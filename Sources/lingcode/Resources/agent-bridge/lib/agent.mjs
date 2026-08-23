// agent.mjs — provider routing + the two streaming agent loops.
//
// streamOnce is the single public entry point: it resolves the active
// account, dispatches to the Anthropic-shape path (claude-agent-sdk) or
// the OpenAI-compat path (in-house SSE loop) based on the provider's
// shape, and returns whatever the caller needs to resume the next turn.
//
// Module-level state kept here:
//   - lazy-loaded SDK query() function
//   - cached path to the claude-code cli.js
//   - cached MCP client connections (reused across REPL turns)
//   - _needsNewline: whether the last text chunk lacked a trailing \n,
//     so we know when to emit one before a [ToolCall] line lands

import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { existsSync } from 'node:fs'
import { execSync } from 'node:child_process'
import process from 'node:process'

import { providerByName, activeAccount, readKeyFromEnv, loadCredentials } from './auth.mjs'
import { streamOpenAICompat } from './openai-compat.mjs'
import { discoverAll, buildSkillIndex } from './plugins.mjs'
import { startMCPServers, closeAll as closeMCP } from './mcp-client.mjs'
import { formatUsageLine, usageFromAnthropicResult, usageFromOpenAICompat } from './usage.mjs'
import { isTTY, ansi, renderToolCall, promptYesNo } from './render.mjs'

// ---- Host context (static) ------------------------------------------------
// Tells the model it's running inside the lingcode CLI REPL and that the
// sibling macOS GUI is LingCode.app. Without this, "open lingcode app" sends
// the agent hunting for an unknown binary and instructing the user to run
// `lingcode` — which they're already inside of.
const HOST_CONTEXT_EXTENSION = `You are the assistant inside the \`lingcode\` CLI — a multi-provider AI coding REPL running in the user's terminal. The user is already in this REPL; never instruct them to run \`lingcode\` and never try to relaunch yourself.

A sibling macOS GUI ships under the name "LingCode":
  • App bundle (installed):  /Applications/LingCode.app
  • Launch with:             open -a LingCode

When the user says "open the app", "open lingcode", "launch lingcode", or similar, they mean the GUI — run \`open -a LingCode\`. macOS LaunchServices will find the app wherever it's installed (including dev builds in DerivedData), so don't hunt for the bundle path yourself.`

// ---- Output style (config-driven) -----------------------------------------
// `lingcode config set output-style <compact|verbose|concise>` toggles a
// system-prompt suffix so the model adjusts its response length/style.
// Read on every call so changes take effect without REPL restart.
async function readOutputStyleExtension() {
  const { existsSync } = await import('node:fs')
  const { readFile } = await import('node:fs/promises')
  const { homedir } = await import('node:os')
  const { join: pathJoin } = await import('node:path')
  const cfgPath = pathJoin(homedir(), '.lingcode', 'config.json')
  if (!existsSync(cfgPath)) return null
  try {
    const cfg = JSON.parse(await readFile(cfgPath, 'utf8'))
    switch (cfg['output-style']) {
      case 'compact': return 'Keep responses brief — 1-3 sentences unless a thorough answer is genuinely necessary.'
      case 'verbose': return 'Explain reasoning step by step. Show intermediate work and trade-offs.'
      case 'concise': return 'Skip pleasantries. Answer directly with no preamble.'
      default:        return null
    }
  } catch { return null }
}

// ---- SDK resolution -------------------------------------------------------
const __dirname = dirname(fileURLToPath(import.meta.url))
const bundledSDK = join(__dirname, '..', 'sdk-bundle.mjs')

let query

async function loadSDK() {
  if (query) return query
  if (existsSync(bundledSDK)) {
    ;({ query } = await import(pathToFileURL(bundledSDK).href))
  } else {
    const sdkEntry = process.env.LINGCODE_CLAUDE_AGENT_SDK_PATH
    if (!sdkEntry) {
      throw new Error('sdk-bundle.mjs not found beside the package and LINGCODE_CLAUDE_AGENT_SDK_PATH is not set.')
    }
    ;({ query } = await import(pathToFileURL(sdkEntry).href))
  }
  return query
}

// Locate the bundled `claude-code` CLI binary that the SDK spawns under the
// hood. Prefer env override → node_modules sibling → global `claude` on PATH.
function resolveClaudeCodeExecutable() {
  if (process.env.LINGCODE_CLAUDE_CODE_EXECUTABLE) {
    return process.env.LINGCODE_CLAUDE_CODE_EXECUTABLE
  }
  const local = join(__dirname, '..', 'node_modules', '@anthropic-ai', 'claude-agent-sdk', 'cli.js')
  if (existsSync(local)) return local
  const which = process.platform === 'win32' ? 'where' : 'which'
  try {
    const out = execSync(`${which} claude`, { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim()
    if (out && existsSync(out.split('\n')[0])) return out.split('\n')[0]
  } catch {
    /* not on PATH */
  }
  return null
}

const CLAUDE_CODE_EXECUTABLE = resolveClaudeCodeExecutable()

// ---- Permission gate ------------------------------------------------------
// Tools whose execution is read-only — auto-allow in TTY without prompting.
const SAFE_TOOLS = new Set(['Read', 'Glob', 'Grep', 'LS', 'NotebookRead'])

// Internal: tracked across streaming events so the next emitted line knows
// whether it needs to push a leading newline first.
let _needsNewline = false

async function askPermission(toolName, input, permissionMode, prompter = null) {
  if (SAFE_TOOLS.has(toolName) || permissionMode === 'bypassPermissions') return 'allow'
  if (!isTTY) return 'deny'
  if (_needsNewline) {
    process.stdout.write('\n')
    _needsNewline = false
  }
  const question = `${ansi.yellow(`Allow ${toolName}?`)} ${renderToolCall(toolName, input)} ${ansi.dim('[y/N] ')}`
  // Prefer the caller-supplied prompter (REPL mode passes one wired to the
  // active readline). Fall back to a standalone reader for one-shot paths.
  const ok = prompter ? await prompter(question) : await promptYesNo(question)
  return ok ? 'allow' : 'deny'
}

// ---- Provider resolution --------------------------------------------------

async function resolveProvider(overrideName = null) {
  let chosen = null
  if (overrideName) {
    const store = await loadCredentials()
    const rec = store.accounts[overrideName]
    if (!rec) {
      throw new Error(
        `No account configured for '${overrideName}'. Run: lingcode auth login --provider ${overrideName}`
      )
    }
    chosen = { ...rec, _name: overrideName }
  } else {
    chosen = await activeAccount()
  }
  if (!chosen) {
    throw new Error('No active provider. Run: lingcode auth login')
  }
  const meta = providerByName(chosen.provider || chosen._name)
  if (!meta) {
    throw new Error(`Stored account has unknown provider '${chosen.provider}'.`)
  }
  // Env var override beats stored secret (matches Swift CLI behavior).
  const envOverride = readKeyFromEnv(meta.name)
  const secret = envOverride || chosen[meta.keyField] || chosen.apiKey || chosen.token
  if (!secret) {
    throw new Error(`No secret stored for '${meta.name}'. Run: lingcode auth login --provider ${meta.name}`)
  }
  return { meta, secret, accountName: chosen._name }
}

// Set the env vars the Anthropic SDK consumes. Only used for the Anthropic
// shape — OpenAI-compat passes auth in the HTTP header directly.
function applyAnthropicEnv(meta, secret) {
  if (meta.baseURL) {
    // Proxied Anthropic-shape endpoint — bearer auth.
    process.env.ANTHROPIC_BASE_URL = meta.baseURL
    process.env.ANTHROPIC_AUTH_TOKEN = secret
    delete process.env.ANTHROPIC_API_KEY
  } else {
    // Native Anthropic — x-api-key.
    process.env.ANTHROPIC_API_KEY = secret
    delete process.env.ANTHROPIC_BASE_URL
    delete process.env.ANTHROPIC_AUTH_TOKEN
  }
}

// ---- MCP client cache -----------------------------------------------------
// Same MCP server connections reused across turns inside one process. REPL
// keeps them alive; one-shot ask spawns + closes per call.
let _mcpCache = null

async function ensureMCP(mcpServers) {
  const sig = mcpServers ? JSON.stringify(mcpServers) : ''
  if (_mcpCache && _mcpCache.sig === sig) return _mcpCache
  if (_mcpCache) {
    try { await closeMCP(_mcpCache.clients) } catch { /* ignore */ }
    _mcpCache = null
  }
  if (!mcpServers || Object.keys(mcpServers).length === 0) return null
  const { clients, tools } = await startMCPServers(mcpServers, {
    onWarn: (m) => process.stderr.write(ansi.dim(`(MCP: ${m})\n`)),
  })
  _mcpCache = { sig, clients, tools }
  return _mcpCache
}

// Tear down any cached MCP servers at process exit (REPL-driven case).
process.on('beforeExit', async () => {
  if (_mcpCache) await closeMCP(_mcpCache.clients)
})

// ---- streamOnce — dispatcher ----------------------------------------------

export async function streamOnce(prompt, {
  sessionId = null,
  permissionMode = 'default',
  providerOverride = null,
  priorMessages = null,
  plugins = null,
  imagePaths = [],
  prompter = null,
} = {}) {
  const { meta, secret, accountName } = await resolveProvider(providerOverride)
  const pluginConfig = plugins || (await discoverAll(process.cwd()))

  const abortController = new AbortController()
  const onSigInt = () => abortController.abort()
  process.on('SIGINT', onSigInt)
  _needsNewline = false

  try {
    if (meta.shape === 'anthropic') {
      return await streamAnthropic(prompt, {
        meta, secret, sessionId, permissionMode, abortController, accountName, pluginConfig, imagePaths, prompter,
      })
    }
    return await streamCompat(prompt, {
      meta, secret, priorMessages, permissionMode, abortController, accountName, pluginConfig, imagePaths, prompter,
    })
  } catch (error) {
    if (abortController.signal.aborted) {
      process.stderr.write(ansi.dim('\n[cancelled]\n'))
      return { sessionId, account: accountName, aborted: true }
    }
    process.stderr.write(ansi.red(`\nlingcode: ${error instanceof Error ? error.message : String(error)}\n`))
    throw error
  } finally {
    process.off('SIGINT', onSigInt)
  }
}

// ---- streamAnthropic ------------------------------------------------------

async function streamAnthropic(prompt, { meta, secret, sessionId, permissionMode, abortController, accountName, pluginConfig, imagePaths = [], prompter = null }) {
  applyAnthropicEnv(meta, secret)
  await loadSDK()
  if (!CLAUDE_CODE_EXECUTABLE) {
    throw new Error(
      `Couldn't locate the bundled claude-code CLI. ` +
      `Run \`npm install\` in ${join(__dirname, '..')} or install Claude Code globally (npm i -g @anthropic-ai/claude-code).`
    )
  }

  // If the user attached images, build the Anthropic-shape multi-content
  // user message and pass `prompt` as an async iterable. Otherwise the
  // simple string-prompt form is enough.
  let promptArg = prompt
  if (imagePaths.length > 0) {
    const { readFile } = await import('node:fs/promises')
    const { extname } = await import('node:path')
    const MIME = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp' }
    const content = [{ type: 'text', text: prompt }]
    for (const path of imagePaths) {
      const ext = extname(path).toLowerCase()
      const media_type = MIME[ext]
      if (!media_type) throw new Error(`Unsupported image type: ${path} (${ext}). Use .png/.jpg/.gif/.webp.`)
      const data = (await readFile(path)).toString('base64')
      content.push({ type: 'image', source: { type: 'base64', media_type, data } })
    }
    promptArg = (async function* () {
      yield { type: 'user', message: { role: 'user', content } }
    })()
  }

  let newSessionId = sessionId
  let finalResult = null

  const skillIndex = pluginConfig?.skills ? buildSkillIndex(pluginConfig.skills) : null
  const styleExt = await readOutputStyleExtension()
  const combinedSystemExt = [HOST_CONTEXT_EXTENSION, skillIndex, styleExt].filter(Boolean).join('\n\n') || null

  const queryOptions = {
    cwd: process.cwd(),
    includePartialMessages: true,
    permissionMode,
    abortController,
    pathToClaudeCodeExecutable: CLAUDE_CODE_EXECUTABLE,
    ...(sessionId ? { resume: sessionId } : {}),
    ...(process.env.ANTHROPIC_MODEL ? { model: process.env.ANTHROPIC_MODEL } : {}),
    ...(permissionMode === 'bypassPermissions' ? { allowDangerouslySkipPermissions: true } : {}),
    ...(pluginConfig?.mcpServers ? { mcpServers: pluginConfig.mcpServers } : {}),
    ...(pluginConfig?.hooks ? { hooks: pluginConfig.hooks.hooks } : {}),
    ...(pluginConfig?.agents ? { agents: pluginConfig.agents } : {}),
    ...(combinedSystemExt ? { appendSystemPrompt: combinedSystemExt } : {}),
    canUseTool: async (toolName, input) => {
      const decision = await askPermission(toolName, input, permissionMode, prompter)
      return decision === 'allow'
        ? { behavior: 'allow', updatedInput: input }
        : { behavior: 'deny', message: 'User denied.' }
    },
  }

  const stream = query({ prompt: promptArg, options: queryOptions })
  for await (const message of stream) {
    if (!message || typeof message !== 'object') continue
    if (typeof message.session_id === 'string') newSessionId = message.session_id
    if (message.type === 'result') {
      finalResult = message
      continue
    }
    if (message.type === 'rate_limit_event') continue

    if (message.type === 'assistant' && Array.isArray(message.message?.content)) {
      for (const block of message.message.content) {
        if (block.type === 'tool_use') {
          if (_needsNewline) {
            process.stdout.write('\n')
            _needsNewline = false
          }
          process.stdout.write(renderToolCall(block.name, block.input) + '\n')
        }
      }
    }
    if (message.type === 'stream_event' && message.event?.type === 'content_block_delta') {
      const delta = message.event.delta
      if (delta?.type === 'text_delta' && typeof delta.text === 'string') {
        process.stdout.write(delta.text)
        _needsNewline = !delta.text.endsWith('\n')
      }
    }
  }
  if (_needsNewline) process.stdout.write('\n')
  // Dim usage line on stderr when SDK gave us a `result` with token counts.
  const usage = usageFromAnthropicResult(finalResult)
  const line = usage ? formatUsageLine(usage) : null
  if (isTTY && line) process.stderr.write(ansi.dim(line + '\n'))
  return { sessionId: newSessionId, result: finalResult, account: accountName, messages: null }
}

// ---- streamCompat (OpenAI-shape) ------------------------------------------

async function streamCompat(prompt, { meta, secret, priorMessages, permissionMode, abortController, accountName, pluginConfig, imagePaths = [], prompter = null }) {
  const skillIndex = pluginConfig?.skills ? buildSkillIndex(pluginConfig.skills) : null
  const styleExt = await readOutputStyleExtension()
  const combinedSystemExt = [HOST_CONTEXT_EXTENSION, skillIndex, styleExt].filter(Boolean).join('\n\n') || null
  const mcp = await ensureMCP(pluginConfig?.mcpServers)

  const result = await streamOpenAICompat({
    prompt,
    messages: priorMessages,
    meta,
    secret,
    systemPromptExtension: combinedSystemExt,
    mcpClients: mcp?.clients || null,
    mcpTools: mcp?.tools || [],
    hooksConfig: pluginConfig?.hooks?.hooks || null,
    imagePaths,
    abortController,
    permissionCallback: (name, input) => askPermission(name, input, permissionMode, prompter),
    onText: (chunk) => {
      process.stdout.write(chunk)
      _needsNewline = !chunk.endsWith('\n')
    },
    onToolStart: (name, input) => {
      if (_needsNewline) { process.stdout.write('\n'); _needsNewline = false }
      process.stdout.write(renderToolCall(name, input) + '\n')
    },
    onToolResult: () => {},
    onToolDenied: (name) => {
      process.stderr.write(ansi.dim(`(denied ${name})\n`))
    },
  })
  if (_needsNewline) process.stdout.write('\n')
  const usage = usageFromOpenAICompat(result.usage, result.model)
  const line = usage ? formatUsageLine(usage) : null
  if (isTTY && line) process.stderr.write(ansi.dim(line + '\n'))
  // OpenAI-compat has no session id — return the full message history so
  // the REPL can resume by passing it back next turn.
  return { sessionId: null, result: null, account: accountName, messages: result.messages }
}
