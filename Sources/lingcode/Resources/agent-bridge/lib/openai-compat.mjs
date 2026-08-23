// openai-compat.mjs — streaming agent loop for OpenAI-compatible providers
// (OpenAI, Groq, Together, OpenRouter, Mistral, xAI, Fireworks, Kimi, Qwen,
// z-ai, Gemini-OpenAI-shim, Ollama) AND DeepSeek's native /chat/completions
// (which is OpenAI-shape).
//
// Implements: streaming SSE, tool calls via the OpenAI function-call protocol,
// multi-turn tool round-tripping, permission gating via a callback supplied
// by the caller, abort via AbortController.
//
// Intentionally NOT included in v0.3: MCP (deferred to v0.4), hooks, custom
// system prompt layering beyond a single string, image inputs, JSON mode,
// parallel tool calls beyond what the SDK natively supports (we execute them
// serially even when the model emits multiple in one turn).

import process from 'node:process'
import { readFile } from 'node:fs/promises'
import { extname } from 'node:path'
import { TOOL_SCHEMAS, executeTool, SAFE_TOOLS } from './native-tools.mjs'
import { callMCPTool, parseMCPName } from './mcp-client.mjs'
import { runHooks } from './hooks.mjs'

const IMAGE_MIME = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
}

async function buildUserContent(prompt, imagePaths) {
  if (!imagePaths || imagePaths.length === 0) return prompt
  const blocks = [{ type: 'text', text: prompt }]
  for (const path of imagePaths) {
    const ext = extname(path).toLowerCase()
    const mime = IMAGE_MIME[ext]
    if (!mime) throw new Error(`Unsupported image type: ${path} (${ext}). Use .png/.jpg/.gif/.webp.`)
    const buf = await readFile(path)
    blocks.push({
      type: 'image_url',
      image_url: { url: `data:${mime};base64,${buf.toString('base64')}` },
    })
  }
  return blocks
}

const DEFAULT_MODELS = {
  openai: 'gpt-4o-mini',
  groq: 'llama-3.3-70b-versatile',
  together: 'meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo',
  openrouter: 'openai/gpt-4o-mini',
  mistral: 'mistral-large-latest',
  xai: 'grok-2-latest',
  fireworks: 'accounts/fireworks/models/llama-v3p1-70b-instruct',
  kimi: 'moonshot-v1-32k',
  qwen: 'qwen-max',
  'z-ai': 'glm-4.6',
  gemini: 'gemini-2.0-flash',
  ollama: 'llama3.2',
  deepseek: 'deepseek-chat',
}

const SYSTEM_PROMPT = [
  'You are LingCode, a coding assistant in the terminal.',
  'You can read, write, and edit files; run shell commands; and search code via the provided tools.',
  'Be concise. Prefer running a tool over asking the user clarifying questions when the answer is in the codebase.',
  'When you finish, end with a short summary of what changed.',
].join(' ')

// ---- SSE line parser ------------------------------------------------------
// Splits a stream of text chunks into discrete `data: ...` events.
async function* parseSSE(reader) {
  const decoder = new TextDecoder()
  let buffer = ''
  while (true) {
    const { value, done } = await reader.read()
    if (done) break
    buffer += decoder.decode(value, { stream: true })
    const lines = buffer.split('\n')
    buffer = lines.pop() || ''
    for (const line of lines) {
      if (!line.startsWith('data:')) continue
      const payload = line.slice(5).trim()
      if (payload === '[DONE]') return
      if (!payload) continue
      try {
        yield JSON.parse(payload)
      } catch {
        // Skip malformed chunks (some providers send keepalive comments).
      }
    }
  }
}

// ---- Tool-call assembler --------------------------------------------------
// The SSE stream emits tool_calls in fragments: { index, id, function:{name,
// arguments} }. We accumulate by index into a flat array.
function accumulateToolCall(state, delta) {
  const idx = delta.index ?? 0
  if (!state[idx]) state[idx] = { id: '', function: { name: '', arguments: '' } }
  if (delta.id) state[idx].id = delta.id
  if (delta.function?.name) state[idx].function.name += delta.function.name
  if (delta.function?.arguments) state[idx].function.arguments += delta.function.arguments
}

// ---- Streaming render -----------------------------------------------------

export async function streamOpenAICompat({
  prompt,
  messages: priorMessages = null,
  meta,
  secret,
  abortController,
  permissionCallback, // async (toolName, parsedInput) => 'allow' | 'deny'
  onText,             // (chunk: string) => void
  onToolStart,        // (name, input) => void
  onToolResult,       // (name, content) => void
  onToolDenied,       // (name) => void
  systemPromptExtension = null, // string — appended to system message on first turn
  mcpClients = null,             // Map<serverName, Client> from startMCPServers
  mcpTools = [],                 // function schemas already namespaced mcp__server__tool
  hooksConfig = null,            // raw .claude/hooks/hooks.json `hooks` object
  imagePaths = [],               // file paths to attach as image_url content blocks
  model: modelOverride = null,
  maxIterations = 16,
}) {
  const baseURL = meta.baseURL
  const model = modelOverride || process.env.LINGCODE_OPENAI_MODEL || DEFAULT_MODELS[meta.name] || 'gpt-4o-mini'
  const url = `${baseURL.replace(/\/$/, '')}/chat/completions`

  // UserPromptSubmit hook gate. If a hook blocks, we surface the reason and
  // bail before any HTTP request.
  if (hooksConfig) {
    const dec = await runHooks(hooksConfig, 'UserPromptSubmit', { userPrompt: prompt })
    if (dec.blocked) {
      throw new Error(`UserPromptSubmit hook blocked: ${dec.reason}`)
    }
  }

  // Build/seed message history. If imagePaths is non-empty, the user
  // content becomes a multi-part array (text + image_url blocks).
  const sysContent = systemPromptExtension
    ? `${SYSTEM_PROMPT}\n\n${systemPromptExtension}`
    : SYSTEM_PROMPT
  const messages = priorMessages
    ? priorMessages.slice() // resume — caller passed history
    : [{ role: 'system', content: sysContent }]
  const userContent = await buildUserContent(prompt, imagePaths)
  messages.push({ role: 'user', content: userContent })

  // Native tools + any MCP tools the caller registered.
  const allTools = [...TOOL_SCHEMAS, ...(Array.isArray(mcpTools) ? mcpTools : [])]

  let iter = 0
  let finalMessages = messages // returned to caller for REPL session resume

  while (iter < maxIterations) {
    iter++
    if (abortController.signal.aborted) break

    const requestBody = {
      model,
      messages: finalMessages,
      stream: true,
      // Ask OpenAI-shape endpoints for usage stats in the final chunk.
      // Most providers honor this; the ones that don't just ignore it.
      stream_options: { include_usage: true },
      tools: allTools,
      tool_choice: 'auto',
    }
    const headers = {
      'Content-Type': 'application/json',
      Accept: 'text/event-stream',
    }
    if (secret) headers['Authorization'] = `Bearer ${secret}`

    let response
    try {
      response = await fetch(url, {
        method: 'POST',
        headers,
        body: JSON.stringify(requestBody),
        signal: abortController.signal,
      })
    } catch (error) {
      if (abortController.signal.aborted) return { messages: finalMessages, aborted: true }
      throw new Error(`HTTP request failed: ${error.message}`)
    }
    if (!response.ok) {
      const text = await response.text().catch(() => '')
      // Surface a more helpful hint for common auth failures so users
      // aren't left staring at a raw provider payload.
      const hint = (() => {
        if (response.status === 401 || response.status === 403) {
          return ` (stored key for '${meta.name}' was rejected — refresh with \`lingcode auth set ${meta.name} <new-key>\`)`
        }
        if (response.status === 404) return ` (model '${model}' not found at this endpoint — try \`LINGCODE_OPENAI_MODEL=...\` or another provider)`
        if (response.status === 429) return ` (rate-limited; wait or switch providers via \`/use\` in REPL)`
        if (response.status >= 500) return ` (provider-side error; retry in a moment)`
        return ''
      })()
      throw new Error(`HTTP ${response.status} from ${url}${hint}: ${text.slice(0, 400)}`)
    }
    if (!response.body) throw new Error('No response body (provider may not support streaming).')

    let assistantText = ''
    let lastUsage = null   // captured from the final SSE chunk when present
    const toolCalls = []

    for await (const event of parseSSE(response.body.getReader())) {
      // Some providers emit a final event whose `choices` is empty but
      // whose `usage` is populated. Capture it before checking choice[0].
      if (event.usage) lastUsage = event.usage
      const choice = event.choices?.[0]
      if (!choice) continue
      const delta = choice.delta || {}
      if (typeof delta.content === 'string' && delta.content.length > 0) {
        assistantText += delta.content
        onText?.(delta.content)
      }
      if (Array.isArray(delta.tool_calls)) {
        for (const tc of delta.tool_calls) accumulateToolCall(toolCalls, tc)
      }
      // finish_reason: 'stop' | 'tool_calls' | 'length' | 'content_filter'
    }

    // Append the assistant message back to history.
    const assistantMessage = {
      role: 'assistant',
      content: assistantText || null,
    }
    if (toolCalls.length > 0) {
      assistantMessage.tool_calls = toolCalls
        .filter((c) => c && c.function?.name)
        .map((c) => ({
          id: c.id || `call_${Math.random().toString(36).slice(2, 10)}`,
          type: 'function',
          function: { name: c.function.name, arguments: c.function.arguments || '{}' },
        }))
    }
    finalMessages.push(assistantMessage)

    // If no tool calls, we're done. Fire the Stop hook.
    if (!assistantMessage.tool_calls || assistantMessage.tool_calls.length === 0) {
      if (hooksConfig) {
        await runHooks(hooksConfig, 'Stop', {})
      }
      return { messages: finalMessages, aborted: false, usage: lastUsage, model }
    }

    // Execute tool calls. We sequence permission prompts so they don't
    // interleave on the TTY, but tool execution itself runs concurrently
    // after permission is granted.
    const decisions = []
    for (const call of assistantMessage.tool_calls) {
      if (abortController.signal.aborted) return { messages: finalMessages, aborted: true }
      const name = call.function.name
      let parsedInput = {}
      try {
        parsedInput = call.function.arguments ? JSON.parse(call.function.arguments) : {}
      } catch (error) {
        decisions.push({ call, error: `Error: tool arguments were not valid JSON: ${error.message}` })
        continue
      }
      onToolStart?.(name, parsedInput)
      // PreToolUse hook gate (blocks before permission prompt; user-defined
      // hooks can veto tool use with their own policy regardless of TTY).
      if (hooksConfig) {
        const dec = await runHooks(hooksConfig, 'PreToolUse', { toolName: name, toolInput: parsedInput })
        if (dec.blocked) {
          decisions.push({ call, denied: true, reason: dec.reason || 'Blocked by PreToolUse hook.' })
          onToolDenied?.(name)
          continue
        }
      }
      let decision = 'allow'
      if (!SAFE_TOOLS.has(name) && !parseMCPName(name)) {
        decision = await permissionCallback(name, parsedInput)
      } else if (parseMCPName(name)) {
        decision = await permissionCallback(name, parsedInput)
      }
      if (decision !== 'allow') {
        onToolDenied?.(name)
        decisions.push({ call, denied: true })
        continue
      }
      decisions.push({ call, parsedInput })
    }

    // Run all allowed tool calls in parallel.
    const results = await Promise.all(decisions.map(async ({ call, parsedInput, error, denied, reason }) => {
      if (error) return { call, content: error }
      if (denied) return { call, content: reason || 'User denied this tool call.' }
      const name = call.function.name
      try {
        let result
        const mcp = parseMCPName(name)
        if (mcp) {
          if (!mcpClients || !mcpClients.has(mcp.server)) {
            throw new Error(`MCP server '${mcp.server}' not connected.`)
          }
          result = await callMCPTool(mcpClients, name, parsedInput)
        } else {
          result = await executeTool(name, parsedInput, { cwd: process.cwd() })
        }
        const content = typeof result === 'string' ? result : JSON.stringify(result)
        onToolResult?.(name, content)
        // PostToolUse hook (non-blocking — its only job is logging/auditing).
        if (hooksConfig) {
          await runHooks(hooksConfig, 'PostToolUse', { toolName: name, toolInput: parsedInput, toolResult: content })
        }
        return { call, content }
      } catch (e) {
        const msg = `Error: ${e.message}`
        onToolResult?.(name, msg)
        if (hooksConfig) {
          await runHooks(hooksConfig, 'PostToolUse', { toolName: name, toolInput: parsedInput, toolResult: msg })
        }
        return { call, content: msg }
      }
    }))
    for (const { call, content } of results) {
      finalMessages.push({ role: 'tool', tool_call_id: call.id, content })
    }
    // Loop back to send tool results to the model for the next turn.
  }

  return { messages: finalMessages, aborted: false, exhausted: true }
}
