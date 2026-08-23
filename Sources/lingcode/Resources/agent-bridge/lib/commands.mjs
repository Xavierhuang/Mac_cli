// commands.mjs — the smaller "utility" subcommands that don't justify their
// own file: doctor / init / mcp / config / completion / history.
//
// Bigger ones (auth, serve) live in their own files.

import { existsSync } from 'node:fs'
import { readFile, writeFile, mkdir, readdir } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { execSync } from 'node:child_process'
import process from 'node:process'
import { loadCredentials } from './auth.mjs'
import { discoverAll } from './plugins.mjs'

const LINGCODE_DIR = join(homedir(), '.lingcode')
const CONFIG_PATH = join(LINGCODE_DIR, 'config.json')

// ---- doctor ---------------------------------------------------------------
export async function cmdDoctor() {
  const checks = []
  const ok = (label, detail) => checks.push({ ok: true, label, detail })
  const warn = (label, detail) => checks.push({ ok: false, label, detail })

  // Node version
  ok(`node ${process.version}`, `${process.platform}/${process.arch}`)

  // Bundled SDK
  const sdkPath = join(import.meta.dirname || dirname(new URL(import.meta.url).pathname), '..', 'sdk-bundle.mjs')
  if (existsSync(sdkPath)) ok('sdk-bundle.mjs', sdkPath)
  else warn('sdk-bundle.mjs', `not found at ${sdkPath} — Anthropic-shape providers will not work.`)

  // claude-code cli.js
  const cliJs = join(import.meta.dirname || dirname(new URL(import.meta.url).pathname), '..', 'node_modules', '@anthropic-ai', 'claude-agent-sdk', 'cli.js')
  if (existsSync(cliJs)) ok('claude-agent-sdk cli.js', cliJs)
  else warn('claude-agent-sdk cli.js', 'run `npm install` inside this package.')

  // Credentials
  const store = await loadCredentials()
  const count = Object.keys(store.accounts).length
  if (count > 0) ok(`credentials`, `${count} account(s), active: ${store.active}`)
  else warn(`credentials`, 'no accounts — run `lingcode auth login`.')

  // ripgrep (used by Grep tool)
  try {
    const rg = execSync(process.platform === 'win32' ? 'where rg' : 'which rg', { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim()
    if (rg) ok('ripgrep', rg)
    else throw new Error('not found')
  } catch {
    warn('ripgrep', 'not on PATH — the Grep tool will fail. Install via brew/apt/winget.')
  }

  // Plugins
  const plugins = await discoverAll(process.cwd())
  const summary = []
  if (plugins.commands.size > 0) summary.push(`${plugins.commands.size} commands`)
  if (plugins.skills.length > 0) summary.push(`${plugins.skills.length} skills`)
  if (plugins.mcpServers) summary.push(`${Object.keys(plugins.mcpServers).length} MCP`)
  if (plugins.hooks) summary.push('hooks')
  if (plugins.agents) summary.push(`${Object.keys(plugins.agents).length} agents`)
  ok('plugins', summary.length > 0 ? summary.join(', ') : '(none discovered)')

  // Provider env vars present
  const envSet = []
  for (const env of ['ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'DEEPSEEK_API_KEY', 'GROQ_API_KEY', 'GEMINI_API_KEY']) {
    if (process.env[env]) envSet.push(env)
  }
  if (envSet.length > 0) ok('env vars', envSet.join(', '))

  // Render report
  for (const c of checks) {
    const mark = c.ok ? '\x1b[32m✓\x1b[0m' : '\x1b[33m⚠\x1b[0m'
    process.stdout.write(`${mark} ${c.label.padEnd(28)} ${c.detail}\n`)
  }
  const anyWarn = checks.some((c) => !c.ok)
  if (anyWarn) process.exitCode = 1
}

// ---- init -----------------------------------------------------------------
// Generates a minimal CLAUDE.md at the project root. Idempotent — won't
// overwrite an existing file.
export async function cmdInit(args) {
  let target = process.cwd()
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--path' && args[i + 1]) {
      target = args[i + 1]
      i++
    }
  }
  const claudeMd = join(target, 'CLAUDE.md')
  if (existsSync(claudeMd) && !args.includes('--force')) {
    console.error(`init: CLAUDE.md already exists at ${claudeMd}. Pass --force to overwrite.`)
    process.exit(64)
  }
  const projectName = target.split('/').pop() || 'project'
  const template = `# CLAUDE.md

Guidance for AI coding agents (Claude Code, lingcode, Codex, Gemini CLI) working in this repo.

## Project

${projectName} — describe the project in one or two sentences.

## Run / build / test

\`\`\`bash
# How does someone build this?
# How are tests run?
\`\`\`

## Conventions

- Code style, linting, formatting rules
- Where business logic lives vs. wiring code
- Anything an agent should NEVER do without asking

## Where to look next

- README.md
- docs/
`
  await writeFile(claudeMd, template, 'utf8')
  console.log(`✓ Wrote ${claudeMd}.`)
}

// ---- mcp (project .mcp.json management) -----------------------------------

// Built-in registry of well-known MCP servers (mirrors the Swift CLI's
// MCP.swift table). Names are short slugs; the install command writes the
// full spawn spec into .mcp.json.
const MCP_REGISTRY = {
  filesystem: {
    description: 'Read/write files in a sandboxed root',
    config: { type: 'stdio', command: 'npx', args: ['-y', '@modelcontextprotocol/server-filesystem', '.'] },
  },
  github: {
    description: 'GitHub API access (issues, PRs, files)',
    config: { type: 'stdio', command: 'npx', args: ['-y', '@modelcontextprotocol/server-github'], env: { GITHUB_PERSONAL_ACCESS_TOKEN: '<set me>' } },
  },
  fetch: {
    description: 'HTTP fetch / read web pages',
    config: { type: 'stdio', command: 'npx', args: ['-y', '@modelcontextprotocol/server-fetch'] },
  },
  memory: {
    description: 'Persistent knowledge graph',
    config: { type: 'stdio', command: 'npx', args: ['-y', '@modelcontextprotocol/server-memory'] },
  },
  sqlite: {
    description: 'Query SQLite databases',
    config: { type: 'stdio', command: 'npx', args: ['-y', '@modelcontextprotocol/server-sqlite', '--db-path', '<path>'] },
  },
  postgres: {
    description: 'Query Postgres databases',
    config: { type: 'stdio', command: 'npx', args: ['-y', '@modelcontextprotocol/server-postgres', '<connection-string>'] },
  },
  puppeteer: {
    description: 'Browser automation (Chrome via Puppeteer)',
    config: { type: 'stdio', command: 'npx', args: ['-y', '@modelcontextprotocol/server-puppeteer'] },
  },
  brave: {
    description: 'Brave Search API',
    config: { type: 'stdio', command: 'npx', args: ['-y', '@modelcontextprotocol/server-brave-search'], env: { BRAVE_API_KEY: '<set me>' } },
  },
}

async function readMCPProject() {
  const path = join(process.cwd(), '.mcp.json')
  if (!existsSync(path)) return { path, data: { mcpServers: {} } }
  try {
    return { path, data: JSON.parse(await readFile(path, 'utf8')) }
  } catch (error) {
    throw new Error(`Failed to read ${path}: ${error.message}`)
  }
}

async function writeMCPProject(path, data) {
  await writeFile(path, JSON.stringify(data, null, 2) + '\n', 'utf8')
}

export async function cmdMCP(args) {
  const sub = args[0]
  const rest = args.slice(1)
  switch (sub) {
    case 'search': {
      for (const [name, entry] of Object.entries(MCP_REGISTRY)) {
        process.stdout.write(`  ${name.padEnd(14)} ${entry.description}\n`)
      }
      return
    }
    case 'install': {
      const name = rest[0]
      if (!name) { console.error('mcp install: usage: lingcode mcp install <name>'); process.exit(64) }
      const entry = MCP_REGISTRY[name]
      if (!entry) { console.error(`mcp install: '${name}' is not in the built-in registry. Run \`lingcode mcp search\` for the list.`); process.exit(64) }
      const { path, data } = await readMCPProject()
      data.mcpServers = data.mcpServers || {}
      data.mcpServers[name] = entry.config
      await writeMCPProject(path, data)
      console.log(`✓ Added '${name}' to ${path}.`)
      if (entry.config.env) {
        for (const [k, v] of Object.entries(entry.config.env)) {
          if (v === '<set me>') console.log(`  ⚠ Set ${k} in .mcp.json (currently '<set me>').`)
        }
      }
      return
    }
    case 'list': {
      const { path, data } = await readMCPProject()
      const names = Object.keys(data.mcpServers || {})
      if (names.length === 0) {
        console.log(`(no MCP servers in ${path})`)
      } else {
        for (const n of names) {
          const cfg = data.mcpServers[n]
          process.stdout.write(`  ${n.padEnd(14)} ${cfg.command}${cfg.args ? ' ' + cfg.args.join(' ') : ''}\n`)
        }
      }
      return
    }
    case 'remove': {
      const name = rest[0]
      if (!name) { console.error('mcp remove: usage: lingcode mcp remove <name>'); process.exit(64) }
      const { path, data } = await readMCPProject()
      if (!data.mcpServers?.[name]) {
        console.error(`mcp remove: no server '${name}' in ${path}.`)
        process.exit(64)
      }
      delete data.mcpServers[name]
      await writeMCPProject(path, data)
      console.log(`✓ Removed '${name}' from ${path}.`)
      return
    }
    default:
      console.error(`mcp: unknown subcommand '${sub || ''}'.`)
      console.error('Usage: lingcode mcp <search|install|list|remove> [...]')
      process.exit(64)
  }
}

// ---- config ---------------------------------------------------------------
async function loadConfig() {
  if (!existsSync(CONFIG_PATH)) return {}
  try {
    return JSON.parse(await readFile(CONFIG_PATH, 'utf8'))
  } catch {
    return {}
  }
}
async function saveConfig(obj) {
  await mkdir(LINGCODE_DIR, { recursive: true })
  await writeFile(CONFIG_PATH, JSON.stringify(obj, null, 2) + '\n', 'utf8')
}

export async function cmdConfig(args) {
  const sub = args[0]
  const rest = args.slice(1)
  switch (sub) {
    case 'get': {
      const key = rest[0]
      if (!key) { console.error('config get: missing key'); process.exit(64) }
      const cfg = await loadConfig()
      if (key in cfg) process.stdout.write(String(cfg[key]) + '\n')
      else process.exit(1)
      return
    }
    case 'set': {
      const [key, value] = rest
      if (!key || value === undefined) { console.error('config set: usage: lingcode config set <key> <value>'); process.exit(64) }
      const cfg = await loadConfig()
      cfg[key] = value
      await saveConfig(cfg)
      console.log(`✓ ${key} = ${value}`)
      return
    }
    case 'unset': {
      const key = rest[0]
      if (!key) { console.error('config unset: missing key'); process.exit(64) }
      const cfg = await loadConfig()
      delete cfg[key]
      await saveConfig(cfg)
      console.log(`✓ unset ${key}`)
      return
    }
    case 'list': {
      const cfg = await loadConfig()
      const keys = Object.keys(cfg).sort()
      if (keys.length === 0) console.log('(no config — try `lingcode config set <key> <value>`)')
      else for (const k of keys) process.stdout.write(`${k} = ${cfg[k]}\n`)
      return
    }
    default:
      console.error(`config: unknown subcommand '${sub || ''}'.`)
      console.error('Usage: lingcode config <get|set|unset|list>')
      process.exit(64)
  }
}

// ---- completion -----------------------------------------------------------
// Print a shell completion script for bash/zsh/fish/pwsh.
export function cmdCompletion(args) {
  const shell = args[0] || 'bash'
  const cmds = 'auth ask repl doctor init mcp config completion serve history'
  switch (shell) {
    case 'bash':
      process.stdout.write(`# lingcode bash completion. Source from ~/.bashrc:
#   eval "$(lingcode completion bash)"
_lingcode() {
  local cur prev cmds
  COMPREPLY=()
  cur="\${COMP_WORDS[COMP_CWORD]}"
  prev="\${COMP_WORDS[COMP_CWORD-1]}"
  if [ "\$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=( \$(compgen -W "${cmds}" -- "\$cur") )
    return
  fi
  case "\${COMP_WORDS[1]}" in
    auth) COMPREPLY=( \$(compgen -W "login status list use delete set get logout export import" -- "\$cur") );;
    mcp) COMPREPLY=( \$(compgen -W "search install list remove" -- "\$cur") );;
    config) COMPREPLY=( \$(compgen -W "get set unset list" -- "\$cur") );;
    completion) COMPREPLY=( \$(compgen -W "bash zsh fish pwsh" -- "\$cur") );;
  esac
}
complete -F _lingcode lingcode
`)
      return
    case 'zsh':
      process.stdout.write(`# lingcode zsh completion. Source from ~/.zshrc:
#   eval "$(lingcode completion zsh)"
_lingcode() {
  local -a cmds
  cmds=(${cmds.split(' ').map((c) => `'${c}'`).join(' ')})
  _describe 'command' cmds
}
compdef _lingcode lingcode
`)
      return
    case 'fish':
      process.stdout.write(`# lingcode fish completion. Save as ~/.config/fish/completions/lingcode.fish.
complete -c lingcode -n "__fish_use_subcommand" -a "${cmds}"
complete -c lingcode -n "__fish_seen_subcommand_from auth" -a "login status list use delete set get logout export import"
complete -c lingcode -n "__fish_seen_subcommand_from mcp" -a "search install list remove"
complete -c lingcode -n "__fish_seen_subcommand_from config" -a "get set unset list"
complete -c lingcode -n "__fish_seen_subcommand_from completion" -a "bash zsh fish pwsh"
`)
      return
    case 'pwsh':
    case 'powershell':
      process.stdout.write(`# lingcode PowerShell completion. Add to your $PROFILE:
#   Invoke-Expression (lingcode completion pwsh | Out-String)
Register-ArgumentCompleter -CommandName lingcode -ScriptBlock {
  param($wordToComplete, $commandAst, $cursorPosition)
  $cmds = '${cmds.split(' ').join("','")}'.Split(',')
  $sub = $commandAst.CommandElements[1].Value
  $sub2 = switch ($sub) {
    'auth'   { 'login','status','list','use','delete','set','get','logout','export','import' }
    'mcp'    { 'search','install','list','remove' }
    'config' { 'get','set','unset','list' }
    'completion' { 'bash','zsh','fish','pwsh' }
    default  { $cmds }
  }
  $sub2 | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
  }
}
`)
      return
    default:
      console.error(`completion: unsupported shell '${shell}'. Use bash | zsh | fish | pwsh.`)
      process.exit(64)
  }
}

// ---- plugin install/list/remove ------------------------------------------
// Manage Claude-Code-spec plugins under ~/.claude/plugins/<name>/. A plugin
// is any directory containing .claude-plugin/plugin.json. We support three
// install sources: local path, https tarball, git repo (https/ssh URL or
// owner/repo shorthand).

const PLUGINS_DIR = join(homedir(), '.claude', 'plugins')

async function readPluginManifest(dir) {
  const path = join(dir, '.claude-plugin', 'plugin.json')
  if (!existsSync(path)) return null
  try {
    return JSON.parse(await readFile(path, 'utf8'))
  } catch {
    return null
  }
}

export async function cmdPlugin(args) {
  const sub = args[0]
  const rest = args.slice(1)
  switch (sub) {
    case 'list':        return cmdPluginList()
    case 'install':     return cmdPluginInstall(rest)
    case 'remove':      return cmdPluginRemove(rest)
    case 'search':      return cmdPluginSearch(rest)
    case 'marketplace': return cmdMarketplace(rest)
    default:
      console.error(`plugin: unknown subcommand '${sub || ''}'.`)
      console.error('Usage: lingcode plugin <list|install|remove|search|marketplace> [...]')
      process.exit(64)
  }
}

// ---- Plugin marketplaces --------------------------------------------------
// A marketplace is a git repo cloned to ~/.claude/marketplaces/<name>/ with a
// `marketplace.json` (or .claude-plugin/marketplace.json) at the root.
// Marketplace shape (Claude-Code spec):
//   { "name": "...", "plugins": [{ "name": "...", "description": "...",
//                                  "source": "owner/repo" or full URL }] }
const MARKETPLACES_DIR = join(homedir(), '.claude', 'marketplaces')

async function readMarketplaceManifest(dir) {
  for (const p of ['marketplace.json', join('.claude-plugin', 'marketplace.json')]) {
    const path = join(dir, p)
    if (existsSync(path)) {
      try { return JSON.parse(await readFile(path, 'utf8')) } catch { return null }
    }
  }
  return null
}

async function cmdMarketplace(args) {
  const sub = args[0]
  const rest = args.slice(1)
  switch (sub) {
    case 'add': {
      const [name, source] = rest
      if (!name || !source) {
        console.error('plugin marketplace add: usage: lingcode plugin marketplace add <name> <git-url-or-owner/repo>')
        process.exit(64)
      }
      await mkdir(MARKETPLACES_DIR, { recursive: true })
      const dest = join(MARKETPLACES_DIR, name)
      if (existsSync(dest)) {
        console.error(`marketplace add: '${name}' already registered at ${dest}.`)
        process.exit(64)
      }
      const repoURL = /^[\w-]+\/[\w.-]+$/.test(source) ? `https://github.com/${source}.git` : source
      try {
        execSync(`git clone --depth 1 "${repoURL}" "${dest}"`, { stdio: 'inherit' })
      } catch (error) {
        console.error(`marketplace add: git clone failed: ${error.message}`)
        process.exit(1)
      }
      const manifest = await readMarketplaceManifest(dest)
      const plugins = Array.isArray(manifest?.plugins) ? manifest.plugins.length : 0
      console.log(`✓ Registered marketplace '${name}' (${plugins} plugin${plugins === 1 ? '' : 's'}).`)
      return
    }
    case 'list': {
      if (!existsSync(MARKETPLACES_DIR)) {
        console.log('(no marketplaces — add with `lingcode plugin marketplace add <name> <git>`)')
        return
      }
      const entries = await readdir(MARKETPLACES_DIR, { withFileTypes: true })
      for (const e of entries) {
        if (!e.isDirectory()) continue
        const manifest = await readMarketplaceManifest(join(MARKETPLACES_DIR, e.name))
        const count = Array.isArray(manifest?.plugins) ? manifest.plugins.length : '?'
        process.stdout.write(`  ${e.name.padEnd(22)} ${count} plugin(s)\n`)
      }
      return
    }
    case 'remove': {
      const name = rest[0]
      if (!name) { console.error('marketplace remove: usage: lingcode plugin marketplace remove <name>'); process.exit(64) }
      const dir = join(MARKETPLACES_DIR, name)
      if (!existsSync(dir)) { console.error(`marketplace remove: '${name}' not registered.`); process.exit(64) }
      const { rm } = await import('node:fs/promises')
      await rm(dir, { recursive: true, force: true })
      console.log(`✓ Unregistered '${name}'.`)
      return
    }
    default:
      console.error(`plugin marketplace: unknown subcommand '${sub || ''}'.`)
      console.error('Usage: lingcode plugin marketplace <add|list|remove> [...]')
      process.exit(64)
  }
}

async function cmdPluginList() {
  if (!existsSync(PLUGINS_DIR)) {
    console.log('(no plugins installed; install via `lingcode plugin install <path|url|owner/repo>`)')
    return
  }
  const entries = await readdir(PLUGINS_DIR, { withFileTypes: true })
  let found = 0
  for (const e of entries) {
    if (!e.isDirectory()) continue
    const dir = join(PLUGINS_DIR, e.name)
    const manifest = await readPluginManifest(dir)
    if (!manifest) continue
    found++
    const desc = manifest.description || '(no description)'
    process.stdout.write(`  ${e.name.padEnd(28)} ${desc}\n`)
  }
  if (found === 0) console.log('(no plugins with .claude-plugin/plugin.json found)')
}

function pluginNameFromSource(src) {
  // owner/repo → repo
  if (/^[\w-]+\/[\w.-]+$/.test(src)) return src.split('/')[1]
  // git URL → last segment minus .git
  const lastSlash = src.lastIndexOf('/')
  if (lastSlash >= 0) {
    return src
      .slice(lastSlash + 1)
      .replace(/\.git$/, '')
      .replace(/\.tar\.gz$/, '')
      .replace(/\.zip$/, '')
  }
  return src.split('/').filter(Boolean).pop() || 'plugin'
}

// Resolve a marketplace-qualified source like `claude-code-setup@claude-plugins-official`
// to a concrete source the rest of cmdPluginInstall already understands (path /
// URL / owner-repo). Returns { source, name } — name is the marketplace entry's
// canonical name when present so we don't drop it during path-derivation later.
// Pass-through for un-qualified sources.
async function resolveMarketplaceSource(source) {
  const at = source.lastIndexOf('@')
  // Reject `@start` and `trailing@` — those aren't marketplace syntax. Owner/repo
  // shorthand never contains '@', so any '@' in the middle means marketplace.
  if (at <= 0 || at >= source.length - 1) return { source, name: null }
  const pluginName = source.slice(0, at)
  const marketName = source.slice(at + 1)
  const marketDir = join(MARKETPLACES_DIR, marketName)
  if (!existsSync(marketDir)) {
    console.error(`plugin install: marketplace '${marketName}' is not registered.`)
    console.error(`  Add it with: lingcode plugin marketplace add ${marketName} <owner/repo or git url>`)
    process.exit(64)
  }
  const manifest = await readMarketplaceManifest(marketDir)
  const entry = Array.isArray(manifest?.plugins)
    ? manifest.plugins.find((p) => p?.name === pluginName)
    : null
  if (!entry?.source) {
    console.error(`plugin install: '${pluginName}' not found in marketplace '${marketName}'.`)
    console.error(`  Run \`lingcode plugin search ${pluginName}\` to list available plugins.`)
    process.exit(64)
  }
  // Marketplace entries' `source` can be:
  //   - "owner/repo" or a git/https URL — passes through to the existing git/tarball logic.
  //   - "./subdir" or "subdir" — a plugin colocated inside the marketplace repo (the
  //     pattern Anthropic's claude-plugins-official uses). Resolve against marketDir
  //     so the existing isLocal branch copies the subdirectory.
  let resolved = entry.source
  if (resolved.startsWith('./') || resolved.startsWith('../') || resolved === '.') {
    resolved = join(marketDir, resolved)
  } else if (!resolved.includes('://') && !/^[\w-]+\/[\w.-]+$/.test(resolved)) {
    const sub = join(marketDir, resolved)
    if (existsSync(sub)) resolved = sub
  }
  return { source: resolved, name: pluginName }
}

async function cmdPluginInstall(args) {
  const raw = args[0]
  if (!raw) {
    console.error('plugin install: usage: lingcode plugin install <path|https-url|owner/repo|name@marketplace>')
    process.exit(64)
  }
  const resolved = await resolveMarketplaceSource(raw)
  const source = resolved.source
  await mkdir(PLUGINS_DIR, { recursive: true })
  const name = resolved.name || pluginNameFromSource(source)
  const dest = join(PLUGINS_DIR, name)
  if (existsSync(dest) && !args.includes('--force')) {
    console.error(`plugin install: ${dest} already exists. Pass --force to replace.`)
    process.exit(64)
  }

  // Decide install strategy from source shape.
  const isLocal = existsSync(source)
  const isTarball = /^https?:\/\/.*\.(tar\.gz|tgz|zip)$/.test(source)
  const isGit = !isLocal && !isTarball

  if (isLocal) {
    // Copy directory recursively.
    const { cp } = await import('node:fs/promises')
    if (existsSync(dest)) {
      const { rm } = await import('node:fs/promises')
      await rm(dest, { recursive: true, force: true })
    }
    await cp(source, dest, { recursive: true })
  } else if (isGit) {
    // owner/repo shorthand → expand to GitHub HTTPS.
    const repoURL = /^[\w-]+\/[\w.-]+$/.test(source) ? `https://github.com/${source}.git` : source
    if (existsSync(dest)) {
      const { rm } = await import('node:fs/promises')
      await rm(dest, { recursive: true, force: true })
    }
    try {
      execSync(`git clone --depth 1 "${repoURL}" "${dest}"`, { stdio: 'inherit' })
    } catch (error) {
      console.error(`plugin install: git clone failed: ${error.message}`)
      process.exit(1)
    }
  } else if (isTarball) {
    // Download + extract. Use tar -xz (available on macOS/Linux out of the
    // box, and bundled with Git for Windows).
    const { writeFile } = await import('node:fs/promises')
    const buf = await (await fetch(source)).arrayBuffer()
    const tmp = join(homedir(), '.lingcode', `plugin-${Date.now()}.tmp`)
    await writeFile(tmp, Buffer.from(buf))
    await mkdir(dest, { recursive: true })
    try {
      if (source.endsWith('.zip')) {
        // Use unzip on Unix; on Windows, fall back to PowerShell Expand-Archive.
        if (process.platform === 'win32') {
          execSync(`powershell -Command "Expand-Archive -Path '${tmp}' -DestinationPath '${dest}' -Force"`, { stdio: 'inherit' })
        } else {
          execSync(`unzip -q -o "${tmp}" -d "${dest}"`, { stdio: 'inherit' })
        }
      } else {
        execSync(`tar -xzf "${tmp}" -C "${dest}" --strip-components=1`, { stdio: 'inherit' })
      }
    } catch (error) {
      console.error(`plugin install: extraction failed: ${error.message}`)
      process.exit(1)
    }
  }

  const manifest = await readPluginManifest(dest)
  if (!manifest) {
    console.error(`plugin install: ⚠ no .claude-plugin/plugin.json found in ${dest}. Plugin probably won't load.`)
  } else {
    console.log(`✓ Installed ${manifest.name || name}: ${manifest.description || '(no description)'}`)
  }
  // Consent prompt for plugins that ship hooks/bin (Claude-Code-spec rule).
  const hasHooks = existsSync(join(dest, 'hooks', 'hooks.json'))
  const hasBin = existsSync(join(dest, 'bin'))
  if (hasHooks || hasBin) {
    console.log(`  ⚠ This plugin ships ${[hasHooks && 'hooks', hasBin && 'bin/'].filter(Boolean).join(' + ')}. ` +
                `It will run shell commands. Review before invoking.`)
  }
}

async function cmdPluginRemove(args) {
  const name = args[0]
  if (!name) {
    console.error('plugin remove: usage: lingcode plugin remove <name>')
    process.exit(64)
  }
  const dir = join(PLUGINS_DIR, name)
  if (!existsSync(dir)) {
    console.error(`plugin remove: ${dir} does not exist.`)
    process.exit(64)
  }
  const { rm } = await import('node:fs/promises')
  await rm(dir, { recursive: true, force: true })
  console.log(`✓ Removed ${dir}.`)
}

async function cmdPluginSearch(args) {
  const query = (args[0] || '').toLowerCase()
  if (!existsSync(MARKETPLACES_DIR)) {
    console.log('(no marketplaces registered — add one with `lingcode plugin marketplace add <name> <git>`)')
    return
  }
  const entries = await readdir(MARKETPLACES_DIR, { withFileTypes: true })
  let total = 0
  for (const e of entries) {
    if (!e.isDirectory()) continue
    const manifest = await readMarketplaceManifest(join(MARKETPLACES_DIR, e.name))
    if (!Array.isArray(manifest?.plugins)) continue
    for (const p of manifest.plugins) {
      if (!p?.name) continue
      const hay = `${p.name} ${p.description || ''}`.toLowerCase()
      if (query && !hay.includes(query)) continue
      process.stdout.write(`  ${(e.name + '/' + p.name).padEnd(32)} ${p.description || ''}\n`)
      if (p.source) process.stdout.write(`    install: lingcode plugin install ${p.source}\n`)
      total++
    }
  }
  if (total === 0) console.log(`(no matches${query ? ` for "${query}"` : ''})`)
}

// ---- telemetry ------------------------------------------------------------
// Toggle the telemetry flag. We don't actually send anything anywhere — this
// just sets the config flag for compat with the Swift CLI's surface.
export async function cmdTelemetry(args) {
  const sub = args[0]
  const cfg = await loadConfig()
  if (!sub || sub === 'status') {
    const enabled = cfg.telemetry === 'on' || cfg.telemetry === true
    console.log(`telemetry: ${enabled ? 'on' : 'off'}`)
    console.log('(this CLI does not collect any telemetry; the flag is for spec parity)')
    return
  }
  if (sub === 'on') { cfg.telemetry = 'on'; await saveConfig(cfg); console.log('✓ telemetry: on (no-op — nothing is collected)'); return }
  if (sub === 'off') { cfg.telemetry = 'off'; await saveConfig(cfg); console.log('✓ telemetry: off'); return }
  console.error("telemetry: usage: lingcode telemetry <on|off|status>")
  process.exit(64)
}

// ---- upgrade --------------------------------------------------------------
// Check the latest version on GitHub releases and print instructions. We don't
// auto-swap the binary because npm-install-g layouts vary and silent
// over-the-air updates surprise users.
export async function cmdUpgrade() {
  const RELEASES_URL = 'https://api.github.com/repos/Xavierhuang/LingCode/releases'
  console.log('Checking for newer lingcode releases…')
  let releases
  try {
    const res = await fetch(RELEASES_URL, { headers: { Accept: 'application/vnd.github+json' } })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    releases = await res.json()
  } catch (error) {
    console.error(`upgrade: couldn't reach GitHub: ${error.message}`)
    process.exit(1)
  }
  const cliTags = (Array.isArray(releases) ? releases : []).filter((r) => r.tag_name?.startsWith('cli-v'))
  if (cliTags.length === 0) {
    console.log('No CLI releases tagged cli-v* yet on GitHub. To upgrade locally:')
    console.log('  cd <path-to-agent-bridge>')
    console.log('  git pull')
    console.log('  npm install -g .')
    return
  }
  const latest = cliTags[0].tag_name
  console.log(`Latest tagged: ${latest}`)
  console.log('To upgrade: cd <path-to-agent-bridge> && git pull && npm install -g .')
}

// ---- bridge ---------------------------------------------------------------
// The Swift CLI's `bridge daemon-*` commands keep a Node + SDK process warm
// between invocations to dodge ~1s cold-start. Our Node CLI IS Node, so
// there's no equivalent latency to save — query() runs in-process. We expose
// the surface for command-line parity but the daemon mode is a no-op.
export function cmdBridge(args) {
  const sub = args[0]
  switch (sub) {
    case 'daemon-start':
    case 'daemon-stop':
    case 'daemon-ping':
    case 'daemon-status':
      console.log(`(no bridge daemon needed in this CLI — the agent loop runs in-process inside the same Node host.`)
      console.log(` This command exists for parity with the Swift CLI but performs no action.)`)
      return
    case 'status':
      console.log('(no separate bridge processes — query() runs inside lingcode itself.)')
      return
    case 'kill':
      console.log('(nothing to kill — no separate bridge processes.)')
      return
    default:
      console.error(`bridge: unknown subcommand '${sub || ''}'.`)
      console.error('Usage: lingcode bridge <daemon-start|daemon-stop|daemon-ping|daemon-status|status|kill>')
      process.exit(64)
  }
}

// ---- acp-serve ------------------------------------------------------------
// Minimum-viable ACP server. Speaks JSON-RPC 2.0 over stdin/stdout with
// LSP-style Content-Length framing. We respond to `initialize` and report
// our capability set, then NACK most other methods with -32601
// (method not found). Real ACP integration (Zed, etc.) needs the full
// `session/new`, `session/prompt`, `session/cancel` lifecycle plus client
// callbacks for permission requests — that's a separate session of work.
// Tracking as a v1.0 task; this stub keeps the command surface complete
// without claiming functionality we don't have.
export async function cmdAcpServe() {
  let buffer = ''
  process.stdin.setEncoding('utf8')

  const writeMessage = (msg) => {
    const json = JSON.stringify(msg)
    const bytes = Buffer.byteLength(json, 'utf8')
    process.stdout.write(`Content-Length: ${bytes}\r\n\r\n${json}`)
  }

  function tryDispatch() {
    while (true) {
      const headerEnd = buffer.indexOf('\r\n\r\n')
      if (headerEnd === -1) return
      const header = buffer.slice(0, headerEnd)
      const m = header.match(/Content-Length:\s*(\d+)/i)
      if (!m) {
        buffer = buffer.slice(headerEnd + 4)
        continue
      }
      const len = parseInt(m[1], 10)
      if (Buffer.byteLength(buffer, 'utf8') < headerEnd + 4 + len) return
      const body = buffer.slice(headerEnd + 4, headerEnd + 4 + len)
      buffer = buffer.slice(headerEnd + 4 + len)
      let req
      try { req = JSON.parse(body) } catch { continue }
      handleRequest(req)
    }
  }

  function handleRequest(req) {
    if (req.method === 'initialize') {
      writeMessage({
        jsonrpc: '2.0',
        id: req.id,
        result: {
          protocolVersion: 1,
          agentCapabilities: {
            // Honest disclosure: this stub doesn't yet implement session/prompt,
            // so we declare a minimal capability set. Clients that need the
            // full session lifecycle should currently use Claude Code directly.
            promptCapabilities: { image: false, audio: false, embeddedContext: false },
          },
          authMethods: [],
        },
      })
      return
    }
    if (req.id !== undefined) {
      writeMessage({
        jsonrpc: '2.0',
        id: req.id,
        error: {
          code: -32601,
          message: `Method '${req.method}' is not yet implemented in the Node CLI's ACP server. Full ACP support is planned for v1.0; use \`lingcode ask\` or the REPL meanwhile.`,
        },
      })
    }
  }

  process.stdin.on('data', (chunk) => {
    buffer += chunk
    tryDispatch()
  })
  process.stdin.on('end', () => {
    // Drain pending stdout writes before exiting — otherwise the final
    // Content-Length response can be lost if the client closed stdin
    // immediately after sending the request.
    process.stdout.write('', () => process.exit(0))
  })
  // Block-forever — the protocol drives shutdown via the client.
  await new Promise(() => {})
}

// ---- history --------------------------------------------------------------
// Lists past saved sessions. Session persistence is OPT-IN via
// `lingcode config set saveHistory true`. Sessions land in
// ~/.lingcode/sessions/<timestamp>.json — see lib/transcript.mjs.
// `lingcode history` lists; `lingcode history show <id>` dumps; `lingcode
// history export <id> <path>` writes markdown.
export async function cmdHistory(args = []) {
  const { listSessions, loadSession, renderTranscriptAsMarkdown } = await import('./transcript.mjs')
  const sub = args[0]
  if (!sub) {
    const ids = await listSessions()
    if (ids.length === 0) {
      console.log('(no saved sessions — enable persistence with `lingcode config set saveHistory true`)')
      return
    }
    for (const id of ids) {
      const t = await loadSession(id)
      const turns = Array.isArray(t) ? t.filter((m) => m.role === 'user').length : 0
      process.stdout.write(`  ${id}   ${turns} turn${turns === 1 ? '' : 's'}\n`)
    }
    process.stdout.write('\nResume one with: lingcode --resume <id>\n')
    return
  }
  if (sub === 'show') {
    const id = args[1]
    if (!id) { console.error('history show: usage: lingcode history show <id>'); process.exit(64) }
    const t = await loadSession(id)
    if (!t) { console.error(`history show: session '${id}' not found.`); process.exit(64) }
    process.stdout.write(renderTranscriptAsMarkdown(t, { title: `lingcode session ${id}` }))
    return
  }
  if (sub === 'export') {
    const [, id, path] = args
    if (!id || !path) { console.error('history export: usage: lingcode history export <id> <path>'); process.exit(64) }
    const t = await loadSession(id)
    if (!t) { console.error(`history export: session '${id}' not found.`); process.exit(64) }
    const { writeFile } = await import('node:fs/promises')
    const md = renderTranscriptAsMarkdown(t, { title: `lingcode session ${id}` })
    await writeFile(path, md, 'utf8')
    console.log(`✓ Wrote ${md.length} bytes to ${path}`)
    return
  }
  console.error(`history: unknown subcommand '${sub}'.`)
  console.error('Usage: lingcode history [show <id> | export <id> <path>]')
  process.exit(64)
}
