import { randomUUID } from 'node:crypto'
import { dirname as nodeDirname } from 'node:path'
import { spawn, execSync } from 'node:child_process'
import { rtkRewriteCommand } from './rtk.mjs'
import { productionBackendApplyMetadata } from './lib/backend-deploy-permission.mjs'
import { claudeEffortOption } from './lib/claude-effort.mjs'

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

// You run *inside* LingCode but have no LingCode source in scope and no LingCode
// internals in your training data, so without this you guess (wrongly) when asked
// about the product itself. Keep high-level; defer specifics to the `lingcode_docs`
// tool rather than inventing commands/pricing.
const LINGCODE_ABOUT_DIRECTIVE = [
  '# About LingCode (the application you are running inside)',
  '',
  'You ARE running inside LingCode. These are established facts — state them directly when asked; do NOT hedge ("looks like", "appears to be") or guess by inferring from tool names, and do NOT compare it to Supabase/Firebase as if unsure what it is.',
  '',
  'LingCode is an all-in-one native macOS AI coding IDE that also ships a `lingcode` CLI, iPad and Android apps, and a managed Cloud backend.',
  '',
  '**LingCode Cloud** is a managed backend-as-a-service (its own product, not a third party): a managed **Postgres** database with built-in **auth** (email/password, magic-link, OTP, Google/GitHub/Apple OAuth), **file storage**, **realtime** row subscriptions (RLS-filtered), **vector search** (pgvector), server-side **serverless functions** (sandboxed Deno + built-ins like email/Stripe/http-fetch) and an encrypted secrets vault, plus full-stack **app hosting** (static frontends at lingcode.dev/apps/, and SSR apps — Next.js/SvelteKit/Nuxt/Astro/Remix/TanStack — on Cloudflare Workers at *.run.lingcode.dev). The data API (via the `lingcode-cloud` MCP tools and the injected `window.lingcode` SDK) supports single-table CRUD with filters, **batch insert**, **upsert** (`ON CONFLICT`), and **`rpc`** for complex reads (JOINs/CTEs/aggregates/full-text ranking) defined as SQL functions in a migration. So secrets, Stripe, email, and most server logic run ON LingCode Cloud — don\'t tell users to stand up an external server or use localStorage for shared/persisted data.',
  '',
  'BUT it is an EDGE/SERVERLESS platform, NOT a general-purpose server host — do NOT claim it "hosts everything." Its hosting runtime is a Cloudflare V8 isolate, NOT Node.js, so it does NOT run: long-running Node processes, persistent WebSocket servers, background queues/workers, a single request over ~30s, or non-JS backends (Python/Django, Rails, Go). A plain Express/`next start` server must be ported to a Worker-targeting framework (Hono, TanStack Start, OpenNext adapter). Work that doesn\'t fit (scrapers, long ingest pipelines, minutes-long jobs) runs on a server the USER operates and writes into the managed backend over the gateway.',
  '',
  'Deploy a web app to LingCode Cloud three ways: the in-app "Deploy to Cloud" button, the `lingcode cloud deploy` CLI, and the /try web playground. (The Swift CLI\'s `lingcode deploy` is a SEPARATE iOS App Store / TestFlight flow — not web hosting.)',
  '',
  'Multi-provider agent: Claude (default, full tool use), DeepSeek, and other OpenAI-compatible providers — all with tool use and MCP.',
  '',
  'When a backend is connected/available you have the `describe_backend` MCP tool — call it for LIVE capabilities, tiers and quotas before designing a data/auth/backend feature. For anything beyond this summary, call the `lingcode_docs` tool (grounded in the live docs). Use these tools rather than guessing; never invent LingCode features, commands, or pricing. Only volunteer this when the user asks about LingCode itself; otherwise stay focused on their project.',
].join('\n')

// The Xcode-shaped work LingCode does in-app. Without this the agent answers
// signing and destination problems with "open Xcode" or "build for the
// simulator instead" — sending the user out of the IDE for things it already
// does, which is the one thing LingCode is for. Kept to a symptom → surface
// map rather than a feature tour: this lands in every turn's system prompt.
const LINGCODE_IDE_SURFACES_DIRECTIVE = [
  '# Xcode work you can do inside LingCode',
  '',
  'These exist in the app. When one of these symptoms comes up, name the LingCode surface FIRST; mention Xcode only as an alternative, and never as the only option.',
  '',
  '- "Signing for X requires a development team" / no `DEVELOPMENT_TEAM` → Settings → Build & Ship → **Signing & Teams**. It writes `DEVELOPMENT_TEAM` into `project.pbxproj`, including for projects that have never been signed, and also sets signing style (Automatic/Manual).',
  '- Bundle id, version/build, deployment target, sanitizer → Settings → Build & Ship → **Build Settings**.',
  '- Info.plist keys (privacy strings, URL schemes, display name) → Settings → Build & Ship → **Info.plist Editor**.',
  '- Push/HealthKit/iCloud and other entitlements → Settings → Build & Ship → **Capabilities & Entitlements**.',
  '- "Which device will this run on?" / picking a simulator or a connected iPhone → the **run-destination picker** in the window toolbar. It lists My Mac, paired devices and simulators, filtered to the platforms the open project actually builds for.',
  '- "Why won\'t this run on my phone?" — Developer Mode off, no iOS SDK, no signing identity, Xcode too old for the phone\'s iOS, no team, template bundle id → **Mobile → Signing & Deployment Preflight** (also Settings → Build & Ship → Setup Checklist). It checks each one and offers the fix.',
  '- Uploading to TestFlight / App Store Connect → the **Ship** flow (`⌘⇧⌥S`).',
  '- App icons and launch screens → **App Icon Generator** and **Splash Screen** in the same menus.',
  '',
  'A macOS-only project cannot build for a phone and an iPhone-only project cannot build for My Mac; if a build fails with "destination doesn\'t match the app\'s supported platforms", that mismatch is the cause — not signing.',
  '',
  'The `lingcode` CLI is always on PATH. Prefer it over external tooling:',
  '- Swift files with no `.xcodeproj` → `lingcode generate-xcodeproj` (never suggest XcodeGen, Tuist, `swift package init`, or "open Xcode → File → New Project").',
  '- Unexplained tool failures / "my setup is broken" → `lingcode doctor` before guessing.',
  '- LingCode embeds and signs its own Node — never tell the user to `brew install node` or install global npm packages.',
  '',
  'Only volunteer this when it is relevant to what the user is doing.',
].join('\n')

// Base URL for LingCode website APIs the bridge calls directly (e.g. the docs
// RAG). Override via env for staging/local. No trailing slash.
const LINGCODE_API_BASE =
  (process.env.LINGCODE_API_BASE || 'https://lingcode.dev').replace(/\/+$/, '')

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

// Defense-in-depth: if the SDK stream goes silent mid-query (a stalled upstream
// API that emits nothing further), abort it after this much inactivity and emit a
// real `query_failed` event instead of hanging forever. Kept BELOW the Swift
// `stallThreshold` (~120s) so Node aborts first and the app renders a clean
// failure rather than relying on its own heartbeat backstop.
const PER_QUERY_INACTIVITY_MS = 90_000

// While the model is generating a tool's input (e.g. a large Write whose content
// is the whole file), the SDK surfaces NO intermediate messages for the entire
// generation — which can legitimately run for minutes. Use a much more generous
// ceiling in that window so we don't abort a turn that's provably mid-generation;
// it still catches a truly hung generation, just later.
const TOOL_GEN_INACTIVITY_MS = 600_000

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
//
// Return the `"auto"` sentinel (NOT a hardcoded model literal): the proxy's
// applyLingModelCostControls rewrites `"auto"` to the DB-configured real model
// (LINGMODEL_DEFAULT_MODEL / FORCE_MODEL), which is production's source of truth.
// A hardcoded literal here bypasses that mapping (it's only rewritten when the
// value is `"auto"`), so a config change would leave the bridge asking upstream
// for a model that no longer exists — a silent model-not-found. The native path
// (AIService) already sends `"auto"`; this keeps the two loops consistent.
function lingModelUpstream(tag) {
  if (
    tag === 'lingmodel-standard' ||
    tag === 'lingmodel-advanced' ||
    tag === 'lingmodel-fast' ||
    tag === 'lingmodel-pro' ||
    tag === 'lingmodel'
  ) {
    return 'auto'
  }
  return null
}
const isLingModelTag = (m) => lingModelUpstream(m) !== null

// User-defined Anthropic-compatible endpoints. Shape: { "<id>": { baseURL, apiKey, model? } }.
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

// ── Terminal read round-trip ────────────────────────────────────────────
// The read_terminal / list_terminals / tail_terminal MCP tools emit a
// terminal_read_request over stdout; the app reads the user's VISIBLE terminal
// tabs (Swift TerminalBufferReader on TerminalSessionManager.shared) and replies
// with terminal_read_response. This is how the Claude (Anthropic) agent — which
// otherwise only sees output of shells it spawned itself via Bash — can read a
// separate terminal tab the user is running. Same shape as the memory round-trip.
const pendingTerminalReads = new Map()
const TERMINAL_READ_TIMEOUT_MS = 15_000

function rejectAllPendingTerminalReads(reason) {
  for (const [requestId, pending] of pendingTerminalReads.entries()) {
    pending.cleanup?.()
    pendingTerminalReads.delete(requestId)
    pending.reject(new Error(reason))
  }
}

function requestTerminalRead(payload) {
  return new Promise((resolve, reject) => {
    const requestId = randomUUID()
    const timer = setTimeout(() => {
      if (!pendingTerminalReads.has(requestId)) return
      pendingTerminalReads.delete(requestId)
      reject(new Error(`Terminal read request ${requestId} timed out after ${TERMINAL_READ_TIMEOUT_MS}ms.`))
    }, TERMINAL_READ_TIMEOUT_MS)
    pendingTerminalReads.set(requestId, { resolve, reject, cleanup: () => clearTimeout(timer) })
    emit({ type: 'terminal_read_request', requestId, ...payload })
  })
}

async function handleTerminalReadResponse(command) {
  const requestId = normalizeString(command.requestId)
  if (!requestId) {
    emitError('terminal_read_response requires requestId.', { code: 'missing_terminal_request_id' })
    return
  }
  const pending = pendingTerminalReads.get(requestId)
  if (!pending) {
    emitError(`No pending terminal read found for ${requestId}.`, { requestId, code: 'unknown_terminal_request' })
    return
  }
  pendingTerminalReads.delete(requestId)
  pending.cleanup?.()
  if (command.ok === true) {
    pending.resolve({ ok: true, text: normalizeString(command.text) ?? '' })
  } else {
    pending.resolve({ ok: false, text: normalizeString(command.error) ?? 'Terminal read failed.' })
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

  // Answer questions about LingCode ITSELF (features, CLI commands, pricing,
  // how-to) from the live docs via the website RAG endpoint. The model has no
  // LingCode internals in scope, so this is its grounded source of truth — it
  // beats guessing. Direct network call (no Swift round-trip needed); the
  // endpoint is public and rate-limited server-side.
  const lingcodeDocsTool = sdkTool(
    'lingcode_docs',
    'Look up how LingCode itself works — its features, CLI commands, deployment, Cloud backend, pricing, or any "how do I … in LingCode" question — grounded in the official LingCode documentation. Use this instead of guessing whenever the user asks about LingCode the product (not their own project code). Returns an answer plus source links.',
    {
      query: z.string().min(1).max(1000).describe('A natural-language question about LingCode the product (1–1000 chars). Example: "How do I deploy a web app to LingCode Cloud?"'),
    },
    async (args) => {
      try {
        const res = await fetch(`${LINGCODE_API_BASE}/api/site-chat/ask`, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ question: args.query }),
          signal: AbortSignal.timeout(20_000),
        })
        const body = await res.json().catch(() => null)
        if (!res.ok || !body || body.ok !== true || !body.data) {
          const msg = (body && (body.message || body.error)) || `HTTP ${res.status}`
          return { content: [{ type: 'text', text: `lingcode_docs unavailable: ${msg}` }], isError: true }
        }
        const answer = normalizeString(body.data.answer) || 'No answer found in the docs.'
        const sources = Array.isArray(body.data.sources) ? body.data.sources : []
        const sourcesText = sources.length
          ? '\n\nSources:\n' + sources
              .filter((s) => s && s.url)
              .map((s) => `- ${s.title || s.url} (${s.url})`).join('\n')
          : ''
        return { content: [{ type: 'text', text: answer + sourcesText }], isError: false }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        return { content: [{ type: 'text', text: `lingcode_docs failed: ${message}` }], isError: true }
      }
    },
  )

  const readTerminalTool = sdkTool(
    'read_terminal',
    "Read the visible buffer + scrollback of one of the USER's terminal tabs in LingCode (the terminals they have open in the bottom panel — NOT shells you spawned; use bash_output for those). `session` accepts a session UUID, a tab-name substring ('build', 'server'), or 'focused'/'active'/empty for whichever tab is currently focused. Use this when the user says 'look at my terminal', 'what's the build saying', 'fix what just errored'.",
    {
      session: z.string().optional().describe("Session UUID, tab-name substring, or 'focused' (default = the focused tab)."),
      max_lines: z.number().optional().describe('Max lines to return (default 500, cap 5000).'),
    },
    async (args) => {
      try {
        const result = await requestTerminalRead({ op: 'read', session: args.session ?? '', max_lines: args.max_lines })
        return { content: [{ type: 'text', text: result.text }], isError: !result.ok }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        return { content: [{ type: 'text', text: `read_terminal failed: ${message}` }], isError: true }
      }
    },
  )

  const listTerminalsTool = sdkTool(
    'list_terminals',
    "List every terminal tab the user has open in LingCode (session IDs, display names, which is focused, ~line counts). Use before read_terminal / tail_terminal to pick the right tab when the user is ambiguous — or skip it and pass session='focused' to read whatever they're looking at.",
    {},
    async () => {
      try {
        const result = await requestTerminalRead({ op: 'list' })
        return { content: [{ type: 'text', text: result.text }], isError: !result.ok }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        return { content: [{ type: 'text', text: `list_terminals failed: ${message}` }], isError: true }
      }
    },
  )

  const tailTerminalTool = sdkTool(
    'tail_terminal',
    "Return only the terminal content that's new since `after_line` — for 'watch the build and tell me when it fails' loops. Call with after_line=0 first, then pass the `next_line` value the previous call returned. `session` works like read_terminal ('focused' default).",
    {
      session: z.string().optional().describe("Session UUID, tab-name substring, or 'focused' (default)."),
      after_line: z.number().optional().describe('Return content after this line index (default 0).'),
      max_lines: z.number().optional().describe('Max lines to return (default 500, cap 5000).'),
    },
    async (args) => {
      try {
        const result = await requestTerminalRead({ op: 'tail', session: args.session ?? '', after_line: args.after_line ?? 0, max_lines: args.max_lines })
        return { content: [{ type: 'text', text: result.text }], isError: !result.ok }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        return { content: [{ type: 'text', text: `tail_terminal failed: ${message}` }], isError: true }
      }
    },
  )

  return createSdkMcpServer({
    name: 'lingcode-memory',
    version: '1.0.0',
    tools: [saveTool, removeTool, skillProposeTool, sessionSearchTool, simulatorScreenshotTool, lingcodeDocsTool, readTerminalTool, listTerminalsTool, tailTerminalTool],
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

function requestToolPermission(queryId, toolName, input, options = {}) {
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
        suggestions: options.forceOneTime ? [] : (options.suggestions ?? []),
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

function createPermissionHandler(queryId, initialPermissionMode) {
  return async (toolName, input, options = {}) => {
    // Read the mode at DECISION time, not at capture time. This handler is built
    // once per query, so capturing the mode meant a mid-turn switch never applied
    // to the turn already running: flipping to Bypass to stop being interrupted
    // left AskUserQuestion on the interactive path, waiting for an answer the app
    // had stopped intending to give — a hung turn.
    //
    // `defaultPermissionMode` tracks the live value (set at query start, updated
    // by `set_permission_mode`). Safe as a module global because there is one
    // bridge process per session — the daemon mode is an explicit no-op, see
    // `lib/commands.mjs`.
    const permissionMode = defaultPermissionMode || initialPermissionMode
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
    // Applying a production backend plan is the exception to yolo/bypass: it
    // always requires a real one-time click. The server validates that the
    // summary and warnings shown here exactly match its short-lived plan.
    const productionDeploy = productionBackendApplyMetadata(toolName, input)
    if (productionDeploy) {
      if (permissionMode === 'dontAsk') {
        return {
          behavior: 'deny',
          message: 'Production backend deployment requires explicit user approval.',
          decisionClassification: 'user_reject',
        }
      }
      return requestToolPermission(queryId, toolName, input, {
        ...options,
        title: productionDeploy.title,
        description: productionDeploy.description,
        forceOneTime: true,
      })
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
    return requestToolPermission(queryId, toolName, input, options)
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

// Anthropic rejects a resumed transcript whose stored thinking block carries a
// truncated/invalid `signature` (the signature streams as a trailing
// `signature_delta`, so a run cut off mid-thinking persists an unverifiable
// block). On resume the CLI replays it and the API 400s. The transcript is
// unrepairable client-side, so we recover by retrying once as a fresh session
// (re-seeding prior context as text — see resumeFallbackContext).
function isThinkingSignatureError(error) {
  const msg = error instanceof Error ? error.message : String(error ?? '')
  return /signature/i.test(msg) && /thinking block/i.test(msg)
}

// Prepend a plain-text context preamble to the next-turn prompt. Handles both
// prompt shapes the SDK accepts: a bare string (no attachments) and an async
// iterable of user messages (attachments present — inject the context as a
// leading text block on the first user message).
function prependContextToPrompt(promptInput, contextText) {
  if (!contextText) return promptInput
  if (typeof promptInput === 'string') {
    return contextText + '\n\n' + promptInput
  }
  return (async function* contextSeededPrompt() {
    let injected = false
    for await (const m of promptInput) {
      if (!injected && m && m.message && m.message.role === 'user') {
        const content = m.message.content
        if (Array.isArray(content)) {
          m.message.content = [{ type: 'text', text: contextText }, ...content]
        } else if (typeof content === 'string') {
          m.message.content = contextText + '\n\n' + content
        }
        injected = true
      }
      yield m
    }
  })()
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
  // Optional plain-text rendering of the prior conversation, sent by Swift only
  // when this turn resumes a session. Used solely on corruption recovery to
  // re-seed continuity in the fresh session.
  const resumeFallbackContext = normalizeString(command.resumeFallbackContext)

  defaultPermissionMode = permissionMode

  // Defense in depth: re-apply provider env in case anything between the last
  // set_model and now mutated it. The Anthropic SDK spawns the `claude` CLI
  // fresh on every query() call, so env mutation here propagates to the child.
  applyProviderEnv(currentModel)
  // LingModel: single tier, send the unified upstream id. Server still gates
  // (allowlist + per-tier caps) and may rewrite to a different id via env.
  // Custom Anthropic-compatible endpoints: send the per-endpoint model the user pinned
  // (e.g. `glm-5.2` for a z.ai endpoint) so gateways that honor the model param route to
  // the right model. When none is set, fall back to a valid-looking Anthropic model id
  // (`claude-sonnet-4-6`) since the SDK requires one and most proxies route by their own
  // config regardless.
  const effectiveModel = isLingModelTag(currentModel)
    ? lingModelUpstream(currentModel)
    : isCustomTag(currentModel)
      ? (customEndpointFor(currentModel)?.model || 'claude-sonnet-4-6')
      : currentModel

  emit({
    type: 'query_started',
    queryId,
    cwd,
    permissionMode,
    resumeSessionId: resumeSessionId ?? null,
    rss: process.memoryUsage().rss,
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
    ...claudeEffortOption(command.effort),
    ...(thinkingEnabled ? { thinking: { type: 'enabled', budget_tokens: command.thinkingBudgetTokens ?? 8000 } } : {}),
    ...(customAgents && Object.keys(customAgents).length > 0 ? { agents: customAgents } : {}),
    appendSystemPrompt: [
      isLingModelTag(currentModel) ? LINGMODEL_IDENTITY_DIRECTIVE : null,
      NARRATION_DIRECTIVE,
      LINGCODE_ABOUT_DIRECTIVE,
      LINGCODE_IDE_SURFACES_DIRECTIVE,
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

  // Inactivity watchdog (see PER_QUERY_INACTIVITY_MS). Re-armed on every SDK
  // message; if it fires the query is aborted and reported as `query_failed`,
  // distinguished from a user cancel via `inactivityAborted`.
  let inactivityTimer = null
  let inactivityAborted = false
  // Indices of tool_use content blocks currently being generated. While any is
  // open the model is provably mid-generation (a big Write etc.), so the timer
  // uses the generous TOOL_GEN_INACTIVITY_MS instead of the normal ceiling.
  const openToolBlocks = new Set()
  // Count of tool_use blocks that have finished emitting but whose tool_result
  // hasn't come back yet — i.e., the SDK is executing the tool and the stream
  // is legitimately silent. Cleared per-tool as tool_result blocks arrive in
  // the next `user` message (parallel tool calls all resolve in one message).
  // Without this, a >90s Bash call (e.g. `xcodebuild` compiling ContentView)
  // trips PER_QUERY_INACTIVITY_MS mid-execution and aborts the query with a
  // misleading "Claude stopped responding" — Claude was waiting on us.
  let pendingToolResults = 0
  const noteStreamEventForToolState = (message) => {
    if (message?.type !== 'stream_event') return
    const ev = message.event
    if (!ev || typeof ev.type !== 'string') return
    if (ev.type === 'content_block_start' && ev.content_block?.type === 'tool_use') {
      if (typeof ev.index === 'number') openToolBlocks.add(ev.index)
    } else if (ev.type === 'content_block_stop') {
      // Only tool_use indices sit in openToolBlocks — text/thinking blocks
      // aren't tracked. Closing one hands control to the tool executor.
      if (typeof ev.index === 'number' && openToolBlocks.has(ev.index)) {
        openToolBlocks.delete(ev.index)
        pendingToolResults += 1
      }
    } else if (ev.type === 'message_stop') {
      openToolBlocks.clear()
    }
  }
  const armInactivityTimer = () => {
    if (inactivityTimer) clearTimeout(inactivityTimer)
    const midToolWork = openToolBlocks.size > 0 || pendingToolResults > 0
    const ms = midToolWork ? TOOL_GEN_INACTIVITY_MS : PER_QUERY_INACTIVITY_MS
    inactivityTimer = setTimeout(() => {
      inactivityAborted = true
      activeAbortController?.abort(new Error('inactivity-timeout'))
    }, ms)
  }
  const clearInactivityTimer = () => {
    if (inactivityTimer) { clearTimeout(inactivityTimer); inactivityTimer = null }
  }

  try {
    let retry = true
    while (retry) {
      retry = false
      const stream = startStream(effectiveResumeId, promptInput)
      armInactivityTimer()
      try {
        for await (const message of stream) {
          if (message && typeof message === 'object') {
            if (typeof message.session_id === 'string' && message.session_id) {
              currentSessionId = message.session_id
            }
            // The `user` message that closes a tool-execution gap carries the
            // tool_result blocks. Discharge one pendingToolResults per block so
            // the watchdog drops back to the tight PER_QUERY_INACTIVITY_MS
            // window as soon as the model regains control. Clamp at 0 so a
            // spurious extra user message (mid-flight directive, resume) can't
            // wedge the counter negative and re-arm the tight window.
            if (message.type === 'user' && pendingToolResults > 0) {
              const blocks = message.message?.content
              if (Array.isArray(blocks)) {
                const resultCount = blocks.reduce(
                  (n, b) => n + (b && b.type === 'tool_result' ? 1 : 0),
                  0,
                )
                if (resultCount > 0) {
                  pendingToolResults = Math.max(0, pendingToolResults - resultCount)
                }
              }
            }
            if (message.type === 'result') {
              finalResult = message
              // Some failures (notably a model-switch that invalidates a prior
              // thinking block's signature, or an unresolvable resume) arrive as
              // a result with `is_error` rather than a thrown stream error, so
              // the catch-block recovery below never sees them. Re-raise ONLY the
              // recoverable shapes into that catch so we retry once as a fresh
              // session. Anything else stays a normal `query_finished` result.
              if (message.is_error && !attemptedResumeRecovery && effectiveResumeId) {
                const resultErr = new Error(String(message.result ?? message.subtype ?? ''))
                if (isThinkingSignatureError(resultErr) || isResumeNotFoundError(resultErr)) {
                  throw resultErr
                }
              }
            }
          }
          emit({ type: 'sdk_message', queryId, message })
          noteStreamEventForToolState(message)
          armInactivityTimer()
        }

        clearInactivityTimer()
        // A non-recoverable `is_error` result (model-not-found, upstream 4xx, quota)
        // arrives here as a normal stream end, not a thrown error — the recoverable
        // shapes were already re-raised + retried above. Surface it as `query_failed`
        // so the app shows an error instead of silently finishing with no reply.
        if (finalResult && finalResult.is_error) {
          const failMessage =
            (typeof finalResult.result === 'string' && finalResult.result.trim()) ||
            (typeof finalResult.subtype === 'string' && finalResult.subtype.trim()) ||
            'The model request failed.'
          emit({
            type: 'query_failed',
            queryId,
            sessionId: currentSessionId,
            message: failMessage,
          })
        } else {
          emit({
            type: 'query_finished',
            queryId,
            sessionId: currentSessionId,
            result: finalResult,
          })
        }
      } catch (error) {
        clearInactivityTimer()
        // Inactivity abort: the stream went silent and our watchdog killed it.
        // Surface a real failure (so the app stops the spinner and offers resume)
        // rather than a user-cancel.
        if (inactivityAborted) {
          emit({
            type: 'query_failed',
            queryId,
            sessionId: currentSessionId,
            message: `Claude stopped responding (no activity for ${Math.round(PER_QUERY_INACTIVITY_MS / 1000)}s).`,
            rss: process.memoryUsage().rss,
          })
          return
        }
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
        // Auto-recovery: a resume that can't proceed — either a stale/unresolvable
        // resume id, or a corrupted transcript whose thinking block has an invalid
        // signature (run cut off mid-thinking). Retry ONCE as a fresh session.
        // Safe because the failure is raised before any assistant output streams
        // or directive is injected, so nothing is lost.
        const corruptThinking = isThinkingSignatureError(error)
        if (!attemptedResumeRecovery && effectiveResumeId &&
            (isResumeNotFoundError(error) || corruptThinking)) {
          attemptedResumeRecovery = true
          effectiveResumeId = undefined
          currentSessionId = null
          pendingDirectives = []
          directiveNotifyResolve = null
          // Rebuild a FRESH prompt: the prior attempt may have consumed a
          // single-use async-iterable prompt (attachments). Reuse the raw string
          // when there were none; otherwise re-derive from the command.
          let recoveredPrompt
          try {
            recoveredPrompt = typeof rawPromptInput === 'string'
              ? rawPromptInput
              : await buildPromptInput(command)
          } catch {
            recoveredPrompt = rawPromptInput
          }
          // For corruption, re-seed the prior conversation as text so the fresh
          // session keeps continuity (a bare "continue" otherwise loses the thread).
          if (corruptThinking && resumeFallbackContext) {
            recoveredPrompt = prependContextToPrompt(recoveredPrompt, resumeFallbackContext)
          }
          promptInput = wrapPromptWithDirectiveQueue(recoveredPrompt)
          emit({
            type: 'session_recovered',
            queryId,
            reason: corruptThinking ? 'thinking_signature_corrupt' : 'resume_not_found',
            message: corruptThinking
              ? 'The previous response was interrupted, leaving the session unresumable. Continuing in a new session with the earlier conversation as context.'
              : 'Previous session could not be resumed; continuing in a new session.',
          })
          retry = true
          continue
        }
        emit({
          type: 'query_failed',
          queryId,
          sessionId: currentSessionId,
          message: error instanceof Error ? error.message : String(error),
          rss: process.memoryUsage().rss,
        })
      }
    }
  } finally {
    clearInactivityTimer()
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
    case 'terminal_read_response':
      await handleTerminalReadResponse(command)
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
  rejectAllPendingTerminalReads('Bridge stdin closed.')
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
  rejectAllPendingTerminalReads('Bridge interrupted.')
  killBridgeDescendants('SIGTERM')
  process.exit(130)
})

process.on('SIGTERM', () => {
  rejectAllPendingPermissions('Bridge terminated.')
  rejectAllPendingMemoryWrites('Bridge terminated.')
  rejectAllPendingSkillWrites('Bridge terminated.')
  rejectAllPendingSessionSearches('Bridge terminated.')
  rejectAllPendingTerminalReads('Bridge terminated.')
  killBridgeDescendants('SIGTERM')
  process.exit(143)
})

emit({
  type: 'ready',
  pid: process.pid,
  protocolVersion: 1,
  permissionModes: [...VALID_PERMISSION_MODES],
})
