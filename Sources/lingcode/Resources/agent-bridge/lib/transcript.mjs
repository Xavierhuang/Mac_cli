// transcript.mjs — REPL conversation persistence + helpers for @-mentions
// and markdown export.
//
// Persistent session history is opt-in via `lingcode config set saveHistory true`.
// When on, each REPL turn appends to ~/.lingcode/sessions/<session-id>.json so
// `lingcode history` and `lingcode export` can reach it later. Session id is a
// timestamp captured at REPL start.
//
// @-mentions: any token matching @<path> in the user's prompt that resolves to
// a readable file gets its content prepended as a code block. Common pattern
// across modern terminal AI clients (Cursor, Codex, Claude Code).

import { readFile, writeFile, mkdir, readdir } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, isAbsolute, resolve } from 'node:path'
import process from 'node:process'

const SESSIONS_DIR = join(homedir(), '.lingcode', 'sessions')

// Generate a sortable, human-readable session id like `2026-05-12_15-42-08`.
export function newSessionId() {
  const d = new Date()
  const pad = (n) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}_${pad(d.getHours())}-${pad(d.getMinutes())}-${pad(d.getSeconds())}`
}

export async function saveSession(sessionId, transcript) {
  await mkdir(SESSIONS_DIR, { recursive: true })
  const path = join(SESSIONS_DIR, `${sessionId}.json`)
  await writeFile(path, JSON.stringify(transcript, null, 2), 'utf8')
  return path
}

export async function loadSession(sessionId) {
  const path = join(SESSIONS_DIR, `${sessionId}.json`)
  if (!existsSync(path)) return null
  try {
    return JSON.parse(await readFile(path, 'utf8'))
  } catch {
    return null
  }
}

export async function listSessions() {
  if (!existsSync(SESSIONS_DIR)) return []
  const entries = await readdir(SESSIONS_DIR, { withFileTypes: true })
  return entries
    .filter((e) => e.isFile() && e.name.endsWith('.json'))
    .map((e) => e.name.slice(0, -5))
    .sort()
    .reverse() // newest first
}

// Convert an OpenAI-shape message array into a markdown transcript.
// Anthropic-shape sessions are best-effort: we only have the transcript array
// the caller passed; tool messages get folded into the surrounding assistant
// turn so the export is readable rather than a literal trace.
export function renderTranscriptAsMarkdown(transcript, { title = null } = {}) {
  const lines = []
  if (title) lines.push(`# ${title}`, '')
  let pendingTools = []
  for (const msg of transcript) {
    if (msg.role === 'system') continue // boring; usually our default system prompt
    if (msg.role === 'user') {
      // Flush any pending tools first.
      if (pendingTools.length) {
        for (const t of pendingTools) lines.push(t)
        pendingTools = []
      }
      lines.push('## You', '')
      lines.push(stringifyContent(msg.content), '')
      continue
    }
    if (msg.role === 'assistant') {
      lines.push('## Assistant', '')
      const text = stringifyContent(msg.content)
      if (text) lines.push(text, '')
      if (Array.isArray(msg.tool_calls)) {
        for (const tc of msg.tool_calls) {
          lines.push(`> Tool call: \`${tc.function?.name}\``)
          try {
            const input = JSON.parse(tc.function?.arguments || '{}')
            lines.push('> ```json', '> ' + JSON.stringify(input, null, 2).split('\n').join('\n> '), '> ```')
          } catch {
            lines.push('> ' + tc.function?.arguments)
          }
        }
        lines.push('')
      }
      continue
    }
    if (msg.role === 'tool') {
      // Buffer; show before the next user turn so flow reads naturally.
      const content = typeof msg.content === 'string' ? msg.content : JSON.stringify(msg.content)
      const truncated = content.length > 2000 ? content.slice(0, 2000) + '\n… (truncated)' : content
      pendingTools.push(`> Result:\n> \`\`\`\n> ${truncated.split('\n').join('\n> ')}\n> \`\`\``, '')
    }
  }
  // Flush trailing tools.
  for (const t of pendingTools) lines.push(t)
  return lines.join('\n')
}

function stringifyContent(content) {
  if (content == null) return ''
  if (typeof content === 'string') return content
  if (Array.isArray(content)) {
    // OpenAI-shape multi-part content (text + image_url blocks).
    return content
      .map((b) => (b.type === 'text' ? b.text : b.type === 'image_url' ? '(image attached)' : ''))
      .filter(Boolean)
      .join('\n')
  }
  return JSON.stringify(content)
}

// ---- @-mention expansion --------------------------------------------------
// Scan a user prompt for @<path> tokens and prepend the contents of each
// readable file as a code block. Skips files larger than 200 KB (keeps the
// model's context budget intact). Returns the augmented prompt; leaves the
// original mention text in place so the model knows what was attached.
export async function expandAtMentions(text, cwd = process.cwd()) {
  const re = /@([\w./\-_]+(?:\.\w+)?)/g
  const matches = [...text.matchAll(re)]
  if (matches.length === 0) return text
  const blocks = []
  const seen = new Set()
  for (const m of matches) {
    const ref = m[1]
    if (seen.has(ref)) continue
    seen.add(ref)
    const path = isAbsolute(ref) ? ref : resolve(cwd, ref)
    if (!existsSync(path)) continue
    try {
      const content = await readFile(path, 'utf8')
      if (content.length > 200_000) {
        blocks.push(`[${ref} skipped — over 200KB; use the Read tool with offset/limit instead]`)
        continue
      }
      blocks.push(`[Content of ${ref}]:\n\`\`\`\n${content}\n\`\`\``)
    } catch {
      /* skip unreadable */
    }
  }
  if (blocks.length === 0) return text
  return blocks.join('\n\n') + '\n\n' + text
}
