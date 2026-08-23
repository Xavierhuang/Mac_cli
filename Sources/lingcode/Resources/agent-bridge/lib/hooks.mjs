// hooks.mjs — Claude-Code-spec hook runner for the OpenAI-compat agent loop.
//
// hooks.json shape (loaded by lib/plugins.mjs::discoverHooks):
//   { "hooks": { "PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "..." }] }], ... } }
//
// Events we honor here:
//   - UserPromptSubmit  fires before each user message goes to the model
//   - PreToolUse        fires before a tool executes; can block via exit 1
//                       or by emitting JSON {"decision":"block","reason":"..."}
//                       on stdout
//   - PostToolUse       fires after a tool returns; result is logged via the
//                       hook command; not blocking
//   - Stop              fires when the agent loop finishes (or is aborted)
//
// Env vars set for each spawned hook (matches Claude Code's contract):
//   LINGCODE_HOOK_EVENT, LINGCODE_TOOL_NAME, LINGCODE_TOOL_INPUT,
//   LINGCODE_TOOL_RESULT, LINGCODE_USER_PROMPT, LINGCODE_CWD
//   plus parallel CLAUDE_* aliases for compatibility with hooks authored
//   against Claude Code's docs.

import { spawn } from 'node:child_process'
import process from 'node:process'

function matchEntries(hooksConfig, event, toolName) {
  if (!hooksConfig || typeof hooksConfig !== 'object') return []
  const entries = Array.isArray(hooksConfig[event]) ? hooksConfig[event] : []
  const out = []
  for (const entry of entries) {
    const matcher = entry?.matcher
    if (matcher && toolName) {
      try {
        if (!new RegExp(`^${matcher}$`).test(toolName)) continue
      } catch {
        // Treat bad regex as a literal name match.
        if (matcher !== toolName) continue
      }
    }
    if (Array.isArray(entry.hooks)) {
      for (const h of entry.hooks) {
        if (h?.type === 'command' && typeof h.command === 'string') out.push(h.command)
      }
    }
  }
  return out
}

function runCommand(command, env, { timeout = 10000 } = {}) {
  return new Promise((resolve) => {
    const isWin = process.platform === 'win32'
    const shell = isWin ? 'cmd.exe' : '/bin/sh'
    const args = isWin ? ['/d', '/s', '/c', command] : ['-c', command]
    const proc = spawn(shell, args, { env })
    let stdout = ''
    let stderr = ''
    const timer = setTimeout(() => {
      try { proc.kill('SIGTERM') } catch { /* ignore */ }
    }, timeout)
    proc.stdout.on('data', (d) => { stdout += d.toString() })
    proc.stderr.on('data', (d) => { stderr += d.toString() })
    proc.on('error', () => {
      clearTimeout(timer)
      resolve({ exitCode: -1, stdout, stderr })
    })
    proc.on('close', (code) => {
      clearTimeout(timer)
      resolve({ exitCode: code ?? -1, stdout, stderr })
    })
  })
}

function tryParseDecision(stdout) {
  // Hook can emit {"decision":"block","reason":"..."} on stdout to block.
  const trimmed = stdout.trim()
  if (!trimmed.startsWith('{')) return null
  try {
    return JSON.parse(trimmed)
  } catch {
    return null
  }
}

// runHooks — invoke every matching hook for the given event. Returns:
//   { blocked: bool, reason: string|null }
// PreToolUse + UserPromptSubmit honor blocking; other events ignore exit code.
export async function runHooks(hooksConfig, event, context = {}) {
  if (!hooksConfig) return { blocked: false, reason: null }
  const commands = matchEntries(hooksConfig, event, context.toolName)
  if (commands.length === 0) return { blocked: false, reason: null }

  const env = {
    ...process.env,
    LINGCODE_HOOK_EVENT: event,
    LINGCODE_CWD: process.cwd(),
    CLAUDE_HOOK_EVENT: event,
    CLAUDE_CWD: process.cwd(),
    ...(context.toolName ? { LINGCODE_TOOL_NAME: context.toolName, CLAUDE_TOOL_NAME: context.toolName } : {}),
    ...(context.toolInput !== undefined
      ? {
          LINGCODE_TOOL_INPUT: JSON.stringify(context.toolInput),
          CLAUDE_TOOL_INPUT: JSON.stringify(context.toolInput),
        }
      : {}),
    ...(context.toolResult !== undefined
      ? {
          LINGCODE_TOOL_RESULT: typeof context.toolResult === 'string' ? context.toolResult.slice(0, 8000) : JSON.stringify(context.toolResult).slice(0, 8000),
          CLAUDE_TOOL_RESULT: typeof context.toolResult === 'string' ? context.toolResult.slice(0, 8000) : JSON.stringify(context.toolResult).slice(0, 8000),
        }
      : {}),
    ...(context.userPrompt
      ? { LINGCODE_USER_PROMPT: context.userPrompt, CLAUDE_USER_PROMPT: context.userPrompt }
      : {}),
  }

  const blockingEvent = event === 'PreToolUse' || event === 'UserPromptSubmit'
  for (const command of commands) {
    const { exitCode, stdout, stderr } = await runCommand(command, env)
    const decision = tryParseDecision(stdout)
    if (blockingEvent) {
      if (decision?.decision === 'block') {
        return { blocked: true, reason: decision.reason || 'Blocked by hook.' }
      }
      if (exitCode !== 0) {
        return { blocked: true, reason: stderr.trim() || `Hook exited ${exitCode}.` }
      }
    }
    // For non-blocking events, surface non-zero exits to stderr so the user knows.
    if (!blockingEvent && exitCode !== 0) {
      process.stderr.write(`[hook ${event} exit ${exitCode}] ${stderr.trim()}\n`)
    }
  }
  return { blocked: false, reason: null }
}
