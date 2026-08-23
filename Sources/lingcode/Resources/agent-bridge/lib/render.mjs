// render.mjs — terminal rendering helpers shared by bin + agent + repl.
//
// All the ANSI / readline / stdin plumbing lives here so the agent loop and
// REPL stay focused on flow control. isTTY is captured once at import time
// (it's just process.stdout.isTTY); ANSI helpers fall through to identity
// functions for non-TTY output so logs to files don't get escape codes.

import readline from 'node:readline'
import process from 'node:process'

export const isTTY = process.stdout.isTTY === true

export const ansi = isTTY
  ? {
      dim: (s) => `\x1b[2m${s}\x1b[0m`,
      bold: (s) => `\x1b[1m${s}\x1b[0m`,
      cyan: (s) => `\x1b[36m${s}\x1b[0m`,
      yellow: (s) => `\x1b[33m${s}\x1b[0m`,
      red: (s) => `\x1b[31m${s}\x1b[0m`,
      green: (s) => `\x1b[32m${s}\x1b[0m`,
    }
  : { dim: (s) => s, bold: (s) => s, cyan: (s) => s, yellow: (s) => s, red: (s) => s, green: (s) => s }

// Compact one-line summary of a tool call. Same format the Mac UI uses.
export function renderToolCall(name, input) {
  let suffix = ''
  if (input && typeof input === 'object') {
    if ((name === 'Read' || name === 'Edit' || name === 'Write') && input.file_path) {
      suffix = ` ${input.file_path}`
    } else if (name === 'Bash' && typeof input.command === 'string') {
      const cmd = input.command.length > 60 ? input.command.slice(0, 57) + '…' : input.command
      suffix = ` ${ansi.dim(cmd)}`
    } else if (name === 'Grep' && input.pattern) {
      suffix = ` "${input.pattern}"${input.path ? ` in ${input.path}` : ''}`
    } else if (name === 'Glob' && input.pattern) {
      suffix = ` ${input.pattern}`
    }
  }
  return ansi.cyan(`[${name}${suffix}]`)
}

// Single-line confirm. Returns true iff the user typed y/yes.
// Use ONLY when no other readline is bound to process.stdin (e.g. `lingcode ask`).
// In the REPL, use promptYesNoVia(rl, ...) instead — two readlines on the same
// stdin race for input and resolve immediately with empty answers.
export function promptYesNo(question) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stderr })
    rl.question(question, (answer) => {
      rl.close()
      const a = (answer || '').trim().toLowerCase()
      resolve(a === 'y' || a === 'yes')
    })
  })
}

// Same as promptYesNo but reuses the caller's existing readline.Interface so
// REPL mode doesn't create a second reader on process.stdin. Does not close
// the passed-in rl — ownership stays with the caller.
export function promptYesNoVia(rl, question) {
  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      const a = (answer || '').trim().toLowerCase()
      resolve(a === 'y' || a === 'yes')
    })
  })
}

// Read all of stdin into a string. Used by `lingcode ask -` / pipe input.
export async function readStdin() {
  let buf = ''
  process.stdin.setEncoding('utf8')
  for await (const chunk of process.stdin) buf += chunk
  return buf
}
