// auth.mjs — credentials store + provider table + auth subcommands.
//
// Storage shape (~/.lingcode/credentials.json, mode 600):
//   {
//     "active": "lingmodel",
//     "accounts": {
//       "lingmodel":      { "provider": "lingmodel",  "token":   "lc_..." },
//       "anthropic":      { "provider": "anthropic",  "apiKey":  "sk-ant-..." },
//       "deepseek-claude":{ "provider": "deepseek-claude", "apiKey": "sk-ds-..." },
//       ...
//     }
//   }
//
// Provider routing (how the agent loop turns an account into an SDK call):
//   - LINGMODEL_SHAPE accounts (lingmodel, anthropic, deepseek-claude) use
//     the bundled claude-agent-sdk via Anthropic-shape requests. We just set
//     ANTHROPIC_BASE_URL + ANTHROPIC_API_KEY before query().
//   - Native-DeepSeek + OpenAI-compat providers are not wired up in v0.2 yet;
//     the table is declared for `auth login` to accept and store keys, but
//     `ask` / REPL will error out telling the user it's TODO.

import { homedir } from 'node:os'
import { join } from 'node:path'
import { readFile, writeFile, mkdir, chmod } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import readline from 'node:readline'
import process from 'node:process'

const CRED_DIR = join(homedir(), '.lingcode')
const CRED_PATH = join(CRED_DIR, 'credentials.json')

// ---- Provider table ---------------------------------------------------------
// Mirror the Swift CLI's `knownProviders` (LingCodeCLI/.../Commands/Auth.swift).
// `shape` controls routing:
//   - 'anthropic'    : route via claude-agent-sdk (Anthropic message shape)
//   - 'deepseek'     : native DeepSeek /chat/completions (NOT implemented yet)
//   - 'openai-compat': OpenAI /chat/completions (NOT implemented yet)
//
// `baseURL` only matters for non-default Anthropic-shape providers and the
// OpenAI-compat list. `apiKey` field name in storage is `apiKey` everywhere
// except 'lingmodel' which uses `token` to match the Swift CLI.
export const PROVIDERS = [
  {
    name: 'lingmodel',
    display: 'LingModel (your LingCode account)',
    shape: 'anthropic',
    baseURL: 'https://lingcode.dev/api/inference/anthropic',
    consoleURL: 'https://lingcode.dev/cli-token.html',
    keyField: 'token',
    keyLabel: 'CLI token',
    keyHint: 'Paste the token from https://lingcode.dev/cli-token.html',
  },
  {
    name: 'anthropic',
    display: 'Anthropic (Claude)',
    shape: 'anthropic',
    baseURL: null, // SDK default
    consoleURL: 'https://console.anthropic.com/settings/keys',
    keyField: 'apiKey',
    keyLabel: 'API key',
    keyHint: 'Format: sk-ant-...',
  },
  {
    name: 'deepseek-claude',
    display: 'DeepSeek (via Claude Code agent loop, Anthropic shape)',
    shape: 'anthropic',
    baseURL: 'https://api.deepseek.com/anthropic',
    consoleURL: 'https://platform.deepseek.com/api_keys',
    keyField: 'apiKey',
    keyLabel: 'DeepSeek API key',
    keyHint: 'Format: sk-...',
  },
  {
    name: 'deepseek',
    display: 'DeepSeek (native /chat/completions — NOT yet wired in this CLI)',
    shape: 'deepseek',
    baseURL: 'https://api.deepseek.com/v1',
    consoleURL: 'https://platform.deepseek.com/api_keys',
    keyField: 'apiKey',
    keyLabel: 'DeepSeek API key',
    keyHint: 'Format: sk-...',
  },
  // OpenAI-compat providers — auth supports storing keys; ask/REPL routing is
  // deferred to v0.3 (native loop port from OpenAICompatAgentLoop.swift).
  { name: 'openai',     display: 'OpenAI',                   shape: 'openai-compat', baseURL: 'https://api.openai.com/v1',                         consoleURL: 'https://platform.openai.com/api-keys',           keyField: 'apiKey', keyLabel: 'API key' },
  { name: 'gemini',     display: 'Google Gemini',            shape: 'openai-compat', baseURL: 'https://generativelanguage.googleapis.com/v1beta/openai', consoleURL: 'https://aistudio.google.com/app/apikey', keyField: 'apiKey', keyLabel: 'API key' },
  { name: 'groq',       display: 'Groq',                     shape: 'openai-compat', baseURL: 'https://api.groq.com/openai/v1',                    consoleURL: 'https://console.groq.com/keys',                  keyField: 'apiKey', keyLabel: 'API key' },
  { name: 'together',   display: 'Together',                 shape: 'openai-compat', baseURL: 'https://api.together.xyz/v1',                       consoleURL: 'https://api.together.ai/settings/api-keys',      keyField: 'apiKey', keyLabel: 'API key' },
  { name: 'openrouter', display: 'OpenRouter',               shape: 'openai-compat', baseURL: 'https://openrouter.ai/api/v1',                      consoleURL: 'https://openrouter.ai/keys',                     keyField: 'apiKey', keyLabel: 'API key' },
  { name: 'mistral',    display: 'Mistral',                  shape: 'openai-compat', baseURL: 'https://api.mistral.ai/v1',                         consoleURL: 'https://console.mistral.ai/api-keys/',           keyField: 'apiKey', keyLabel: 'API key' },
  { name: 'xai',        display: 'xAI (Grok)',               shape: 'openai-compat', baseURL: 'https://api.x.ai/v1',                               consoleURL: 'https://console.x.ai/',                          keyField: 'apiKey', keyLabel: 'API key' },
  { name: 'fireworks',  display: 'Fireworks',                shape: 'openai-compat', baseURL: 'https://api.fireworks.ai/inference/v1',             consoleURL: 'https://fireworks.ai/account/api-keys',          keyField: 'apiKey', keyLabel: 'API key' },
  { name: 'kimi',       display: 'Kimi (Moonshot)',          shape: 'openai-compat', baseURL: 'https://api.moonshot.ai/v1',                        consoleURL: 'https://platform.moonshot.cn/console/api-keys',  keyField: 'apiKey', keyLabel: 'API key' },
  { name: 'qwen',       display: 'Qwen (DashScope)',         shape: 'openai-compat', baseURL: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1', consoleURL: 'https://dashscope.console.aliyun.com/apiKey', keyField: 'apiKey', keyLabel: 'API key' },
  { name: 'z-ai',       display: 'z.ai (GLM)',               shape: 'openai-compat', baseURL: 'https://api.z.ai/api/paas/v4',                      consoleURL: 'https://z.ai/manage-apikey/apikey-list',         keyField: 'apiKey', keyLabel: 'API key' },
  { name: 'ollama',     display: 'Ollama (local)',           shape: 'openai-compat', baseURL: 'http://localhost:11434/v1',                         consoleURL: '',                                               keyField: 'apiKey', keyLabel: 'API key (often empty)' },
]

export function providerByName(name) {
  return PROVIDERS.find((p) => p.name === name.toLowerCase()) || null
}

// ---- Credentials store ------------------------------------------------------

async function ensureDir() {
  if (!existsSync(CRED_DIR)) {
    await mkdir(CRED_DIR, { recursive: true })
  }
}

export async function loadCredentials() {
  if (!existsSync(CRED_PATH)) return { active: null, accounts: {} }
  try {
    const raw = await readFile(CRED_PATH, 'utf8')
    const parsed = JSON.parse(raw)
    if (!parsed || typeof parsed !== 'object') return { active: null, accounts: {} }
    return {
      active: typeof parsed.active === 'string' ? parsed.active : null,
      accounts: parsed.accounts && typeof parsed.accounts === 'object' ? parsed.accounts : {},
    }
  } catch (error) {
    throw new Error(`Failed to read ${CRED_PATH}: ${error.message}`)
  }
}

export async function saveCredentials(store) {
  await ensureDir()
  const payload = JSON.stringify(store, null, 2)
  await writeFile(CRED_PATH, payload, 'utf8')
  // chmod 600 on Unix; on Windows fs.chmod is a no-op but harmless.
  try {
    await chmod(CRED_PATH, 0o600)
  } catch {
    /* Windows */
  }
}

// Returns the account record for the active provider, or null.
export async function activeAccount() {
  const store = await loadCredentials()
  if (!store.active) return null
  const account = store.accounts[store.active]
  if (!account) return null
  return { ...account, _name: store.active }
}

// Resolution order for the secret value held by an account:
//   1. credentials.json (this store)
//   2. env var for that provider (lets users override per-shell)
export function readKeyFromEnv(providerName) {
  const map = {
    lingmodel: 'LINGCODE_CLI_TOKEN',
    anthropic: 'ANTHROPIC_API_KEY',
    'deepseek-claude': 'DEEPSEEK_API_KEY',
    deepseek: 'DEEPSEEK_API_KEY',
    openai: 'OPENAI_API_KEY',
    gemini: 'GEMINI_API_KEY',
    groq: 'GROQ_API_KEY',
    together: 'TOGETHER_API_KEY',
    openrouter: 'OPENROUTER_API_KEY',
    mistral: 'MISTRAL_API_KEY',
    xai: 'XAI_API_KEY',
    fireworks: 'FIREWORKS_API_KEY',
    kimi: 'MOONSHOT_API_KEY',
    qwen: 'DASHSCOPE_API_KEY',
    'z-ai': 'ZAI_API_KEY',
    ollama: 'OLLAMA_API_KEY',
  }
  const envVar = map[providerName]
  return envVar ? process.env[envVar] || null : null
}

// ---- Interactive helpers ----------------------------------------------------

// Persistent readline across multiple prompts in the same command. Creating
// a fresh readline per question breaks on piped stdin (the closed interface
// leaves stdin in a state where the next createInterface hangs). One shared
// rl avoids that and also matches more typical CLI UX.
let _sharedRL = null
function getSharedRL() {
  if (_sharedRL && !_sharedRL.closed) return _sharedRL
  _sharedRL = readline.createInterface({ input: process.stdin, output: process.stdout })
  _sharedRL.on('close', () => { _sharedRL.closed = true })
  return _sharedRL
}
export function closePromptRL() {
  if (_sharedRL && !_sharedRL.closed) _sharedRL.close()
}

// Read the first newline-terminated line from stdin. Used in non-TTY mode
// for passphrase-via-pipe (e.g. `echo $PASS | lingcode auth export ...`).
async function readFirstStdinLine() {
  process.stdin.setEncoding('utf8')
  let buf = ''
  for await (const chunk of process.stdin) {
    buf += chunk
    const nl = buf.indexOf('\n')
    if (nl !== -1) return buf.slice(0, nl)
  }
  return buf
}

function prompt(question, { mask = false } = {}) {
  return new Promise((resolve) => {
    const rl = getSharedRL()
    const isTTY = process.stdin.isTTY === true
    let restore = null
    if (mask && isTTY) {
      const origWrite = rl._writeToOutput?.bind(rl)
      if (origWrite) {
        const patched = (str) => { if (str === '\n' || str === '\r\n') origWrite(str) }
        rl._writeToOutput = patched
        restore = () => { rl._writeToOutput = origWrite }
      }
    }
    rl.question(question, (answer) => {
      if (restore) restore()
      if (mask && isTTY) process.stdout.write('\n')
      resolve(answer)
    })
  })
}

// ---- Subcommand implementations --------------------------------------------

export async function cmdAuthLogin(args) {
  let provider = null
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--provider' && args[i + 1]) {
      provider = providerByName(args[i + 1])
      if (!provider) {
        console.error(`auth login: unknown provider '${args[i + 1]}'.`)
        console.error(`Known: ${PROVIDERS.map((p) => p.name).join(', ')}`)
        process.exit(64)
      }
      i++
    }
  }
  if (!provider) {
    // Interactive picker. List providers; user types a number or name.
    console.log('Choose a provider to set up:')
    PROVIDERS.forEach((p, idx) => {
      console.log(`  ${String(idx + 1).padStart(2)}. ${p.name.padEnd(18)} — ${p.display}`)
    })
    const choice = (await prompt('\nProvider (number or name): ')).trim()
    if (/^\d+$/.test(choice)) {
      const idx = parseInt(choice, 10) - 1
      provider = PROVIDERS[idx]
    } else {
      provider = providerByName(choice)
    }
    if (!provider) {
      console.error(`auth login: invalid selection.`)
      process.exit(64)
    }
  }

  console.log(`\nSetting up: ${provider.display}`)
  if (provider.consoleURL) {
    console.log(`  Get your ${provider.keyLabel} at: ${provider.consoleURL}`)
  }
  if (provider.keyHint) {
    console.log(`  ${provider.keyHint}`)
  }

  const secret = (await prompt(`\nPaste ${provider.keyLabel}: `, { mask: true })).trim()
  if (!secret) {
    console.error('auth login: empty value — nothing stored.')
    process.exit(64)
  }

  const store = await loadCredentials()
  store.accounts[provider.name] = {
    provider: provider.name,
    [provider.keyField]: secret,
  }
  if (!store.active) store.active = provider.name
  await saveCredentials(store)

  console.log(`\n✓ Stored ${provider.keyLabel} for ${provider.name}.`)
  if (store.active === provider.name) {
    console.log(`✓ Set as active provider.`)
  } else {
    console.log(`  Active provider is still '${store.active}'. Switch with: lingcode auth use ${provider.name}`)
  }
}

export async function cmdAuthStatus() {
  const store = await loadCredentials()
  const names = Object.keys(store.accounts)
  if (names.length === 0) {
    console.log('No accounts configured. Run: lingcode auth login')
    return
  }
  console.log('Configured accounts:')
  for (const name of names) {
    const isActive = name === store.active
    const a = store.accounts[name]
    const provider = providerByName(a.provider || name)
    const masked = (() => {
      const v = a[provider?.keyField || 'apiKey'] || a.apiKey || a.token || ''
      if (!v) return '(empty)'
      if (v.length <= 8) return '****'
      return v.slice(0, 4) + '…' + v.slice(-4)
    })()
    const marker = isActive ? '▶' : ' '
    console.log(`  ${marker} ${name.padEnd(18)} ${masked.padEnd(20)} ${provider?.display || ''}`)
  }
  console.log('\nActive provider:', store.active || '(none — set one with `lingcode auth use <provider>`)')
}

export async function cmdAuthUse(args) {
  const name = args[0]
  if (!name) {
    console.error('auth use: missing provider name.\nUsage: lingcode auth use <provider>')
    process.exit(64)
  }
  const store = await loadCredentials()
  if (!store.accounts[name]) {
    console.error(`auth use: no account named '${name}'. Run: lingcode auth login --provider ${name}`)
    process.exit(64)
  }
  store.active = name
  await saveCredentials(store)
  console.log(`✓ Active provider: ${name}`)
}

export async function cmdAuthDelete(args) {
  const name = args[0]
  if (!name) {
    console.error('auth delete: missing provider name.\nUsage: lingcode auth delete <provider>')
    process.exit(64)
  }
  const store = await loadCredentials()
  if (!store.accounts[name]) {
    console.error(`auth delete: no account named '${name}'.`)
    process.exit(64)
  }
  delete store.accounts[name]
  if (store.active === name) {
    const remaining = Object.keys(store.accounts)
    store.active = remaining[0] || null
  }
  await saveCredentials(store)
  console.log(`✓ Removed ${name}.`)
  if (store.active) console.log(`  Active provider is now: ${store.active}`)
}

export async function cmdAuthSet(args) {
  const [name, secret] = args
  if (!name || !secret) {
    console.error('auth set: usage: lingcode auth set <provider> <key>')
    process.exit(64)
  }
  const provider = providerByName(name)
  if (!provider) {
    console.error(`auth set: unknown provider '${name}'.`)
    process.exit(64)
  }
  const store = await loadCredentials()
  store.accounts[name] = { provider: name, [provider.keyField]: secret }
  if (!store.active) store.active = name
  await saveCredentials(store)
  console.log(`✓ Stored ${provider.keyLabel} for ${name}.`)
}

export async function cmdAuthLogout(args) {
  // Logout is "delete the active account" if no name given, else delete by name.
  const name = args[0]
  if (name) return cmdAuthDelete([name])
  const store = await loadCredentials()
  if (!store.active) {
    console.error('auth logout: no active account.')
    process.exit(64)
  }
  return cmdAuthDelete([store.active])
}

export async function cmdAuthList() {
  // Alias for status — Swift CLI exposes both for muscle memory.
  return cmdAuthStatus()
}

export async function cmdAuthGet(args) {
  const name = args[0]
  if (!name) {
    console.error('auth get: usage: lingcode auth get <provider>')
    process.exit(64)
  }
  const store = await loadCredentials()
  const account = store.accounts[name]
  if (!account) {
    console.error(`auth get: no account named '${name}'.`)
    process.exit(64)
  }
  const provider = providerByName(account.provider || name)
  const secret = account[provider?.keyField || 'apiKey'] || account.apiKey || account.token
  if (!secret) {
    console.error(`auth get: account '${name}' has no stored secret.`)
    process.exit(64)
  }
  // Write to stdout raw — let user pipe it.
  process.stdout.write(secret + '\n')
}

// auth export — encrypt the credentials store with a passphrase.
// Output format (JSON to stdout, or to --output path):
//   { "v": 1, "salt": "<hex>", "iv": "<hex>", "ct": "<hex>", "tag": "<hex>" }
// AES-256-GCM. Key derived from passphrase via scrypt.
export async function cmdAuthExport(args) {
  const { scrypt, randomBytes, createCipheriv } = await import('node:crypto')
  const { writeFile } = await import('node:fs/promises')
  let outPath = null
  for (let i = 0; i < args.length; i++) {
    if ((args[i] === '--output' || args[i] === '-o') && args[i + 1]) {
      outPath = args[i + 1]
      i++
    }
  }
  const isTTY = process.stdin.isTTY === true
  let passphrase
  if (isTTY) {
    passphrase = (await prompt('Passphrase (will be required to import): ', { mask: true })).trim()
    if (!passphrase) {
      console.error('auth export: empty passphrase.')
      process.exit(64)
    }
    const confirm = (await prompt('Confirm passphrase: ', { mask: true })).trim()
    if (passphrase !== confirm) {
      console.error('auth export: passphrases did not match.')
      process.exit(64)
    }
  } else {
    // Non-TTY: read first line of stdin as the passphrase. No confirm
    // (the user is responsible for piping the right thing).
    passphrase = (await readFirstStdinLine()).trim()
    if (!passphrase) {
      console.error('auth export: no passphrase on stdin (non-TTY mode reads first line).')
      process.exit(64)
    }
  }
  const store = await loadCredentials()
  const plain = Buffer.from(JSON.stringify(store), 'utf8')
  const salt = randomBytes(16)
  const iv = randomBytes(12)
  const key = await new Promise((resolve, reject) => {
    scrypt(passphrase, salt, 32, (err, derived) => (err ? reject(err) : resolve(derived)))
  })
  const cipher = createCipheriv('aes-256-gcm', key, iv)
  const ct = Buffer.concat([cipher.update(plain), cipher.final()])
  const tag = cipher.getAuthTag()
  const out = JSON.stringify({
    v: 1,
    salt: salt.toString('hex'),
    iv: iv.toString('hex'),
    ct: ct.toString('hex'),
    tag: tag.toString('hex'),
  })
  if (outPath) {
    await writeFile(outPath, out, 'utf8')
    console.log(`✓ Exported ${Object.keys(store.accounts).length} accounts to ${outPath}.`)
  } else {
    process.stdout.write(out + '\n')
  }
}

export async function cmdAuthImport(args) {
  const { scrypt, createDecipheriv } = await import('node:crypto')
  const { readFile } = await import('node:fs/promises')
  const inPath = args[0]
  if (!inPath) {
    console.error('auth import: usage: lingcode auth import <file>')
    process.exit(64)
  }
  let raw
  try {
    raw = await readFile(inPath, 'utf8')
  } catch (error) {
    console.error(`auth import: cannot read ${inPath}: ${error.message}`)
    process.exit(64)
  }
  let parsed
  try {
    parsed = JSON.parse(raw)
  } catch (error) {
    console.error(`auth import: file is not valid JSON: ${error.message}`)
    process.exit(64)
  }
  if (parsed?.v !== 1 || !parsed.salt || !parsed.iv || !parsed.ct || !parsed.tag) {
    console.error('auth import: unrecognized export format (expected v:1 bundle).')
    process.exit(64)
  }
  const isTTY = process.stdin.isTTY === true
  const passphrase = isTTY
    ? (await prompt('Passphrase: ', { mask: true })).trim()
    : (await readFirstStdinLine()).trim()
  if (!passphrase) {
    console.error('auth import: no passphrase provided.')
    process.exit(64)
  }
  const salt = Buffer.from(parsed.salt, 'hex')
  const iv = Buffer.from(parsed.iv, 'hex')
  const ct = Buffer.from(parsed.ct, 'hex')
  const tag = Buffer.from(parsed.tag, 'hex')
  const key = await new Promise((resolve, reject) => {
    scrypt(passphrase, salt, 32, (err, derived) => (err ? reject(err) : resolve(derived)))
  })
  const decipher = createDecipheriv('aes-256-gcm', key, iv)
  decipher.setAuthTag(tag)
  let plain
  try {
    plain = Buffer.concat([decipher.update(ct), decipher.final()])
  } catch {
    console.error('auth import: decryption failed (wrong passphrase or corrupt file).')
    process.exit(64)
  }
  let store
  try {
    store = JSON.parse(plain.toString('utf8'))
  } catch (error) {
    console.error(`auth import: decrypted payload is not valid JSON: ${error.message}`)
    process.exit(64)
  }
  await saveCredentials(store)
  console.log(`✓ Imported ${Object.keys(store.accounts || {}).length} account(s). Active: ${store.active || '(none)'}.`)
}

// ---- Top-level dispatch -----------------------------------------------------

export async function cmdAuth(args) {
  const sub = args[0]
  const rest = args.slice(1)
  try {
    switch (sub) {
      case 'login':   return await cmdAuthLogin(rest)
      case 'status':  return await cmdAuthStatus()
      case 'list':    return await cmdAuthList()
      case 'use':     return await cmdAuthUse(rest)
      case 'delete':  return await cmdAuthDelete(rest)
      case 'set':     return await cmdAuthSet(rest)
      case 'get':     return await cmdAuthGet(rest)
      case 'logout':  return await cmdAuthLogout(rest)
      case 'export':  return await cmdAuthExport(rest)
      case 'import':  return await cmdAuthImport(rest)
      default:
        console.error(`auth: unknown subcommand '${sub || ''}'.`)
        console.error('Usage: lingcode auth <login|status|list|use|delete|set|get|logout|export|import> [...]')
        process.exit(64)
    }
  } finally {
    // Always release the shared readline so the process exits cleanly.
    closePromptRL()
  }
}
