// Calls the bundled `rtk hook claude` subcommand to rewrite Bash tool
// commands per Claude Code's PreToolUse hook spec. rtk reads a JSON
// envelope on stdin and emits `hookSpecificOutput.updatedInput.command`
// when it wants to rewrite (e.g. `git status` -> `rtk git status`),
// cutting tool_result tokens 60-90% on common dev commands.
//
// Failure policy: ANY error returns null. Callers run the raw command.
// First failure per process is logged once; subsequent failures are
// silent so a broken rtk doesn't spam logs.

import { spawn } from 'node:child_process'

let firstFailureLogged = false

function logFirstFailure(reason) {
  if (firstFailureLogged) return
  firstFailureLogged = true
  // eslint-disable-next-line no-console
  console.error(`[agent-bridge] rtk rewrite failed; disabling for this session: ${reason}`)
}

/**
 * Rewrite a Bash command via `rtk hook claude`.
 *
 * @param {string} rtkPath  Absolute path to the rtk binary.
 * @param {string} command  The user-supplied bash command string.
 * @param {string} cwd      Working directory for the command.
 * @param {number} timeoutMs  Wall clock cap for the rewrite (default 2000ms).
 * @returns {Promise<string|null>} The rewritten command, or null on any failure.
 */
export async function rtkRewriteCommand(rtkPath, command, cwd, timeoutMs = 2000) {
  if (!rtkPath) return null

  const envelope = JSON.stringify({
    session_id: 'lingcode-bridge',
    transcript_path: '',
    cwd,
    hook_event_name: 'PreToolUse',
    tool_name: 'Bash',
    tool_input: { command, description: '' }
  })

  return new Promise((resolve) => {
    let settled = false
    const settle = (value) => {
      if (settled) return
      settled = true
      resolve(value)
    }

    let child
    try {
      child = spawn(rtkPath, ['hook', 'claude'], {
        cwd,
        stdio: ['pipe', 'pipe', 'pipe']
      })
    } catch (err) {
      logFirstFailure(`spawn: ${err?.message ?? err}`)
      settle(null)
      return
    }

    const timer = setTimeout(() => {
      try { child.kill('SIGTERM') } catch { /* ignore */ }
      logFirstFailure('timeout')
      settle(null)
    }, timeoutMs)

    let stdoutBuf = ''
    child.stdout.on('data', (d) => { stdoutBuf += d.toString() })
    child.stderr.on('data', () => { /* discard */ })

    child.on('error', (err) => {
      clearTimeout(timer)
      logFirstFailure(`process error: ${err?.message ?? err}`)
      settle(null)
    })

    child.on('close', (code) => {
      clearTimeout(timer)
      if (code !== 0) {
        logFirstFailure(`non-zero exit ${code}`)
        settle(null)
        return
      }
      try {
        const parsed = JSON.parse(stdoutBuf)
        const updated = parsed?.hookSpecificOutput?.updatedInput?.command
        if (typeof updated === 'string' && updated.length > 0) {
          settle(updated)
        } else {
          settle(null)
        }
      } catch (err) {
        logFirstFailure(`parse: ${err?.message ?? err}`)
        settle(null)
      }
    })

    try {
      child.stdin.write(envelope)
      child.stdin.end()
    } catch (err) {
      clearTimeout(timer)
      try { child.kill('SIGTERM') } catch { /* ignore */ }
      logFirstFailure(`stdin: ${err?.message ?? err}`)
      settle(null)
    }
  })
}
