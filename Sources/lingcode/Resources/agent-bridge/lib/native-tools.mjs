// native-tools.mjs — JS implementations of the core Claude-Code-style tools
// that we expose to OpenAI-compat models (DeepSeek native + the 11 OpenAI
// providers). Each tool returns a string result (or a JSON-serializable
// object) that becomes the "content" of the role:tool message back to the
// model.
//
// Subset chosen to mirror the Anthropic SDK's built-ins that the Mac app
// already ships: Read, Write, Edit, Bash, Grep, Glob, LS. Notable omissions:
// MultiEdit (callers can chain Edits), WebFetch (different security profile),
// NotebookEdit (specialized; deferred).

import { readFile, writeFile, readdir, stat, mkdir } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { dirname, isAbsolute, join, resolve } from 'node:path'
import process from 'node:process'
import { rtkRewriteCommand } from '../rtk.mjs'

// Tool schemas in OpenAI function-call shape. Returned as-is to providers'
// /chat/completions `tools` parameter.
export const TOOL_SCHEMAS = [
  {
    type: 'function',
    function: {
      name: 'Read',
      description: 'Read a file from the filesystem. Returns its contents as text. For large files, prefer specifying offset/limit to read a window.',
      parameters: {
        type: 'object',
        properties: {
          file_path: { type: 'string', description: 'Absolute path to the file.' },
          offset: { type: 'integer', description: '1-indexed starting line (optional).' },
          limit: { type: 'integer', description: 'Maximum number of lines to return (optional, default 2000).' },
        },
        required: ['file_path'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'Write',
      description: 'Write content to a file, overwriting if it exists. Creates parent directories if needed. Prefer Edit when modifying an existing file.',
      parameters: {
        type: 'object',
        properties: {
          file_path: { type: 'string', description: 'Absolute path to the file.' },
          content: { type: 'string', description: 'Full file contents to write.' },
        },
        required: ['file_path', 'content'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'Edit',
      description: 'Replace an exact string in a file with new content. Errors if old_string is not unique unless replace_all is true. The file must exist.',
      parameters: {
        type: 'object',
        properties: {
          file_path: { type: 'string', description: 'Absolute path to the file.' },
          old_string: { type: 'string', description: 'Exact text to replace (must match exactly, including whitespace).' },
          new_string: { type: 'string', description: 'Replacement text.' },
          replace_all: { type: 'boolean', description: 'Replace every occurrence (default false).' },
        },
        required: ['file_path', 'old_string', 'new_string'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'Bash',
      description: 'Run a shell command. Returns stdout+stderr (combined). 30-second default timeout. Cwd defaults to the user\'s current directory.',
      parameters: {
        type: 'object',
        properties: {
          command: { type: 'string', description: 'Shell command to execute (uses /bin/sh on Unix, cmd.exe on Windows).' },
          cwd: { type: 'string', description: 'Working directory (optional, defaults to user cwd).' },
          timeout: { type: 'integer', description: 'Timeout in milliseconds (default 30000, max 600000).' },
        },
        required: ['command'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'Grep',
      description: 'Search file contents for a regex pattern. Returns matching file:line:text lines.',
      parameters: {
        type: 'object',
        properties: {
          pattern: { type: 'string', description: 'Regex pattern to search for.' },
          path: { type: 'string', description: 'Directory or file to search (default: cwd).' },
          glob: { type: 'string', description: 'File glob to restrict the search (e.g. "*.swift").' },
          case_insensitive: { type: 'boolean' },
        },
        required: ['pattern'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'Glob',
      description: 'Find files matching a glob pattern (e.g. "src/**/*.ts"). Returns absolute paths, one per line.',
      parameters: {
        type: 'object',
        properties: {
          pattern: { type: 'string', description: 'Glob pattern (supports **, *, ?).' },
          path: { type: 'string', description: 'Base directory to glob from (default: cwd).' },
        },
        required: ['pattern'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'LS',
      description: 'List files and directories in the given path. Returns names with type markers.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Absolute path to list (default: cwd).' },
        },
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'WebFetch',
      description: 'Fetch an HTTP/HTTPS URL and return its text content. HTML tags are stripped to keep the response readable. Output is capped at ~30 KB.',
      parameters: {
        type: 'object',
        properties: {
          url: { type: 'string', description: 'http(s):// URL to fetch.' },
          prompt: { type: 'string', description: 'Optional hint about what to extract (purely informational; the tool returns full stripped text).' },
        },
        required: ['url'],
      },
    },
  },
]

// Tools whose execution can't mutate the filesystem or run shell commands —
// auto-approve in TTY without prompting. WebFetch is deliberately NOT here
// (it talks to arbitrary servers and can leak referrer info / IPs).
export const SAFE_TOOLS = new Set(['Read', 'Glob', 'Grep', 'LS'])

function absPath(p, cwd = process.cwd()) {
  if (!p) return cwd
  return isAbsolute(p) ? p : resolve(cwd, p)
}

function clamp(n, min, max, fallback) {
  if (typeof n !== 'number' || !Number.isFinite(n)) return fallback
  return Math.max(min, Math.min(max, Math.floor(n)))
}

// ---- Tool execution dispatch ----

export async function executeTool(name, input, { cwd = process.cwd() } = {}) {
  switch (name) {
    case 'Read':     return await execRead(input, cwd)
    case 'Write':    return await execWrite(input, cwd)
    case 'Edit':     return await execEdit(input, cwd)
    case 'Bash':     return await execBash(input, cwd)
    case 'Grep':     return await execGrep(input, cwd)
    case 'Glob':     return await execGlob(input, cwd)
    case 'LS':       return await execLS(input, cwd)
    case 'WebFetch': return await execWebFetch(input)
    default:
      throw new Error(`Unknown tool: ${name}`)
  }
}

async function execWebFetch(input) {
  const url = typeof input.url === 'string' ? input.url.trim() : ''
  if (!/^https?:\/\//i.test(url)) {
    throw new Error('WebFetch: url must start with http:// or https://')
  }
  let res
  try {
    res = await fetch(url, {
      headers: { 'User-Agent': 'lingcode-cli/0.12 (+https://lingcode.dev)' },
      redirect: 'follow',
    })
  } catch (error) {
    throw new Error(`WebFetch: network error: ${error.message}`)
  }
  if (!res.ok) throw new Error(`WebFetch: HTTP ${res.status} from ${url}`)
  let text = await res.text()
  // Crude HTML → text. Strips script/style blocks, then all tags, then collapses whitespace.
  text = text
    .replace(/<script[\s\S]*?<\/script>/gi, '')
    .replace(/<style[\s\S]*?<\/style>/gi, '')
    .replace(/<!--[\s\S]*?-->/g, '')
    .replace(/<\/(p|div|h\d|li|tr|br|hr)[^>]*>/gi, '\n')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/[ \t]+/g, ' ')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
  const MAX = 30000
  if (text.length > MAX) {
    text = text.slice(0, MAX) + `\n[…truncated, ${text.length - MAX} more bytes]`
  }
  return text
}

async function execRead(input, cwd) {
  const file = absPath(input.file_path, cwd)
  if (!existsSync(file)) throw new Error(`File not found: ${file}`)
  const text = await readFile(file, 'utf8')
  const lines = text.split('\n')
  const offset = clamp(input.offset, 1, lines.length, 1) - 1
  const limit = clamp(input.limit, 1, 10000, 2000)
  const slice = lines.slice(offset, offset + limit)
  // Number lines (1-indexed) so the model can reference them later in Edits.
  return slice.map((line, i) => `${(offset + i + 1).toString().padStart(5)}→${line}`).join('\n')
}

async function execWrite(input, cwd) {
  const file = absPath(input.file_path, cwd)
  if (typeof input.content !== 'string') throw new Error('Write: content must be a string.')
  await mkdir(dirname(file), { recursive: true })
  await writeFile(file, input.content, 'utf8')
  const bytes = Buffer.byteLength(input.content, 'utf8')
  return `Wrote ${bytes} bytes to ${file}.`
}

async function execEdit(input, cwd) {
  const file = absPath(input.file_path, cwd)
  if (!existsSync(file)) throw new Error(`File not found: ${file}`)
  const original = await readFile(file, 'utf8')
  if (typeof input.old_string !== 'string' || typeof input.new_string !== 'string') {
    throw new Error('Edit: old_string and new_string must be strings.')
  }
  if (input.old_string === input.new_string) {
    throw new Error('Edit: old_string and new_string are identical — no edit performed.')
  }
  const count = (original.match(new RegExp(input.old_string.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g')) || []).length
  if (count === 0) throw new Error(`Edit: old_string not found in ${file}.`)
  if (count > 1 && !input.replace_all) {
    throw new Error(`Edit: old_string occurs ${count} times in ${file}. Set replace_all: true, or provide a more unique old_string.`)
  }
  const updated = input.replace_all
    ? original.split(input.old_string).join(input.new_string)
    : original.replace(input.old_string, input.new_string)
  await writeFile(file, updated, 'utf8')
  return `Replaced ${count} occurrence(s) in ${file}.`
}

async function execBash(input, cwd) {
  const command = typeof input.command === 'string' ? input.command : null
  if (!command) throw new Error('Bash: command is required.')
  const timeout = clamp(input.timeout, 100, 600000, 30000)
  const runCwd = input.cwd ? absPath(input.cwd, cwd) : cwd

  // RTK rewrite: when the bundled rtk binary is configured, give it ~2s
  // to swap the command (e.g. `git status` -> `rtk git status`) so the
  // model receives compact output. Falls through to the raw command on
  // any failure -- never blocks. PATH gets the rtk dir prepended so the
  // rewritten `rtk ...` command resolves to the bundled binary.
  let effectiveCommand = command
  let childEnv = process.env
  if (process.env.LINGCODE_RTK_PATH && process.env.LINGCODE_RTK !== '0') {
    const rewritten = await rtkRewriteCommand(process.env.LINGCODE_RTK_PATH, command, runCwd)
    if (rewritten) {
      effectiveCommand = rewritten
      const rtkDir = dirname(process.env.LINGCODE_RTK_PATH)
      childEnv = { ...process.env, PATH: `${rtkDir}:${process.env.PATH ?? ''}` }
    }
  }

  return new Promise((resolve, reject) => {
    const isWin = process.platform === 'win32'
    const shell = isWin ? 'cmd.exe' : '/bin/sh'
    const shellArgs = isWin ? ['/d', '/s', '/c', effectiveCommand] : ['-c', effectiveCommand]
    const proc = spawn(shell, shellArgs, { cwd: runCwd, env: childEnv })
    const outChunks = []
    let timedOut = false
    const timer = setTimeout(() => {
      timedOut = true
      proc.kill('SIGTERM')
    }, timeout)
    proc.stdout.on('data', (d) => { outChunks.push(d) })
    proc.stderr.on('data', (d) => { outChunks.push(d) })
    proc.on('error', (err) => {
      clearTimeout(timer)
      reject(err)
    })
    proc.on('close', (code) => {
      clearTimeout(timer)
      if (timedOut) {
        outChunks.push(Buffer.from(`\n[timed out after ${timeout}ms]`))
      }
      let out = Buffer.concat(outChunks).toString()
      // Truncate runaway output so we don't blow the model's context.
      const MAX = 40000
      if (out.length > MAX) {
        out = out.slice(0, MAX) + `\n[…output truncated, ${out.length - MAX} bytes elided]`
      }
      resolve(`exit ${code}${timedOut ? ' (killed)' : ''}\n${out}`)
    })
  })
}

function execGrep(input, cwd) {
  const pattern = typeof input.pattern === 'string' ? input.pattern : null
  if (!pattern) throw new Error('Grep: pattern is required.')
  const path = input.path ? absPath(input.path, cwd) : cwd
  const args = ['--no-heading', '--line-number', '--with-filename']
  if (input.case_insensitive) args.push('-i')
  if (input.glob) args.push('--glob', input.glob)
  args.push(pattern, path)

  return new Promise((resolve, reject) => {
    const proc = spawn('rg', args, { cwd })
    const outChunks = []
    proc.stdout.on('data', (d) => { outChunks.push(d) })
    proc.stderr.on('data', (d) => { outChunks.push(d) })
    proc.on('error', (err) => {
      if (err.code === 'ENOENT') {
        // ripgrep not installed — return a clear message rather than a crash.
        resolve(`(ripgrep not found on PATH; install via \`brew install ripgrep\` or apt/winget. Grep tool requires rg.)`)
      } else {
        reject(err)
      }
    })
    proc.on('close', () => {
      let out = Buffer.concat(outChunks).toString()
      const MAX = 30000
      if (out.length > MAX) out = out.slice(0, MAX) + `\n[…truncated]`
      resolve(out || '(no matches)')
    })
  })
}

async function execGlob(input, cwd) {
  const pattern = typeof input.pattern === 'string' ? input.pattern : null
  if (!pattern) throw new Error('Glob: pattern is required.')
  const base = input.path ? absPath(input.path, cwd) : cwd

  // Convert glob to regex. Supports ** (any depth), * (segment), ? (single).
  const regex = globToRegex(pattern)
  const results = []
  await walkDir(base, base, regex, results, 0)
  results.sort()
  return results.length === 0 ? '(no matches)' : results.slice(0, 1000).join('\n')
}

function globToRegex(glob) {
  // Escape regex special chars except glob ones.
  let re = ''
  let i = 0
  while (i < glob.length) {
    const ch = glob[i]
    if (ch === '*' && glob[i + 1] === '*') {
      re += '.*'
      i += 2
      if (glob[i] === '/') i++
    } else if (ch === '*') {
      re += '[^/]*'
      i++
    } else if (ch === '?') {
      re += '[^/]'
      i++
    } else if ('.+^${}()|[]\\'.includes(ch)) {
      re += '\\' + ch
      i++
    } else {
      re += ch
      i++
    }
  }
  return new RegExp('^' + re + '$')
}

async function walkDir(base, dir, regex, results, depth) {
  if (depth > 12) return // safety
  let entries
  try {
    entries = await readdir(dir, { withFileTypes: true })
  } catch {
    return
  }
  for (const entry of entries) {
    // Skip noise that explodes traversal time.
    if (entry.name === 'node_modules' || entry.name === '.git' || entry.name.startsWith('.DS_Store')) continue
    const full = join(dir, entry.name)
    const rel = full.slice(base.length + 1).split('\\').join('/')
    if (entry.isDirectory()) {
      await walkDir(base, full, regex, results, depth + 1)
    } else if (regex.test(rel)) {
      results.push(full)
    }
  }
}

async function execLS(input, cwd) {
  const path = input.path ? absPath(input.path, cwd) : cwd
  const entries = await readdir(path, { withFileTypes: true })
  const lines = []
  for (const e of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    if (e.isDirectory()) lines.push(`${e.name}/`)
    else if (e.isSymbolicLink()) lines.push(`${e.name}@`)
    else {
      try {
        const s = await stat(join(path, e.name))
        lines.push(`${e.name} (${s.size}b)`)
      } catch {
        lines.push(e.name)
      }
    }
  }
  return lines.join('\n')
}
