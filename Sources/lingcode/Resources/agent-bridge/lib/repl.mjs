// repl.mjs — interactive `lingcode` REPL loop.
//
// Reads lines from stdin, handles built-in /slash-commands, expands user-
// authored .claude/commands/*.md, and forwards everything else to the agent
// loop. Session state lives in this function's scope — provider can be
// switched per-turn via /use, conversation can be wiped via /reset, plugins
// re-scanned via /reload.

import readline from 'node:readline'
import process from 'node:process'
import { writeFile } from 'node:fs/promises'

import { activeAccount } from './auth.mjs'
import { streamOnce } from './agent.mjs'
import { discoverAll, expandCommand } from './plugins.mjs'
import { isTTY, ansi, promptYesNoVia } from './render.mjs'
import {
  newSessionId,
  saveSession,
  loadSession,
  expandAtMentions,
  renderTranscriptAsMarkdown,
} from './transcript.mjs'

export async function cmdRepl(version, { resumeId = null, persist = false } = {}) {
  let plugins = await discoverAll(process.cwd())

  // Transcript id + buffer (kept even if persistence is off, so /export
  // works mid-session). Resume by loading a saved transcript if --resume given.
  // Distinct from the per-turn Anthropic SDK session_id below.
  const transcriptId = resumeId || newSessionId()
  let transcript = []
  if (resumeId) {
    const loaded = await loadSession(resumeId)
    if (loaded) {
      transcript = loaded
      if (isTTY) process.stdout.write(ansi.dim(`(resumed session ${resumeId} — ${transcript.length} prior messages)\n`))
    } else {
      if (isTTY) process.stdout.write(ansi.red(`(session '${resumeId}' not found; starting fresh)\n`))
    }
  }

  if (isTTY) {
    let activeName = '(none)'
    try {
      const a = await activeAccount()
      if (a) activeName = a._name
    } catch { /* ignore */ }
    const extras = []
    if (plugins.commands.size > 0) extras.push(`${plugins.commands.size} command${plugins.commands.size === 1 ? '' : 's'}`)
    if (plugins.skills.length > 0) extras.push(`${plugins.skills.length} skill${plugins.skills.length === 1 ? '' : 's'}`)
    if (plugins.mcpServers) extras.push(`${Object.keys(plugins.mcpServers).length} MCP`)
    if (plugins.hooks) extras.push('hooks')
    if (plugins.agents) extras.push(`${Object.keys(plugins.agents).length} agent${Object.keys(plugins.agents).length === 1 ? '' : 's'}`)
    const extraStr = extras.length ? `, ${extras.join(', ')}` : ''
    process.stdout.write(
      `lingcode v${version}  ${ansi.dim(`(provider: ${activeName}${extraStr}, Ctrl-D to exit, /help)`)}\n`
    )
  }

  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    prompt: ansi.bold('> '),
    terminal: isTTY,
  })
  let rlClosed = false
  rl.on('close', () => { rlClosed = true })
  const _origPrompt = rl.prompt.bind(rl)
  const safePrompt = () => { if (!rlClosed) _origPrompt() }
  // Permission gate reuses this rl — a second readline on stdin would race
  // for input and resolve every Y/N prompt immediately with an empty answer.
  // Also serialize prompts via a Promise chain: when the model emits multiple
  // tool calls in one turn, the SDK fires canUseTool concurrently, and Node's
  // readline only tracks one pending question callback — a second rl.question
  // would overwrite the first's callback and orphan it. The queue makes the
  // user answer them one at a time, in arrival order.
  let _promptQueue = Promise.resolve()
  const prompter = (question) => {
    const next = _promptQueue.then(() => promptYesNoVia(rl, question))
    _promptQueue = next.catch(() => {})
    return next
  }

  let sessionId = null              // Anthropic-shape: SDK-managed
  let priorMessages = null          // OpenAI-compat: in-memory history
  let permissionMode = 'default'
  let providerOverride = null

  rl.on('SIGINT', () => {
    if (rlClosed) return
    process.stdout.write('\n')
    rl.prompt()
  })
  safePrompt()

  for await (const line of rl) {
    const trimmed = line.trim()
    if (!trimmed) { safePrompt(); continue }
    if (trimmed === '/exit' || trimmed === '/quit') break

    if (trimmed === '/help') {
      process.stdout.write(
        `Built-in commands:\n` +
          `  /reset            Forget conversation\n` +
          `  /yolo on|off      Bypass tool permissions\n` +
          `  /use <provider>   Switch active provider for next turn\n` +
          `  /status           Show active provider + plugin counts\n` +
          `  /reload           Re-scan .claude/ for commands/skills/MCP/hooks/agents\n` +
          `  /commands         List discovered custom commands\n` +
          `  /skills           List discovered skills\n` +
          `  /agents           List discovered subagents (Anthropic-shape only)\n` +
          `  /export <path>    Save conversation as markdown\n` +
          `  /help             This message\n` +
          `  /exit             Quit\n\n` +
          `Inline: @path/to/file in your prompt attaches the file contents.\n`
      )
      if (plugins.commands.size > 0) {
        process.stdout.write(`\nCustom commands (from .claude/commands/):\n`)
        for (const [name, cmd] of plugins.commands) {
          process.stdout.write(`  /${name.padEnd(20)} ${ansi.dim(cmd.description || '')}\n`)
        }
      }
      safePrompt(); continue
    }
    if (trimmed === '/reload') {
      plugins = await discoverAll(process.cwd())
      process.stdout.write(
        ansi.dim(`(reloaded — ${plugins.commands.size} commands, ${plugins.skills.length} skills, ${plugins.mcpServers ? Object.keys(plugins.mcpServers).length : 0} MCP servers)\n`)
      )
      safePrompt(); continue
    }
    if (trimmed === '/commands') {
      if (plugins.commands.size === 0) {
        process.stdout.write(ansi.dim('(no custom commands; create one at .claude/commands/<name>.md)\n'))
      } else {
        for (const [name, cmd] of plugins.commands) {
          process.stdout.write(`/${name.padEnd(20)} ${ansi.dim(cmd.description || '(no description)')}\n`)
        }
      }
      safePrompt(); continue
    }
    if (trimmed === '/skills') {
      if (plugins.skills.length === 0) {
        process.stdout.write(ansi.dim('(no skills; create one at .claude/skills/<name>/SKILL.md)\n'))
      } else {
        for (const s of plugins.skills) {
          const inv = s.modelInvocable ? ansi.green('✓') : ansi.dim('×')
          process.stdout.write(`${inv} ${s.name.padEnd(20)} ${ansi.dim(s.description || '(no description)')}\n`)
        }
      }
      safePrompt(); continue
    }
    if (trimmed === '/agents') {
      const list = plugins.agents ? Object.entries(plugins.agents) : []
      if (list.length === 0) {
        process.stdout.write(ansi.dim('(no subagents; create one at .claude/agents/<name>.md)\n'))
      } else {
        for (const [name, agent] of list) {
          process.stdout.write(`  ${name.padEnd(20)} ${ansi.dim(agent.description || '(no description)')}\n`)
        }
        process.stdout.write(ansi.dim('(only used by the Anthropic-shape providers — lingmodel/anthropic/deepseek-claude)\n'))
      }
      safePrompt(); continue
    }
    if (trimmed === '/reset') {
      sessionId = null
      priorMessages = null
      process.stdout.write(ansi.dim('(conversation reset)\n'))
      safePrompt(); continue
    }
    const yolo = trimmed.match(/^\/yolo\s+(on|off)$/)
    if (yolo) {
      permissionMode = yolo[1] === 'on' ? 'bypassPermissions' : 'default'
      process.stdout.write(ansi.dim(`(permissions: ${permissionMode})\n`))
      safePrompt(); continue
    }
    const use = trimmed.match(/^\/use\s+(\S+)$/)
    if (use) {
      providerOverride = use[1]
      process.stdout.write(ansi.dim(`(provider for next turn: ${providerOverride})\n`))
      safePrompt(); continue
    }
    if (trimmed === '/status') {
      try {
        const a = await activeAccount()
        process.stdout.write(
          ansi.dim(
            `(active: ${a?._name || '(none)'}, override: ${providerOverride || '(none)'}, permissions: ${permissionMode})\n`
          )
        )
      } catch (e) {
        process.stdout.write(ansi.red(`(error: ${e.message})\n`))
      }
      safePrompt(); continue
    }

    // /export <path> — render the transcript as markdown to a file.
    const exportMatch = trimmed.match(/^\/export\s+(.+)$/)
    if (exportMatch) {
      const path = exportMatch[1].trim()
      if (transcript.length === 0 && (!priorMessages || priorMessages.length === 0)) {
        process.stdout.write(ansi.dim('(no conversation to export — start chatting first)\n'))
      } else {
        const source = priorMessages && priorMessages.length > 0 ? priorMessages : transcript
        const md = renderTranscriptAsMarkdown(source, { title: `lingcode session ${transcriptId}` })
        try {
          await writeFile(path, md, 'utf8')
          process.stdout.write(ansi.dim(`(wrote ${md.length} bytes to ${path})\n`))
        } catch (e) {
          process.stderr.write(ansi.red(`(export failed: ${e.message})\n`))
        }
      }
      safePrompt(); continue
    }

    // Custom slash-command expansion. If the user typed /<name> and we have
    // a matching custom command, expand it; otherwise reject unknown slashes
    // before they hit the model.
    let promptText = trimmed
    if (trimmed.startsWith('/')) {
      const expanded = expandCommand(plugins.commands, trimmed)
      if (expanded !== null) {
        promptText = expanded
        process.stdout.write(ansi.dim(`(expanded ${trimmed.split(/\s+/)[0]})\n`))
      } else {
        process.stdout.write(ansi.dim(`(unknown slash command — try /help)\n`))
        safePrompt(); continue
      }
    }

    // @-mention expansion: @path/to/file in the prompt → contents prepended
    // as a code block before the user's question.
    promptText = await expandAtMentions(promptText, process.cwd())

    try {
      transcript.push({ role: 'user', content: trimmed })
      const r = await streamOnce(promptText, { sessionId, priorMessages, permissionMode, providerOverride, plugins, prompter })
      sessionId = r.sessionId
      priorMessages = r.messages || null
      // For OpenAI-shape we get the full message array back; mirror it into
      // the transcript so /export sees the assistant turn (the agent loop
      // already streamed the text to stdout in real time).
      if (r.messages && r.messages.length > 0) {
        const assistantTurn = r.messages[r.messages.length - 1]
        if (assistantTurn?.role === 'assistant') transcript.push(assistantTurn)
      }
      // Persist if the user opted into saveHistory.
      if (persist) {
        try { await saveSession(transcriptId, transcript) } catch { /* ignore */ }
      }
      providerOverride = null // single-turn override
    } catch (error) {
      process.stderr.write(`lingcode: ${error.message}\n`)
    }
    safePrompt()
  }
  // Final flush — save on exit even if per-turn persist was off.
  if (persist && transcript.length > 0) {
    try { await saveSession(transcriptId, transcript) } catch { /* ignore */ }
    process.stdout.write(ansi.dim(`(session saved as ${transcriptId})\n`))
  }
  process.stdout.write(ansi.dim('\nbye.\n'))
  // Make sure the readline is fully torn down before this function resolves.
  // Without this, an `/exit`/`/quit` break out of the for-await leaves rl
  // open, stdin keeps the event loop alive, and `await cmdRepl(...)` at
  // bin/lingcode.mjs:137 reports an unsettled top-level await.
  if (!rlClosed) {
    await new Promise((resolve) => {
      rl.once('close', resolve)
      rl.close()
    })
  }
}
