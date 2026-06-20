import { randomUUID } from 'node:crypto'
import { dirname as nodeDirname } from 'node:path'
import { spawn, execSync } from 'node:child_process'
import { rtkRewriteCommand } from './rtk.mjs'

// When the bundled rtk is configured, prepend its directory to PATH so the
// SDK's bash subprocess can resolve the bare `rtk` command after our hook
// rewrites `git status` -> `rtk git status`. No-op if rtk isn't set up.
if (process.env.LINGCODE_RTK_PATH && process.env.LINGCODE_RTK !== '0') {
  const rtkDir = nodeDirname(process.env.LINGCODE_RTK_PATH)
  const currentPath = process.env.PATH ?? ''
  if (!currentPath.split(':').includes(rtkDir)) {
    process.env.PATH = `${rtkDir}:${currentPath}`
  }
}
import { extname } from 'node:path'
import { readFile, writeFile } from 'node:fs/promises'
import process from 'node:process'
import readline from 'node:readline'
import { pathToFileURL } from 'node:url'

// Resolve @anthropic-ai/claude-agent-sdk.
// Prefer sdk-bundle.mjs sitting next to this file (bundled inside the app). Fall back to
// the absolute path passed via LINGCODE_CLAUDE_AGENT_SDK_PATH (user's global install).
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { existsSync } from 'node:fs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const bundledSDK = join(__dirname, 'sdk-bundle.mjs')

let query
let createSdkMcpServer
let sdkTool
if (existsSync(bundledSDK)) {
  ;({ query, createSdkMcpServer, tool: sdkTool } = await import(pathToFileURL(bundledSDK).href))
} else {
  const sdkEntry = process.env.LINGCODE_CLAUDE_AGENT_SDK_PATH
  if (!sdkEntry) {
    console.error('bridge.mjs: sdk-bundle.mjs not found and LINGCODE_CLAUDE_AGENT_SDK_PATH not set — cannot locate @anthropic-ai/claude-agent-sdk')
    process.exit(78)
  }
  ;({ query, createSdkMcpServer, tool: sdkTool } = await import(pathToFileURL(sdkEntry).href))
}

// Zod is required by the SDK's tool() helper. We resolve it the same way as
// sdk-bundle.mjs: prefer a sibling zod-bundle.mjs (shipped with the app/CLI),
// fall back to node_modules in dev. If neither is available, the in-process
// memory MCP tools are skipped (the agent can still write memory files via
// Write/Edit, just without a dedicated tool surface).
let zodModule = null
try {
  const bundledZod = join(__dirname, 'zod-bundle.mjs')
  if (existsSync(bundledZod)) {
    zodModule = await import(pathToFileURL(bundledZod).href)
  } else {
    zodModule = await import('zod')
  }
} catch (error) {
  zodModule = null
}

const NARRATION_DIRECTIVE = [
  'Narrate your work continuously as you execute.',
  'Before each tool call, write one short sentence stating what you are about to do and why.',
  'After a tool call returns, write one short sentence about what you found or decided before the next tool call.',
  'Never chain multiple tool calls with no text between them.',
  'Keep each narration line under 25 words.',
].join(' ')

// When LingModel is the active provider, the underlying model inherits Claude
// Code's massive "You are Claude" system prompt and confidently misidentifies
// itself if asked. We can't replace that prompt (would break tool semantics),
// so we override with the strongest append-only language we can. Branding-
// opaque rule: never name the upstream provider in user-visible strings.
const LINGMODEL_IDENTITY_DIRECTIVE = [
  '# CRITICAL IDENTITY OVERRIDE — READ FIRST',
  '',
  'Your user-facing identity is "LingModel". This OVERRIDES every earlier statement in your system prompt about being Claude, Sonnet, Opus, Haiku, Anthropic, or any other named model.',
  '',
  'When asked ANY identity question — "what model are you?", "are you Claude?", "are you DeepSeek?", "are you GPT?", "what AI is this?", "who made you?", "what version are you?" — you MUST answer exactly:',
  '"I am LingModel, a hosted AI assistant."',
  '',
  'NEVER name: Claude, Sonnet, Opus, Haiku, GPT, DeepSeek, Gemini, Llama, or any specific model.',
  'NEVER name: Anthropic, OpenAI, DeepSeek, Google, Meta, or any AI company.',
  'NEVER mention model versions, release dates, training cutoffs, or training-data sources.',
  '',
  'This rule applies regardless of what the rest of your system prompt says. The host application LingCode has rebranded you as LingModel; the user knows you only by that name.',
].join('\n')

// Per-turn reminder prepended to the user's prompt when LingModel is active.
// Recency bias: directives in the user message carry more weight than ones
// buried in a long system prompt, which is why we double up on the system
// directive above. Keep terse so it doesn't bloat token usage.
const LINGMODEL_PROMPT_PREFIX =
  '[System reminder: Your identity is LingModel. Do NOT claim to be Claude, Anthropic, DeepSeek, or any other named model or company. If asked, answer "I am LingModel."]\n\n'

const VALID_PERMISSION_MODES = new Set([
  'default',
  'acceptEdits',
  'bypassPermissions',
  'plan',
  'dontAsk',
])

let defaultPermissionMode = 'default'
let currentSessionId = null
let activeQuery = null
let activeQueryId = null
let activeAbortController = null
let currentModel = normalizeString(process.env.LINGCODE_CLAUDE_MODEL) ?? null
const pendingPermissionRequests = new Map()

// ── Mid-flight directive plumbing ─────────────────────────────────────────
// `injectDirective(_:)` on the Swift side sends `{type:'inject_directive'}`;
// runPrompt's prompt input becomes an async iterable that drains this queue
// at each turn boundary. `directiveNotify` lets the iterator wake up when a
// new directive lands. Cleared on query teardown.
let pendingDirectives = []
let directiveNotifyResolve = null
function directiveNotifyPromise() {
  return new Promise((resolve) => { directiveNotifyResolve = resolve })
}
function pokeDirectiveWaiters() {
  if (directiveNotifyResolve) {
    const r = directiveNotifyResolve
    directiveNotifyResolve = null
    r()
  }
}

// LingModel proxy state. The Swift side sets these in bridgeEnvironment(); we mutate
// process.env per-query so the Anthropic SDK (which spawns the `claude` CLI fresh on
// every query()) picks up the right base URL and bearer token.
let proxyBaseURL = normalizeString(process.env.LINGCODE_PROXY_BASE_URL) ?? null
let proxyAuthToken = normalizeString(process.env.LINGCODE_PROXY_AUTH_TOKEN) ?? null

const originalAnthropicBaseURL = process.env.ANTHROPIC_BASE_URL
const originalAnthropicAuthToken = process.env.ANTHROPIC_AUTH_TOKEN
const originalAnthropicAPIKey = process.env.ANTHROPIC_API_KEY

// LingModel: single tier as of the Standard/Advanced collapse. Every public
// id and every legacy alias resolves to the same upstream model. Aliases stay
// accepted so older prefs/CLI/scripts keep routing through the proxy.
function lingModelUpstream(tag) {
  if (
    tag === 'lingmodel-standard' ||
    tag === 'lingmodel-advanced' ||
    tag === 'lingmodel-fast' ||
    tag === 'lingmodel-pro' ||
    tag === 'lingmodel'
  ) {
    return 'kimi-k2.7'
  }
  return null
}
const isLingModelTag = (m) => lingModelUpstream(m) !== null

// User-defined Anthropic-compatible endpoints. Shape: { "<id>": { baseURL, apiKey } }.
// Populated once at startup by the Swift host (LingCode/Services/ClaudeCodeAgentService.swift).
// Tags are `custom:<id>` and route to ANTHROPIC_BASE_URL/AUTH_TOKEN via `applyProviderEnv`.
let customEndpoints = {}
try {
  const raw = process.env.LINGCODE_CUSTOM_ENDPOINTS
  if (raw) customEndpoints = JSON.parse(raw) || {}
} catch (err) {
  console.error('[lingcode-bridge] failed to parse LINGCODE_CUSTOM_ENDPOINTS:', err?.message || err)
}
const isCustomTag = (m) => typeof m === 'string' && m.startsWith('custom:')
function customEndpointFor(tag) {
  if (!isCustomTag(tag)) return null
  const id = tag.slice('custom:'.length)
  return customEndpoints[id] || null
}

function applyProviderEnv(modelTag) {
  if (isCustomTag(modelTag)) {
    const endpoint = customEndpointFor(modelTag)
    if (endpoint && endpoint.baseURL) {
      process.env.ANTHROPIC_BASE_URL = endpoint.baseURL
      if (endpoint.apiKey) {
        process.env.ANTHROPIC_AUTH_TOKEN = endpoint.apiKey
      } else {
        delete process.env.ANTHROPIC_AUTH_TOKEN
      }
      // Don't leak any user-installed Anthropic key as x-api-key to a third-party endpoint.
      delete process.env.ANTHROPIC_API_KEY
      return
    }
    // Unknown custom id — fall through to default restore. The query will fail
    // cleanly against the user's real Anthropic creds rather than silently
    // hitting the wrong endpoint.
  }
  if (isLingModelTag(modelTag) && proxyBaseURL) {
    process.env.ANTHROPIC_BASE_URL = proxyBaseURL
    if (proxyAuthToken) {
      process.env.ANTHROPIC_AUTH_TOKEN = proxyAuthToken
    } else {
      delete process.env.ANTHROPIC_AUTH_TOKEN
    }
    // Force-clear ANTHROPIC_API_KEY so the SDK doesn't also send the user's real
    // Anthropic key (if any) as `x-api-key` to our proxy.
    delete process.env.ANTHROPIC_API_KEY
    return
  }
  // Claude tier (or unset) — restore originals.
  for (const [k, v] of [
    ['ANTHROPIC_BASE_URL', originalAnthropicBaseURL],
    ['ANTHROPIC_AUTH_TOKEN', originalAnthropicAuthToken],
    ['ANTHROPIC_API_KEY', originalAnthropicAPIKey],
  ]) {
    if (v !== undefined) process.env[k] = v
    else delete process.env[k]
  }
}

applyProviderEnv(currentModel)

function emit(event) {
  process.stdout.write(`${JSON.stringify(event)}\n`)
}

function emitError(message, extra = {}) {
  emit({ type: 'error', message, ...extra })
}

function normalizePermissionMode(value) {
  if (typeof value !== 'string') return null
  return VALID_PERMISSION_MODES.has(value) ? value : null
}

function normalizeString(value) {
  return typeof value === 'string' && value.trim() ? value : null
}

function mimeTypeForImagePath(filePath) {
  switch (extname(filePath).toLowerCase()) {
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg'
    case '.png':
      return 'image/png'
    case '.gif':
      return 'image/gif'
    case '.webp':
      return 'image/webp'
    default:
      return null
  }
}

async function buildPromptInput(command) {
  const promptText = typeof command.prompt === 'string' ? command.prompt : ''
  const attachments = Array.isArray(command.attachments) ? command.attachments : []

  if (attachments.length === 0) {
    const normalizedPrompt = normalizeString(promptText)
    if (!normalizedPrompt) {
      throw new Error('Bridge start command requires a non-empty prompt or supported attachments.')
    }
    return isLingModelTag(currentModel)
      ? LINGMODEL_PROMPT_PREFIX + normalizedPrompt
      : normalizedPrompt
  }

  const content = []
  if (promptText.length > 0) {
    content.push({
      type: 'text',
      text: isLingModelTag(currentModel)
        ? LINGMODEL_PROMPT_PREFIX + promptText
        : promptText,
    })
  } else if (isLingModelTag(currentModel) && attachments.length > 0) {
    content.push({
      type: 'text',
      text: LINGMODEL_PROMPT_PREFIX,
    })
  }

  for (const attachment of attachments) {
    if (!attachment || typeof attachment.type !== 'string') continue
    const filePath = normalizeString(attachment.path)
    if (!filePath) {
      throw new Error('Image attachment is missing a valid path.')
    }
    const attachmentName = normalizeString(attachment.name)
    if (attachment.type === 'image') {
      const mediaType = mimeTypeForImagePath(filePath)
      if (!mediaType) {
        throw new Error(`Unsupported image type for attachment: ${filePath}`)
      }
      const bytes = await readFile(filePath)
      content.push({
        type: 'image',
        source: {
          type: 'base64',
          media_type: mediaType,
          data: bytes.toString('base64'),
        },
      })
      continue
    }
    if (attachment.type === 'pdf') {
      const bytes = await readFile(filePath)
      content.push({
        type: 'document',
        title: attachmentName ?? undefined,
        source: {
          type: 'base64',
          media_type: 'application/pdf',
          data: bytes.toString('base64'),
        },
      })
      continue
    }
    if (attachment.type === 'text') {
      const text = await readFile(filePath, 'utf8')
      content.push({
        type: 'document',
        title: attachmentName ?? undefined,
        source: {
          type: 'text',
          media_type: 'text/plain',
          data: text,
        },
      })
    }
  }

  if (content.length === 0) {
    throw new Error('Bridge start command attachments did not produce any valid content.')
  }

  return (async function* generateUserMessage() {
    yield {
      type: 'user',
      parent_tool_use_id: null,
      message: {
        role: 'user',
        content,
      },
    }
  })()
}

// Compose the original prompt (string OR async iterable) with a directive
// queue that pushes synthetic user messages whenever inject_directive lands.
// Returns an async iterable suitable for the SDK's `prompt` option.
function wrapPromptWithDirectiveQueue(originalPrompt) {
  return (async function* directiveAwarePromptStream() {
    if (typeof originalPrompt === 'string') {
      yield {
        type: 'user',
        parent_tool_use_id: null,
        message: { role: 'user', content: originalPrompt },
      }
    } else if (originalPrompt && typeof originalPrompt[Symbol.asyncIterator] === 'function') {
      for await (const m of originalPrompt) yield m
    }

    // Drain directives that were queued while the SDK was streaming Claude's
    // turn. Once the queue empties, the iterable ENDS so the SDK closes the
    // stream and `query_finished` fires — without this terminator the wrapper
    // waited indefinitely for new directives, holding `activeQuery` non-null
    // forever and causing the next Swift `start` command to be rejected with
    // `query_already_running` (manifested as "second send spinner stuck").
    // Follow-up user turns come as fresh `start` commands with resumeSessionId.
    while (pendingDirectives.length > 0) {
      if (activeAbortController?.signal.aborted) return
      const directive = pendingDirectives.shift()
      yield {
        type: 'user',
        parent_tool_use_id: null,
        message: { role: 'user', content: formatDirectiveContent(directive) },
      }
    }
  })()
}

function formatDirectiveContent(directive) {
  const text = typeof directive?.text === 'string' ? directive.text : ''
  const target = typeof directive?.target === 'string' ? directive.target : 'wholeTurn'
  switch (target) {
    case 'currentFile':
      return `[Mid-flight directive · current file] ${text}`
    case 'nextFiles':
      return `[Mid-flight directive · upcoming files] ${text}`
    case 'wholeTurn':
    default:
      return `[Mid-flight directive] ${text}`
  }
}

function rejectAllPendingPermissions(reason) {
  for (const [requestId, pending] of pendingPermissionRequests.entries()) {
    pending.cleanup?.()
    pendingPermissionRequests.delete(requestId)
    pending.reject(new Error(reason))
  }
}

// ── Memory write round-trip ──────────────────────────────────────────────
// Mirrors the permission-request pattern: the in-process memory MCP tools
// don't write files directly. They emit `memory_write_request` over stdout,
// Swift performs the write through AgentMemoryService (single source of truth
// for size limits, staleness, atomic write), and replies with
// `memory_write_response` on stdin.
const pendingMemoryWrites = new Map()
const MEMORY_WRITE_TIMEOUT_MS = 15_000

function rejectAllPendingMemoryWrites(reason) {
  for (const [requestId, pending] of pendingMemoryWrites.entries()) {
    pending.cleanup?.()
    pendingMemoryWrites.delete(requestId)
    pending.reject(new Error(reason))
  }
}

function requestMemoryWrite(payload) {
  return new Promise((resolve, reject) => {
    const requestId = randomUUID()
    const timer = setTimeout(() => {
      if (!pendingMemoryWrites.has(requestId)) return
      pendingMemoryWrites.delete(requestId)
      reject(new Error(`Memory write request ${requestId} timed out after ${MEMORY_WRITE_TIMEOUT_MS}ms.`))
    }, MEMORY_WRITE_TIMEOUT_MS)

    pendingMemoryWrites.set(requestId, {
      resolve,
      reject,
      cleanup: () => clearTimeout(timer),
    })

    emit({ type: 'memory_write_request', requestId, ...payload })
  })
}

async function handleMemoryWriteResponse(command) {
  const requestId = normalizeString(command.requestId)
  if (!requestId) {
    emitError('memory_write_response requires requestId.', {
      code: 'missing_memory_request_id',
    })
    return
  }
  const pending = pendingMemoryWrites.get(requestId)
  if (!pending) {
    emitError(`No pending memory write found for ${requestId}.`, {
      requestId,
      code: 'unknown_memory_request',
    })
    return
  }
  pendingMemoryWrites.delete(requestId)
  pending.cleanup?.()
  if (command.ok === true) {
    pending.resolve({ ok: true, message: normalizeString(command.message) ?? 'Saved.' })
  } else {
    pending.resolve({ ok: false, message: normalizeString(command.error) ?? 'Memory write failed.' })
  }
}

// ── Skill propose round-trip ────────────────────────────────────────────
// Same shape as memory write: in-process MCP tool emits skill_write_request
// over stdout, Swift writes the SKILL.md draft to disk, replies with
// skill_write_response. Drafts go to `.cursor/skills-drafts/`, NOT
// `.cursor/skills/`, so they don't activate until the user explicitly
// promotes them.
const pendingSkillWrites = new Map()
const SKILL_WRITE_TIMEOUT_MS = 15_000

function rejectAllPendingSkillWrites(reason) {
  for (const [requestId, pending] of pendingSkillWrites.entries()) {
    pending.cleanup?.()
    pendingSkillWrites.delete(requestId)
    pending.reject(new Error(reason))
  }
}

function requestSkillWrite(payload) {
  return new Promise((resolve, reject) => {
    const requestId = randomUUID()
    const timer = setTimeout(() => {
      if (!pendingSkillWrites.has(requestId)) return
      pendingSkillWrites.delete(requestId)
      reject(new Error(`Skill write request ${requestId} timed out after ${SKILL_WRITE_TIMEOUT_MS}ms.`))
    }, SKILL_WRITE_TIMEOUT_MS)
    pendingSkillWrites.set(requestId, {
      resolve, reject,
      cleanup: () => clearTimeout(timer),
    })
    emit({ type: 'skill_write_request', requestId, ...payload })
  })
}

async function handleSkillWriteResponse(command) {
  const requestId = normalizeString(command.requestId)
  if (!requestId) {
    emitError('skill_write_response requires requestId.', { code: 'missing_skill_request_id' })
    return
  }
  const pending = pendingSkillWrites.get(requestId)
  if (!pending) {
    emitError(`No pending skill write found for ${requestId}.`, {
      requestId, code: 'unknown_skill_request',
    })
    return
  }
  pendingSkillWrites.delete(requestId)
  pending.cleanup?.()
  if (command.ok === true) {
    pending.resolve({ ok: true, message: normalizeString(command.message) ?? 'Draft saved.', path: normalizeString(command.path) })
  } else {
    pending.resolve({ ok: false, message: normalizeString(command.error) ?? 'Skill draft failed.' })
  }
}

// ── Session search round-trip ──────────────────────────────────────────
const pendingSessionSearches = new Map()
const SESSION_SEARCH_TIMEOUT_MS = 30_000

function rejectAllPendingSessionSearches(reason) {
  for (const [requestId, pending] of pendingSessionSearches.entries()) {
    pending.cleanup?.()
    pendingSessionSearches.delete(requestId)
    pending.reject(new Error(reason))
  }
}

function requestSessionSearch(payload) {
  return new Promise((resolve, reject) => {
    const requestId = randomUUID()
    const timer = setTimeout(() => {
      if (!pendingSessionSearches.has(requestId)) return
      pendingSessionSearches.delete(requestId)
      reject(new Error(`Session search ${requestId} timed out after ${SESSION_SEARCH_TIMEOUT_MS}ms.`))
    }, SESSION_SEARCH_TIMEOUT_MS)
    pendingSessionSearches.set(requestId, {
      resolve, reject,
      cleanup: () => clearTimeout(timer),
    })
    emit({ type: 'session_search_request', requestId, ...payload })
  })
}

async function handleSessionSearchResponse(command) {
  const requestId = normalizeString(command.requestId)
  if (!requestId) {
    emitError('session_search_response requires requestId.', { code: 'missing_search_request_id' })
    return
  }
  const pending = pendingSessionSearches.get(requestId)
  if (!pending) {
    emitError(`No pending session search found for ${requestId}.`, {
      requestId, code: 'unknown_search_request',
    })
    return
  }
  pendingSessionSearches.delete(requestId)
  pending.cleanup?.()
  if (command.ok === true) {
    pending.resolve({ ok: true, hits: Array.isArray(command.hits) ? command.hits : [] })
  } else {
    pending.resolve({ ok: false, message: normalizeString(command.error) ?? 'Session search failed.' })
  }
}

// ── lingcode-memory SDK MCP server ──────────────────────────────────────
// Registered when zod is available. Two tools: memory_save and memory_remove.
// Both round-trip to Swift via requestMemoryWrite().
function buildLingcodeMemoryServer() {
  if (!zodModule || !createSdkMcpServer || !sdkTool) return null
  const z = zodModule.z ?? zodModule.default?.z ?? zodModule.default
  if (!z || typeof z.object !== 'function') return null

  const VALID_TYPES = ['user', 'feedback', 'project', 'reference']
  const VALID_SCOPES = ['user', 'project']

  const saveTool = sdkTool(
    'memory_save',
    'Save or update a single memory entry. Picks the file based on `scope`: '
      + '"project" → <cwd>/.lingcode/memory.md, "user" → ~/.lingcode/USER.md. '
      + 'Use this rather than Write/Edit on memory files so the IDE can show the save and apply size limits atomically.',
    {
      scope: z.enum(VALID_SCOPES).describe('"project" for facts about this codebase, "user" for facts that travel across all projects.'),
      type: z.enum(VALID_TYPES).describe('Category tag: user (who they are), feedback (how to work), project (project context), reference (external systems).'),
      title: z.string().min(1).max(120).describe('Short section title — becomes the markdown `## <title>` header. If a section with the same title exists, it is replaced.'),
      content: z.string().min(1).max(2000).describe('The memory body. Plain markdown. Lead with the rule/fact; for feedback include a short Why; for project include a How-to-apply.'),
    },
    async (args) => {
      try {
        const result = await requestMemoryWrite({
          op: 'save',
          scope: args.scope,
          memoryType: args.type,
          title: args.title,
          content: args.content,
        })
        return {
          content: [{ type: 'text', text: result.ok ? `✓ ${result.message}` : `✗ ${result.message}` }],
          isError: !result.ok,
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        return { content: [{ type: 'text', text: `memory_save failed: ${message}` }], isError: true }
      }
    },
  )

  const removeTool = sdkTool(
    'memory_remove',
    'Remove a memory entry by section title from project or user memory.',
    {
      scope: z.enum(VALID_SCOPES).describe('Which memory file to edit.'),
      title: z.string().min(1).max(120).describe('Title of the section to remove. Must match exactly.'),
    },
    async (args) => {
      try {
        const result = await requestMemoryWrite({
          op: 'remove',
          scope: args.scope,
          title: args.title,
        })
        return {
          content: [{ type: 'text', text: result.ok ? `✓ ${result.message}` : `✗ ${result.message}` }],
          isError: !result.ok,
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        return { content: [{ type: 'text', text: `memory_remove failed: ${message}` }], isError: true }
      }
    },
  )

  const skillProposeTool = sdkTool(
    'skill_propose',
    'Propose a NEW reusable skill (slash-command) based on a procedure you just executed. Use this when you find yourself doing the same multi-step procedure twice in a session — the proposal becomes a draft SKILL.md that the user reviews before it goes live. Drafts are saved to `.cursor/skills-drafts/<name>/` (project) or `~/.cursor/skills-drafts/<name>/` (user) and do NOT activate until promoted.',
    {
      name: z.string().min(1).max(50).regex(/^[a-z0-9-]+$/).describe('Slug for the skill. Lowercase, hyphens only, e.g. "migrate-feature-flag". Becomes the directory name and slash-command (/migrate-feature-flag).'),
      scope: z.enum(VALID_SCOPES).describe('"project" if the procedure is specific to this codebase, "user" if it generalizes across all your work.'),
      description: z.string().min(10).max(200).describe('One-line summary shown when the user types `/`. Explain when to invoke the skill.'),
      body: z.string().min(50).max(8000).describe('The skill prompt — the instructions a future invocation will give to the agent. Write in second person ("you"). Be concrete: list the exact steps, name files/tools, mention non-obvious gotchas. Do not include YAML frontmatter — the IDE wraps it for you.'),
    },
    async (args) => {
      try {
        const result = await requestSkillWrite({
          op: 'propose',
          scope: args.scope,
          name: args.name,
          description: args.description,
          body: args.body,
        })
        if (result.ok) {
          const where = result.path ? ` at ${result.path}` : ''
          return {
            content: [{ type: 'text', text: `✓ Proposed skill draft '${args.name}'${where}. The user must promote it from skills-drafts/ to skills/ for it to activate.` }],
            isError: false,
          }
        } else {
          return { content: [{ type: 'text', text: `✗ ${result.message}` }], isError: true }
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        return { content: [{ type: 'text', text: `skill_propose failed: ${message}` }], isError: true }
      }
    },
  )

  const sessionSearchTool = sdkTool(
    'session_search',
    'Full-text search across past Claude Agent SDK session transcripts on this Mac. Returns matching snippets with session ids and the cwd those sessions ran against. Use when the user references prior work ("the bug we hit last week", "where did we discuss X", "did I already fix Y in another project"). Index is built lazily — first call may take a few seconds while it scans transcripts.',
    {
      query: z.string().min(1).max(200).describe('FTS5 query. Plain words are AND-combined. Quote phrases with double quotes inside. Examples: terraform drift, "race condition" timer, eslint AND react.'),
      limit: z.number().int().min(1).max(20).optional().describe('Maximum number of hits to return. Default 5.'),
    },
    async (args) => {
      try {
        const result = await requestSessionSearch({
          query: args.query,
          limit: args.limit ?? 5,
        })
        if (!result.ok) {
          return { content: [{ type: 'text', text: `✗ ${result.message}` }], isError: true }
        }
        if (!result.hits || result.hits.length === 0) {
          return { content: [{ type: 'text', text: `No matches for: ${args.query}` }], isError: false }
        }
        const lines = result.hits.map((h, i) => {
          const cwd = h.cwd ? ` cwd=${h.cwd}` : ''
          const when = h.startedAt ? ` at ${h.startedAt}` : ''
          return `${i + 1}. [${h.role}]${when}${cwd}\n   session=${h.sessionId}\n   ${h.snippet}`
        })
        return { content: [{ type: 'text', text: lines.join('\n\n') }], isError: false }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        return { content: [{ type: 'text', text: `session_search failed: ${message}` }], isError: true }
      }
    },
  )

  // Capture a PNG screenshot of the running iOS simulator so the agent can
  // visually verify what the user is looking at. Closes the "I can't see the
  // UI" gap for build-and-launch workflows (lingcode build, lingcode convert,
  // any TDD loop that targets the simulator). Returns image content so Claude
  // can actually see the screen, not a path or a description.
  const simulatorScreenshotTool = sdkTool(
    'simulator_screenshot',
    'Capture a PNG screenshot of the running iOS simulator and return it as an image you can see. Use after installing/launching an app in the simulator to visually verify the UI rendered correctly, to inspect what the user sees, or to confirm a tap/animation produced the expected state. Defaults to the booted simulator; pass `device_udid` to target a specific one.',
    {
      device_udid: z.string().optional().describe('Optional simulator UDID. Defaults to "booted" (the currently-running simulator). Get UDIDs from `xcrun simctl list devices`.'),
    },
    async (args) => {
      const target = args.device_udid || 'booted'
      try {
        const png = await runXcrunScreenshot(target)
        return {
          content: [{
            type: 'image',
            source: { type: 'base64', media_type: 'image/png', data: png.toString('base64') },
          }],
          isError: false,
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        return { content: [{ type: 'text', text: `simulator_screenshot failed: ${message}` }], isError: true }
      }
    },
  )

  return createSdkMcpServer({
    name: 'lingcode-memory',
    version: '1.0.0',
    tools: [saveTool, removeTool, skillProposeTool, sessionSearchTool, simulatorScreenshotTool],
  })
}

function runXcrunScreenshot(target) {
  return new Promise((resolve, reject) => {
    const proc = spawn('/usr/bin/xcrun', ['simctl', 'io', target, 'screenshot', '-', '--type=png'])
    const chunks = []
    const errChunks = []
    proc.stdout.on('data', (c) => chunks.push(c))
    proc.stderr.on('data', (c) => errChunks.push(c))
    proc.on('error', reject)
    proc.on('close', (code) => {
      if (code !== 0) {
        const stderr = Buffer.concat(errChunks).toString('utf8').trim()
        reject(new Error(`xcrun simctl exited with code ${code}: ${stderr || '(no stderr)'}`))
        return
      }
      const buf = Buffer.concat(chunks)
      if (buf.length === 0) {
        reject(new Error('xcrun simctl returned empty output (is the simulator booted?)'))
        return
      }
      // Sanity check PNG magic so we fail loudly if simctl ever changes its output shape.
      if (buf.length < 8 || buf[0] !== 0x89 || buf[1] !== 0x50 || buf[2] !== 0x4e || buf[3] !== 0x47) {
        reject(new Error('output is not a valid PNG (magic bytes mismatch)'))
        return
      }
      resolve(buf)
    })
  })
}

const lingcodeMemoryServer = buildLingcodeMemoryServer()

// SubagentStart / SubagentStop hook callbacks. The SDK's built-in Agent tool
// dispatches subagents (often in parallel) as part of normal Task execution.
// These hooks let LingCode show live "lanes" in SubagentTreeView /
// SubagentPanelView — what's actively running, when each child started/ended.
//
// Hook return shape: an empty `{ continue: true }` is the no-op. We just want
// the side effect of emitting an event to Swift; the SDK doesn't need us to
// intervene in the agent's flow.
function buildSubagentLifecycleHooks(queryId) {
  const onStart = async (input) => {
    emit({
      type: 'subagent_started',
      queryId,
      agentId: input?.agent_id ?? null,
      agentType: input?.agent_type ?? null,
      sessionId: input?.session_id ?? null,
      cwd: input?.cwd ?? null,
    })
    return { continue: true }
  }
  const onStop = async (input) => {
    emit({
      type: 'subagent_finished',
      queryId,
      agentId: input?.agent_id ?? null,
      agentType: input?.agent_type ?? null,
      sessionId: input?.session_id ?? null,
      transcriptPath: input?.agent_transcript_path ?? null,
      stopHookActive: input?.stop_hook_active ?? null,
    })
    return { continue: true }
  }
  const hooks = {
    SubagentStart: [{ hooks: [onStart] }],
    SubagentStop: [{ hooks: [onStop] }],
  }

  // RTK auto-rewrite: when the bundled rtk binary is configured, register a
  // PreToolUse[Bash] hook that swaps `git status` -> `rtk git status` (etc.)
  // before the SDK runs the command, cutting tool_result tokens 60-90% on
  // common dev workflows. The SDK applies hookSpecificOutput.updatedInput in
  // place — no extra model round-trip. Falls through silently on any rtk
  // failure: rtkRewriteCommand returns null and we leave the input alone.
  const rtkPath = process.env.LINGCODE_RTK_PATH
  if (rtkPath && process.env.LINGCODE_RTK !== '0') {
    const onPreBash = async (input) => {
      const command = input?.tool_input?.command
      if (typeof command !== 'string' || command.length === 0) {
        return { continue: true }
      }
      const cwd = typeof input?.cwd === 'string' ? input.cwd : process.cwd()
      const rewritten = await rtkRewriteCommand(rtkPath, command, cwd)
      if (!rewritten || rewritten === command) {
        return { continue: true }
      }
      return {
        continue: true,
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecisionReason: 'RTK auto-rewrite',
          updatedInput: { ...(input.tool_input ?? {}), command: rewritten },
        },
      }
    }
    hooks.PreToolUse = [{ matcher: 'Bash', hooks: [onPreBash] }]
  }

  return hooks
}

function createPermissionHandler(queryId, permissionMode) {
  return async (toolName, input, options = {}) => {
    // AskUserQuestion is NOT a permission gate — it's the model asking the user
    // a multiple-choice question.
    //   • bypassPermissions ("yolo"): the user wants zero interruptions, so we
    //     auto-pick a sensible default (the option labeled/desc'd "Recommended",
    //     else the first) and feed it back as `updatedInput.answers` — no UI.
    //   • every other mode: surface the interactive option picker and answer
    //     with the user's real selection.
    // The native binary turns `updatedInput.answers` into the tool result.
    if (toolName === 'AskUserQuestion') {
      if (permissionMode === 'bypassPermissions') {
        return {
          behavior: 'allow',
          updatedInput: { ...input, answers: autoPickAskUserAnswers(input) },
        }
      }
      return requestUserInputAnswer(queryId, input, options)
    }
    // Belt-and-suspenders for bypassPermissions. The SDK is supposed to
    // short-circuit canUseTool when allowDangerouslySkipPermissions is true,
    // but we don't want the user to ever see an approval dialog under bypass
    // even if the SDK invokes the callback anyway.
    if (permissionMode === 'bypassPermissions') {
      return { behavior: 'allow', updatedInput: input }
    }
    if (permissionMode === 'dontAsk') {
      return {
        behavior: 'deny',
        message:
          options.decisionReason ??
          'LingCode permission mode is set to Don’t Ask.',
        decisionClassification: 'user_reject',
      }
    }
    return new Promise((resolve, reject) => {
      const requestId = randomUUID()
      let settled = false

      const cleanup = () => {
        settled = true
        if (options.signal && abortHandler) {
          options.signal.removeEventListener('abort', abortHandler)
        }
      }

      const abortHandler = () => {
        if (settled) return
        cleanup()
        pendingPermissionRequests.delete(requestId)
        reject(new Error(`Permission request ${requestId} aborted.`))
      }

      if (options.signal?.aborted) {
        abortHandler()
        return
      }

      if (options.signal) {
        options.signal.addEventListener('abort', abortHandler, { once: true })
      }

      pendingPermissionRequests.set(requestId, {
        resolve: (result) => {
          if (settled) return
          cleanup()
          resolve(result)
        },
        reject: (error) => {
          if (settled) return
          cleanup()
          reject(error)
        },
        cleanup,
        originalInput: input,
      })

      emit({
        type: 'permission_request',
        queryId,
        requestId,
        toolName,
        input,
        options: {
          suggestions: options.suggestions ?? [],
          blockedPath: options.blockedPath ?? null,
          decisionReason: options.decisionReason ?? null,
          title: options.title ?? null,
          displayName: options.displayName ?? null,
          description: options.description ?? null,
          toolUseID: options.toolUseID,
          agentID: options.agentID ?? null,
        },
      })
    })
  }
}

// Auto-answer AskUserQuestion in bypass/yolo mode: pick the "Recommended"
// option (matched on label or description) when present, otherwise the first
// option. Returns { [questionText]: chosenLabel } shaped for updatedInput.answers.
function autoPickAskUserAnswers(input) {
  const answers = {}
  const questions = Array.isArray(input?.questions) ? input.questions : []
  for (const q of questions) {
    const opts = Array.isArray(q?.options) ? q.options : []
    if (!opts.length || typeof q?.question !== 'string') continue
    const recommended =
      opts.find((o) => typeof o?.label === 'string' && /recommend/i.test(o.label)) ||
      opts.find((o) => typeof o?.description === 'string' && /recommend/i.test(o.description))
    const pick = recommended || opts[0]
    if (pick && typeof pick.label === 'string') {
      answers[q.question] = pick.label
    }
  }
  return answers
}

// AskUserQuestion round-trip. Mirrors the permission Promise above and reuses
// `pendingPermissionRequests` (so abort/teardown via rejectAllPendingPermissions
// is shared), but emits `user_input_request` so the Swift host renders the
// option-picker UI instead of an allow/deny approval dialog. The answer comes
// back as a `user_input_response` command (see handleUserInputResponse), which
// resolves this Promise with `{behavior:'allow', updatedInput:{...input, answers}}`.
function requestUserInputAnswer(queryId, input, options = {}) {
  return new Promise((resolve, reject) => {
    const requestId = randomUUID()
    let settled = false

    const cleanup = () => {
      settled = true
      if (options.signal && abortHandler) {
        options.signal.removeEventListener('abort', abortHandler)
      }
    }

    const abortHandler = () => {
      if (settled) return
      cleanup()
      pendingPermissionRequests.delete(requestId)
      reject(new Error(`User input request ${requestId} aborted.`))
    }

    if (options.signal?.aborted) {
      abortHandler()
      return
    }

    if (options.signal) {
      options.signal.addEventListener('abort', abortHandler, { once: true })
    }

    pendingPermissionRequests.set(requestId, {
      resolve: (result) => {
        if (settled) return
        cleanup()
        resolve(result)
      },
      reject: (error) => {
        if (settled) return
        cleanup()
        reject(error)
      },
      cleanup,
      originalInput: input,
    })

    emit({
      type: 'user_input_request',
      queryId,
      requestId,
      toolUseID: options.toolUseID ?? null,
      questions: Array.isArray(input?.questions) ? input.questions : [],
    })
  })
}

// Resolve a pending AskUserQuestion. On answer, hand the selections back as
// `updatedInput.answers` (question text -> answer string; multi-select values
// are comma-separated). On cancel, deny so the model is told the user declined.
async function handleUserInputResponse(command) {
  const requestId = normalizeString(command.requestId)
  if (!requestId) {
    emitError('user_input_response requires requestId.', {
      code: 'missing_user_input_request_id',
    })
    return
  }

  const pending = pendingPermissionRequests.get(requestId)
  if (!pending) {
    emitError(`No pending user input request found for ${requestId}.`, {
      requestId,
      code: 'unknown_user_input_request',
    })
    return
  }
  pendingPermissionRequests.delete(requestId)

  if (command.cancelled === true) {
    pending.resolve({
      behavior: 'deny',
      message:
        normalizeString(command.message) ??
        'User dismissed the question without answering.',
      decisionClassification: 'user_reject',
    })
    emit({ type: 'user_input_resolved', requestId, cancelled: true })
    return
  }

  const answers =
    command.answers && typeof command.answers === 'object' && !Array.isArray(command.answers)
      ? command.answers
      : {}
  const annotations =
    command.annotations && typeof command.annotations === 'object' && !Array.isArray(command.annotations)
      ? command.annotations
      : null

  pending.resolve({
    behavior: 'allow',
    updatedInput: {
      ...(pending.originalInput ?? {}),
      answers,
      ...(annotations ? { annotations } : {}),
    },
  })
  emit({ type: 'user_input_resolved', requestId, cancelled: false })
}

// The native `claude` CLI throws this when `resume: <id>` references a
// transcript it can't find under the current cwd's project slug (deleted
// transcript, cwd changed since the session was created, or a UUID that isn't
// the SDK's internal resume key). Detected so we can transparently retry once
// as a fresh session instead of hard-failing the user out of the conversation.
function isResumeNotFoundError(error) {
  const msg = error instanceof Error ? error.message : String(error ?? '')
  return /No conversation found with session/i.test(msg)
}

async function runPrompt(command) {
  if (activeQuery) {
    emitError('A Claude query is already running.', {
      queryId: activeQueryId,
      code: 'query_already_running',
    })
    return
  }

  let prompt
  try {
    prompt = await buildPromptInput(command)
  } catch (error) {
    emitError(error instanceof Error ? error.message : String(error), {
      code: 'missing_prompt',
    })
    return
  }

  // Wrap the prompt as a controllable async iterable so inject_directive can
  // push synthetic user messages at the next turn boundary. The SDK accepts
  // either a string or an async iterable of user-message objects.
  pendingDirectives = []
  directiveNotifyResolve = null
  // Keep the raw (pre-wrapped) prompt so a resume-recovery retry can rebuild a
  // fresh directive queue — the wrapped async iterable is single-consumption.
  const rawPromptInput = prompt
  prompt = wrapPromptWithDirectiveQueue(prompt)

  const queryId = normalizeString(command.queryId) ?? randomUUID()
  const permissionMode =
    normalizePermissionMode(command.permissionMode) ?? defaultPermissionMode
  const cwd = normalizeString(command.cwd) ?? process.cwd()
  const claudePath = normalizeString(command.claudePath) ?? undefined
  const resumeSessionId =
    normalizeString(command.resumeSessionId) ?? currentSessionId ?? undefined
  // Default to 200 turns when the caller doesn't pass one, matching the Mac
  // app's explicit budget (ClaudeCodeAgentService) so CLI/headless runs aren't
  // capped tighter. An explicit command.maxTurns still wins.
  const maxTurns =
    typeof command.maxTurns === 'number' && command.maxTurns > 0
      ? Math.floor(command.maxTurns)
      : 200
  const allowedTools = Array.isArray(command.allowedTools) ? command.allowedTools : undefined
  const disallowedTools = Array.isArray(command.disallowedTools) ? command.disallowedTools : undefined
  // Build mcpServers as an object map (SDK form). Swift sends `{name: cfg}`;
  // we also fold in the in-process `lingcode-memory` SDK server when available.
  const mcpServers = (() => {
    const out = {}
    if (command.mcpServers && typeof command.mcpServers === 'object') {
      for (const [name, cfg] of Object.entries(command.mcpServers)) {
        if (cfg && typeof cfg === 'object') out[name] = cfg
      }
    }
    if (lingcodeMemoryServer) {
      out['lingcode-memory'] = lingcodeMemoryServer
    }
    return Object.keys(out).length > 0 ? out : undefined
  })()
  const customSystemPrompt = normalizeString(command.systemPrompt)
  const customAppendSystemPrompt = normalizeString(command.appendSystemPrompt)
  // Custom subagent definitions, parsed Swift-side from `.claude/agents/<name>.md`.
  // SDK expects `agents: Record<string, {description, prompt, tools?, model?}>`.
  const customAgents = command.agents && typeof command.agents === 'object' && !Array.isArray(command.agents)
    ? Object.fromEntries(
        Object.entries(command.agents)
          .filter(([k, v]) => typeof k === 'string' && v && typeof v === 'object' && typeof v.description === 'string' && typeof v.prompt === 'string')
          .map(([k, v]) => {
            const def = { description: v.description, prompt: v.prompt }
            if (Array.isArray(v.tools) && v.tools.every(t => typeof t === 'string')) def.tools = v.tools
            if (typeof v.model === 'string' && v.model.length > 0) def.model = v.model
            return [k, def]
          })
      )
    : undefined
  const additionalDirectories = Array.isArray(command.additionalDirectories) && command.additionalDirectories.length
    ? command.additionalDirectories.filter((d) => typeof d === 'string' && d.length > 0)
    : undefined
  const thinkingEnabled = command.thinking === true

  defaultPermissionMode = permissionMode

  // Defense in depth: re-apply provider env in case anything between the last
  // set_model and now mutated it. The Anthropic SDK spawns the `claude` CLI
  // fresh on every query() call, so env mutation here propagates to the child.
  applyProviderEnv(currentModel)
  // LingModel: single tier, send the unified upstream id. Server still gates
  // (allowlist + per-tier caps) and may rewrite to a different id via env.
  // Custom Anthropic-compatible endpoints: most proxies route by their own model regardless
  // of what we send, but the SDK requires a valid-looking Anthropic model id, so default
  // the wire name to claude-sonnet-4-6.
  const effectiveModel = isLingModelTag(currentModel)
    ? lingModelUpstream(currentModel)
    : isCustomTag(currentModel)
      ? 'claude-sonnet-4-6'
      : currentModel

  emit({
    type: 'query_started',
    queryId,
    cwd,
    permissionMode,
    resumeSessionId: resumeSessionId ?? null,
  })

  // Build options once; `resume` and `abortController` are the only fields that
  // differ between the initial attempt and a resume-recovery retry.
  const buildOptions = (resumeId, abortController) => ({
    cwd,
    maxTurns,
    includePartialMessages: true,
    permissionMode,
    abortController,
    // NOTE: we deliberately do NOT set `allowDangerouslySkipPermissions` for
    // bypassPermissions. That flag makes the SDK skip canUseTool entirely, which
    // would prevent us from intercepting AskUserQuestion to auto-pick a sensible
    // answer in bypass mode (it would self-resolve to an empty answer instead).
    // Instead, createPermissionHandler auto-allows every tool under bypass
    // (synchronously, no UI), so bypass stays dialog-free while still letting us
    // answer AskUserQuestion. See createPermissionHandler + autoPickAskUserAnswers.
    ...(claudePath ? { pathToClaudeCodeExecutable: claudePath } : {}),
    ...(resumeId ? { resume: resumeId } : {}),
    ...(effectiveModel ? { model: effectiveModel } : {}),
    ...(allowedTools ? { allowedTools } : {}),
    ...(disallowedTools ? { disallowedTools } : {}),
    ...(mcpServers ? { mcpServers } : {}),
    ...(customSystemPrompt ? { systemPrompt: customSystemPrompt } : {}),
    ...(additionalDirectories ? { additionalDirectories } : {}),
    ...(thinkingEnabled ? { thinking: { type: 'enabled', budget_tokens: command.thinkingBudgetTokens ?? 8000 } } : {}),
    ...(customAgents && Object.keys(customAgents).length > 0 ? { agents: customAgents } : {}),
    appendSystemPrompt: [
      isLingModelTag(currentModel) ? LINGMODEL_IDENTITY_DIRECTIVE : null,
      NARRATION_DIRECTIVE,
      customAppendSystemPrompt || null,
    ].filter(Boolean).join('\n\n'),
    canUseTool: createPermissionHandler(queryId, permissionMode),
    hooks: buildSubagentLifecycleHooks(queryId),
    // Live ~30s AI-generated progress summaries from running subagents.
    // Surfaces as "stream_event" (or similar) entries the Mac app maps onto
    // SubagentLane; also useful when running blind from headless CLI mode.
    agentProgressSummaries: true,
    // Suppress the "Co-Authored-By: Claude <noreply@anthropic.com>" trailer
    // the Claude Code CLI normally appends to commit messages. Empty string =
    // no trailer; commits stay attributed to the human author only, so the
    // user's GitHub contributor graph stays clean. Same suppression applies
    // to PR bodies via attribution.pr.
    attribution: { commit: '', pr: '' },
  })

  // (Re)create the abort controller + stream and publish them as the active
  // query. Called once normally, twice when recovering from a bad resume.
  const startStream = (resumeId, promptInput) => {
    activeAbortController = new AbortController()
    const stream = query({
      prompt: promptInput,
      options: buildOptions(resumeId, activeAbortController),
    })
    activeQuery = stream
    activeQueryId = queryId
    return stream
  }

  let effectiveResumeId = resumeSessionId
  let promptInput = prompt
  let attemptedResumeRecovery = false
  let finalResult = null

  try {
    let retry = true
    while (retry) {
      retry = false
      const stream = startStream(effectiveResumeId, promptInput)
      try {
        for await (const message of stream) {
          if (message && typeof message === 'object') {
            if (typeof message.session_id === 'string' && message.session_id) {
              currentSessionId = message.session_id
            }
            if (message.type === 'result') {
              finalResult = message
            }
          }
          emit({ type: 'sdk_message', queryId, message })
        }

        emit({
          type: 'query_finished',
          queryId,
          sessionId: currentSessionId,
          result: finalResult,
        })
      } catch (error) {
        // User-initiated cancel takes priority over recovery — unchanged.
        if (activeAbortController?.signal.aborted) {
          emit({
            type: 'query_cancelled',
            queryId,
            sessionId: currentSessionId,
            message: error instanceof Error ? error.message : 'Query cancelled.',
          })
          return
        }
        // Auto-recovery: a stale/unresolvable resume id. Retry ONCE as a fresh
        // session. Safe because the failure is raised before any assistant
        // output streams or directive is injected, so nothing is lost.
        if (!attemptedResumeRecovery && effectiveResumeId && isResumeNotFoundError(error)) {
          attemptedResumeRecovery = true
          effectiveResumeId = undefined
          currentSessionId = null
          // Rebuild the single-use directive-wrapped prompt from the raw input.
          pendingDirectives = []
          directiveNotifyResolve = null
          promptInput = wrapPromptWithDirectiveQueue(rawPromptInput)
          emit({
            type: 'session_recovered',
            queryId,
            reason: 'resume_not_found',
            message: 'Previous session could not be resumed; continuing in a new session.',
          })
          retry = true
          continue
        }
        emit({
          type: 'query_failed',
          queryId,
          sessionId: currentSessionId,
          message: error instanceof Error ? error.message : String(error),
        })
      }
    }
  } finally {
    activeQuery = null
    activeQueryId = null
    activeAbortController = null
    pendingDirectives = []
    pokeDirectiveWaiters()
    rejectAllPendingPermissions('Query finished before permission response arrived.')
  }
}

async function handlePermissionResponse(command) {
  const requestId = normalizeString(command.requestId)
  if (!requestId) {
    emitError('permission_response requires requestId.', {
      code: 'missing_permission_request_id',
    })
    return
  }

  const pending = pendingPermissionRequests.get(requestId)
  if (!pending) {
    emitError(`No pending permission request found for ${requestId}.`, {
      requestId,
      code: 'unknown_permission_request',
    })
    return
  }
  pendingPermissionRequests.delete(requestId)

  const behavior = command.behavior === 'deny' ? 'deny' : 'allow'
  if (behavior === 'allow') {
    const resolvedInput = command.updatedInput ?? pending.originalInput ?? {}
    pending.resolve({
      behavior: 'allow',
      updatedInput: resolvedInput,
      ...(Array.isArray(command.updatedPermissions)
        ? { updatedPermissions: command.updatedPermissions }
        : {}),
      ...(normalizeString(command.decisionClassification)
        ? { decisionClassification: command.decisionClassification }
        : {}),
    })
  } else {
    pending.resolve({
      behavior: 'deny',
      message:
        normalizeString(command.message) ??
        'Denied by LingCode bridge approval UI.',
      ...(typeof command.interrupt === 'boolean'
        ? { interrupt: command.interrupt }
        : {}),
      ...(normalizeString(command.decisionClassification)
        ? { decisionClassification: command.decisionClassification }
        : {}),
    })
  }

  emit({
    type: 'permission_resolved',
    requestId,
    behavior,
  })
}

async function handleCommand(command) {
  if (!command || typeof command !== 'object') {
    emitError('Bridge received a non-object command payload.', {
      code: 'invalid_command_shape',
    })
    return
  }

  switch (command.type) {
    case 'start':
      await runPrompt(command)
      break
    case 'mock_can_use_tool_roundtrip':
      await runMockCanUseToolRoundTrip(command)
      break
    case 'mock_pending_permission':
      await runMockPendingPermission(command)
      break
    case 'permission_response':
      await handlePermissionResponse(command)
      break
    case 'user_input_response':
      await handleUserInputResponse(command)
      break
    case 'memory_write_response':
      await handleMemoryWriteResponse(command)
      break
    case 'skill_write_response':
      await handleSkillWriteResponse(command)
      break
    case 'session_search_response':
      await handleSessionSearchResponse(command)
      break
    case 'reset_session':
      currentSessionId = null
      emit({ type: 'session_reset' })
      break
    case 'set_permission_mode': {
      const next = normalizePermissionMode(command.permissionMode)
      if (!next) {
        emitError('Unknown permission mode.', {
          code: 'invalid_permission_mode',
          permissionMode: command.permissionMode ?? null,
        })
        return
      }
      defaultPermissionMode = next
      emit({ type: 'permission_mode_updated', permissionMode: next })
      break
    }
    case 'set_model': {
      currentModel = normalizeString(command.model)
      const newToken = normalizeString(command.proxyAuthToken)
      if (newToken) proxyAuthToken = newToken
      applyProviderEnv(currentModel)
      emit({ type: 'model_updated', model: currentModel })
      break
    }
    case 'inject_directive': {
      const directive = command.directive && typeof command.directive === 'object' ? command.directive : null
      if (!directive) {
        emitError('inject_directive requires a directive payload.', {
          code: 'invalid_directive_shape',
        })
        return
      }
      const target = typeof directive.target === 'string' ? directive.target : 'wholeTurn'
      if (target === 'stop') {
        if (activeAbortController) {
          activeAbortController.abort(new Error('Stopped via inject_directive.'))
          emit({ type: 'cancel_requested', queryId: activeQueryId, sessionId: currentSessionId })
        }
        pokeDirectiveWaiters()
        return
      }
      const text = typeof directive.text === 'string' ? directive.text.trim() : ''
      if (!text) {
        emitError('inject_directive requires non-empty text for non-stop targets.', {
          code: 'invalid_directive_text',
        })
        return
      }
      if (!activeQuery) {
        emit({
          type: 'directive_dropped',
          reason: 'no_active_query',
          target,
        })
        return
      }
      pendingDirectives.push({ text, target })
      pokeDirectiveWaiters()
      emit({
        type: 'directive_accepted',
        queryId: activeQueryId,
        sessionId: currentSessionId,
        target,
      })
      break
    }
    case 'cancel_active_query':
      if (!activeQuery || !activeAbortController) {
        emit({
          type: 'query_cancelled',
          queryId: activeQueryId,
          sessionId: currentSessionId,
          message: 'No active Claude query to cancel.',
          alreadyIdle: true,
        })
        return
      }
      activeAbortController.abort(new Error('Cancelled by LingCode.'))
      emit({
        type: 'cancel_requested',
        queryId: activeQueryId,
        sessionId: currentSessionId,
      })
      break
    case 'ping':
      emit({
        type: 'pong',
        activeQueryId,
        sessionId: currentSessionId,
      })
      break
    case 'shutdown':
      activeAbortController?.abort(new Error('Bridge shutting down.'))
      rejectAllPendingPermissions('Bridge shutting down.')
      emit({ type: 'shutdown_ack' })
      process.exit(0)
    default:
      emitError(`Unknown bridge command type: ${String(command.type)}`, {
        code: 'unknown_command_type',
      })
      break
  }
}

async function runMockCanUseToolRoundTrip(command) {
  if (activeQuery) {
    emitError('A Claude query is already running.', {
      queryId: activeQueryId,
      code: 'query_already_running',
    })
    return
  }

  const queryId = normalizeString(command.queryId) ?? randomUUID()
  const targetPath = normalizeString(command.targetPath)
  if (!targetPath) {
    emitError('mock_can_use_tool_roundtrip requires targetPath.', {
      code: 'missing_target_path',
    })
    return
  }

  emit({
    type: 'query_started',
    queryId,
    cwd: normalizeString(command.cwd) ?? process.cwd(),
    permissionMode: 'default',
    resumeSessionId: null,
    mock: true,
  })

  activeQuery = { mock: true }
  activeQueryId = queryId

  try {
    const decide = createPermissionHandler(queryId)
    const result = await decide(
      'Edit',
      {
        file_path: targetPath,
        old_string: '',
        new_string: 'APPROVED_ROUND_TRIP\n',
      },
      {
        toolUseID: `mock-tool-${queryId}`,
        title: 'Claude wants to edit a file',
        displayName: 'Edit file',
        description: `Write APPROVED_ROUND_TRIP to ${targetPath}`,
        blockedPath: targetPath,
        decisionReason: 'Bridge mock self-test for canUseTool round-trip.',
        suggestions: [
          {
            type: 'addDirectories',
            directories: [targetPath],
            destination: 'session',
          },
        ],
      }
    )

    if (result.behavior === 'deny') {
      emit({
        type: 'query_failed',
        queryId,
        sessionId: currentSessionId,
        message: result.message,
      })
      return
    }

    await writeFile(targetPath, 'APPROVED_ROUND_TRIP\n', 'utf8')

    emit({
      type: 'sdk_message',
      queryId,
      message: {
        type: 'assistant',
        message: {
          content: [
            {
              type: 'text',
              text: 'Mock bridge self-test completed after an approved tool round-trip.',
            },
          ],
        },
        parent_tool_use_id: null,
        session_id: currentSessionId ?? `mock-session-${queryId}`,
      },
    })

    emit({
      type: 'query_finished',
      queryId,
      sessionId: currentSessionId ?? `mock-session-${queryId}`,
      result: {
        type: 'result',
        subtype: 'success',
        is_error: false,
        result: 'Mock round-trip completed.',
        session_id: currentSessionId ?? `mock-session-${queryId}`,
      },
    })
  } catch (error) {
    emit({
      type: 'query_failed',
      queryId,
      sessionId: currentSessionId,
      message: error instanceof Error ? error.message : String(error),
    })
  } finally {
    activeQuery = null
    activeQueryId = null
    rejectAllPendingPermissions('Mock query finished before permission response arrived.')
  }
}

async function runMockPendingPermission(command) {
  if (activeQuery) {
    emitError('A Claude query is already running.', {
      queryId: activeQueryId,
      code: 'query_already_running',
    })
    return
  }

  const queryId = normalizeString(command.queryId) ?? randomUUID()
  activeAbortController = new AbortController()
  activeQuery = { mock: true, pendingPermission: true }
  activeQueryId = queryId

  emit({
    type: 'query_started',
    queryId,
    cwd: normalizeString(command.cwd) ?? process.cwd(),
    permissionMode: 'default',
    resumeSessionId: null,
    mock: true,
  })

  try {
    const decide = createPermissionHandler(queryId, 'default')
    await decide(
      'Edit',
      { file_path: '/tmp/mock-cancel.txt' },
      {
        toolUseID: `mock-cancel-${queryId}`,
        title: 'Claude wants to edit a file',
        displayName: 'Edit file',
        description: 'Waiting for approval or cancellation.',
        blockedPath: '/tmp/mock-cancel.txt',
        decisionReason: 'Bridge mock cancellation test.',
        signal: activeAbortController.signal,
      }
    )

    emit({
      type: 'query_finished',
      queryId,
      sessionId: currentSessionId ?? `mock-session-${queryId}`,
      result: {
        type: 'result',
        subtype: 'success',
        is_error: false,
        result: 'Mock pending permission resolved.',
        session_id: currentSessionId ?? `mock-session-${queryId}`,
      },
    })
  } catch (error) {
    if (activeAbortController?.signal.aborted) {
      emit({
        type: 'query_cancelled',
        queryId,
        sessionId: currentSessionId,
        message: error instanceof Error ? error.message : 'Query cancelled.',
      })
      return
    }

    emit({
      type: 'query_failed',
      queryId,
      sessionId: currentSessionId,
      message: error instanceof Error ? error.message : String(error),
    })
  } finally {
    activeQuery = null
    activeQueryId = null
    activeAbortController = null
    rejectAllPendingPermissions('Mock pending permission finished before permission response arrived.')
  }
}

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
})

rl.on('line', async (line) => {
  const trimmed = line.trim()
  if (!trimmed) return

  let command
  try {
    command = JSON.parse(trimmed)
  } catch (error) {
    emitError('Bridge received invalid JSON.', {
      code: 'invalid_json',
      detail: error instanceof Error ? error.message : String(error),
    })
    return
  }

  try {
    await handleCommand(command)
  } catch (error) {
    emitError(error instanceof Error ? error.message : String(error), {
      code: 'bridge_command_failed',
    })
  }
})

rl.on('close', () => {
  rejectAllPendingPermissions('Bridge stdin closed.')
  rejectAllPendingMemoryWrites('Bridge stdin closed.')
  rejectAllPendingSkillWrites('Bridge stdin closed.')
  rejectAllPendingSessionSearches('Bridge stdin closed.')
  process.exit(0)
})

// Kill every transitive descendant of this bridge process. The Anthropic SDK
// spawns the `claude` CLI internally and we don't hold a ChildProcess ref to
// it; without this step those CLI processes orphan when the bridge dies and
// accumulate across LingCode restarts. `pgrep -P` is on PATH on every macOS
// version we support.
function killBridgeDescendants(signal) {
  const collect = (parentPid) => {
    let out
    try {
      out = execSync(`pgrep -P ${parentPid}`, { stdio: ['ignore', 'pipe', 'ignore'] }).toString()
    } catch { return [] }
    const direct = out.trim().split('\n').filter(Boolean).map(Number)
    return direct.flatMap((p) => [p, ...collect(p)])
  }
  for (const pid of collect(process.pid)) {
    try { process.kill(pid, signal) } catch {}
  }
}

process.on('SIGINT', () => {
  rejectAllPendingPermissions('Bridge interrupted.')
  rejectAllPendingMemoryWrites('Bridge interrupted.')
  rejectAllPendingSkillWrites('Bridge interrupted.')
  rejectAllPendingSessionSearches('Bridge interrupted.')
  killBridgeDescendants('SIGTERM')
  process.exit(130)
})

process.on('SIGTERM', () => {
  rejectAllPendingPermissions('Bridge terminated.')
  rejectAllPendingMemoryWrites('Bridge terminated.')
  rejectAllPendingSkillWrites('Bridge terminated.')
  rejectAllPendingSessionSearches('Bridge terminated.')
  killBridgeDescendants('SIGTERM')
  process.exit(143)
})

emit({
  type: 'ready',
  pid: process.pid,
  protocolVersion: 1,
  permissionModes: [...VALID_PERMISSION_MODES],
})
