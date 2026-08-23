// plugins.mjs — file-system discovery for Claude-Code-spec extensions:
//   .claude/commands/<name>.md         custom slash commands
//   .claude/skills/<name>/SKILL.md     model-invocable skills
//   .mcp.json                          MCP server config (project-local)
//   ~/.claude/<same>                   user-global versions
//   ~/.claude/plugins/installed_plugins.json + each plugin's skills/ subdir
//
// All sources are scanned at REPL startup / each ask invocation, merged
// project-first (project shadows user-global shadows plugins).

import { readdir, readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

// ---- Frontmatter parser (YAML-lite). Same shape Claude Code uses ----------
function parseFrontmatter(text) {
  if (!text.startsWith('---\n')) return { meta: {}, body: text }
  const end = text.indexOf('\n---', 4)
  if (end === -1) return { meta: {}, body: text }
  const block = text.slice(4, end)
  const body = text.slice(end + 4).replace(/^\n/, '')
  const meta = {}
  for (const line of block.split('\n')) {
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*)$/)
    if (!m) continue
    let value = m[2].trim()
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1)
    }
    if (value === 'true') value = true
    else if (value === 'false') value = false
    meta[m[1]] = value
  }
  return { meta, body }
}

// ---- Slash commands -------------------------------------------------------
// Returns: Map<commandName, { description, body, allowedTools, sourcePath }>
//   commandName excludes the leading slash and the `.md` extension.
export async function discoverCommands(cwd) {
  const out = new Map()
  // User-global first, project last so project wins.
  const dirs = [join(homedir(), '.claude', 'commands'), join(cwd, '.claude', 'commands')]
  for (const dir of dirs) {
    if (!existsSync(dir)) continue
    let entries = []
    try {
      entries = await readdir(dir, { withFileTypes: true })
    } catch {
      continue
    }
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith('.md')) continue
      const name = entry.name.slice(0, -3)
      const file = join(dir, entry.name)
      try {
        const text = await readFile(file, 'utf8')
        const { meta, body } = parseFrontmatter(text)
        out.set(name, {
          description: typeof meta.description === 'string' ? meta.description : '',
          body: body.trimEnd(),
          allowedTools: typeof meta['allowed-tools'] === 'string' ? meta['allowed-tools'] : null,
          sourcePath: file,
        })
      } catch {
        /* skip malformed file */
      }
    }
  }
  return out
}

// Expand a `/<command> <args>` line. Returns null if not a command, else the
// expanded prompt text (with $ARGUMENTS and $1..$9 substituted).
export function expandCommand(commands, line) {
  const m = line.match(/^\/(\S+)(.*)$/)
  if (!m) return null
  const name = m[1]
  const argsStr = m[2].trim()
  const cmd = commands.get(name)
  if (!cmd) return null
  const argv = argsStr.length > 0 ? argsStr.split(/\s+/) : []
  let body = cmd.body
  body = body.replace(/\$ARGUMENTS/g, argsStr)
  for (let i = 1; i <= 9; i++) {
    body = body.replace(new RegExp(`\\$${i}\\b`, 'g'), argv[i - 1] || '')
  }
  return body
}

// ---- Skills ---------------------------------------------------------------
// Returns array of { name, description, body, modelInvocable, sourcePath }.
// Discovery order (later overrides earlier on name collision):
//   1. ~/.claude/plugins/<plugin>/skills/  (e.g. superpowers)
//   2. ~/.claude/skills/                    (user-global)
//   3. <cwd>/.claude/skills/                (project)
export async function discoverSkills(cwd) {
  const out = []
  for (const skill of await loadPluginSkills()) out.push(skill)
  const dirs = [join(homedir(), '.claude', 'skills'), join(cwd, '.claude', 'skills')]
  for (const dir of dirs) {
    if (!existsSync(dir)) continue
    let entries = []
    try {
      entries = await readdir(dir, { withFileTypes: true })
    } catch {
      continue
    }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue
      const skillFile = join(dir, entry.name, 'SKILL.md')
      if (!existsSync(skillFile)) continue
      try {
        const text = await readFile(skillFile, 'utf8')
        const { meta, body } = parseFrontmatter(text)
        const name = typeof meta.name === 'string' && meta.name ? meta.name : entry.name
        const modelInvocable = meta['disable-model-invocation'] !== true
        out.push({
          name,
          description: typeof meta.description === 'string' ? meta.description : '',
          body: body.trimEnd(),
          modelInvocable,
          sourcePath: skillFile,
        })
      } catch {
        /* skip */
      }
    }
  }
  // Later sources (project) shadow earlier (user, plugins) by name.
  const dedup = new Map()
  for (const s of out) dedup.set(s.name, s)
  return [...dedup.values()]
}

// Walk ~/.claude/plugins/installed_plugins.json and pull every plugin's
// skills/<name>/SKILL.md. Plugin key is "<plugin-name>@<marketplace>"; we
// expose the bare plugin name as the skill's source for provenance.
async function loadPluginSkills() {
  const manifestPath = join(homedir(), '.claude', 'plugins', 'installed_plugins.json')
  if (!existsSync(manifestPath)) return []
  let manifest
  try {
    manifest = JSON.parse(await readFile(manifestPath, 'utf8'))
  } catch {
    return []
  }
  const plugins = manifest?.plugins
  if (!plugins || typeof plugins !== 'object') return []
  const out = []
  for (const [key, installs] of Object.entries(plugins)) {
    if (!Array.isArray(installs) || installs.length === 0) continue
    const install = installs[0]
    const installPath = install?.installPath
    if (typeof installPath !== 'string') continue
    const skillsDir = join(installPath, 'skills')
    if (!existsSync(skillsDir)) continue
    let entries = []
    try {
      entries = await readdir(skillsDir, { withFileTypes: true })
    } catch {
      continue
    }
    const pluginName = key.split('@')[0]
    for (const entry of entries) {
      if (!entry.isDirectory()) continue
      const skillFile = join(skillsDir, entry.name, 'SKILL.md')
      if (!existsSync(skillFile)) continue
      try {
        const text = await readFile(skillFile, 'utf8')
        const { meta, body } = parseFrontmatter(text)
        const name = typeof meta.name === 'string' && meta.name ? meta.name : entry.name
        const modelInvocable = meta['disable-model-invocation'] !== true
        const baseDesc = typeof meta.description === 'string' ? meta.description : ''
        out.push({
          name,
          description: baseDesc ? `${baseDesc} [plugin: ${pluginName}]` : `[plugin: ${pluginName}]`,
          body: body.trimEnd(),
          modelInvocable,
          sourcePath: skillFile,
        })
      } catch {
        /* skip */
      }
    }
  }
  return out
}

// Build a single string suitable for appendSystemPrompt: enumerate the
// model-invocable skills with their descriptions. The model decides when
// to ask the user to invoke a skill (we don't auto-load bodies).
export function buildSkillIndex(skills) {
  const usable = skills.filter((s) => s.modelInvocable)
  if (usable.length === 0) return null
  const lines = ['Available skills (mention by name when relevant):']
  for (const s of usable) {
    lines.push(`- ${s.name}: ${s.description || '(no description)'}`)
  }
  return lines.join('\n')
}

// ---- MCP servers ----------------------------------------------------------
// .mcp.json shape:
//   {
//     "mcpServers": {
//       "name": { "type": "stdio", "command": "node", "args": ["..."], "env": {...} },
//       "other": { "type": "http", "url": "...", "headers": {...} }
//     }
//   }
// We honor project .mcp.json + user ~/.claude/mcp.json; project entries win on
// name collision.
export async function discoverMCPServers(cwd) {
  const candidates = [
    join(homedir(), '.claude', 'mcp.json'),
    join(cwd, '.mcp.json'),
  ]
  const merged = {}
  for (const file of candidates) {
    if (!existsSync(file)) continue
    try {
      const parsed = JSON.parse(await readFile(file, 'utf8'))
      const servers = parsed?.mcpServers
      if (servers && typeof servers === 'object') {
        for (const [name, cfg] of Object.entries(servers)) merged[name] = cfg
      }
    } catch {
      /* skip malformed */
    }
  }
  return Object.keys(merged).length > 0 ? merged : null
}

// ---- Hooks ----------------------------------------------------------------
// .claude/hooks/hooks.json shape (Claude Code spec):
//   { "hooks": { "PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "..." }] }], ... } }
// We pass this object straight to the Anthropic SDK's `hooks` option (it
// understands the spec). For OpenAI-compat we don't run hooks in v0.4.
export async function discoverHooks(cwd) {
  const merged = { hooks: {} }
  const candidates = [
    join(homedir(), '.claude', 'hooks', 'hooks.json'),
    join(cwd, '.claude', 'hooks', 'hooks.json'),
  ]
  let any = false
  for (const file of candidates) {
    if (!existsSync(file)) continue
    try {
      const parsed = JSON.parse(await readFile(file, 'utf8'))
      if (parsed?.hooks && typeof parsed.hooks === 'object') {
        for (const [event, list] of Object.entries(parsed.hooks)) {
          if (!Array.isArray(list)) continue
          if (!merged.hooks[event]) merged.hooks[event] = []
          merged.hooks[event].push(...list)
          any = true
        }
      }
    } catch {
      /* skip */
    }
  }
  return any ? merged : null
}

// ---- Subagents ------------------------------------------------------------
// Claude-Code-spec subagents at .claude/agents/<name>.md with frontmatter
// (description, tools, model). The Anthropic SDK accepts them straight via
// its `agents` option as { name: { description, prompt, tools?, model? } }.
// OpenAI-compat doesn't natively support subagent delegation, so this only
// affects the three Anthropic-shape providers.
export async function discoverAgents(cwd) {
  const merged = {}
  const dirs = [join(homedir(), '.claude', 'agents'), join(cwd, '.claude', 'agents')]
  for (const dir of dirs) {
    if (!existsSync(dir)) continue
    let entries = []
    try {
      entries = await readdir(dir, { withFileTypes: true })
    } catch {
      continue
    }
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith('.md')) continue
      const name = entry.name.slice(0, -3)
      try {
        const text = await readFile(join(dir, entry.name), 'utf8')
        const { meta, body } = parseFrontmatter(text)
        merged[name] = {
          description: typeof meta.description === 'string' ? meta.description : '',
          prompt: body.trimEnd(),
          ...(typeof meta.tools === 'string' ? { tools: meta.tools.split(',').map((s) => s.trim()).filter(Boolean) } : {}),
          ...(typeof meta.model === 'string' ? { model: meta.model } : {}),
        }
      } catch {
        /* skip */
      }
    }
  }
  return Object.keys(merged).length > 0 ? merged : null
}

// Sweep all five discoveries in parallel — convenience for the CLI entry.
export async function discoverAll(cwd) {
  const [commands, skills, mcpServers, hooks, agents] = await Promise.all([
    discoverCommands(cwd),
    discoverSkills(cwd),
    discoverMCPServers(cwd),
    discoverHooks(cwd),
    discoverAgents(cwd),
  ])
  return { commands, skills, mcpServers, hooks, agents }
}
