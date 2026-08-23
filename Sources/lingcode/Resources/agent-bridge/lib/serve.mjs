// serve.mjs — `lingcode serve` HTTP server. Exposes the agent over
// POST /v1/agent/ask with Server-Sent Events, mirroring the Swift CLI's
// surface (per memory: reference_lingcode_http_server.md):
//
//   - SSE for /v1/agent/ask
//   - Bearer token at ~/.lingcode/server.token (chmod 600), generated on first
//     start, printed to stderr.
//   - Bind defaults to 127.0.0.1; --allow-remote required for non-loopback.

import { createServer } from 'node:http'
import { randomBytes } from 'node:crypto'
import { writeFile, readFile, mkdir, chmod } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import process from 'node:process'

const LINGCODE_DIR = join(homedir(), '.lingcode')
const TOKEN_PATH = join(LINGCODE_DIR, 'server.token')

async function loadOrCreateToken() {
  if (existsSync(TOKEN_PATH)) {
    return (await readFile(TOKEN_PATH, 'utf8')).trim()
  }
  await mkdir(LINGCODE_DIR, { recursive: true })
  const token = randomBytes(32).toString('base64url')
  await writeFile(TOKEN_PATH, token, 'utf8')
  try { await chmod(TOKEN_PATH, 0o600) } catch { /* Windows */ }
  return token
}

function parseArgs(argv) {
  let host = '127.0.0.1'
  let port = 5117 // matches Swift CLI default
  let allowRemote = false
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--host' && argv[i + 1]) { host = argv[i + 1]; i++ }
    else if (argv[i] === '--port' && argv[i + 1]) { port = parseInt(argv[i + 1], 10); i++ }
    else if (argv[i] === '--allow-remote') { allowRemote = true }
  }
  return { host, port, allowRemote }
}

export async function cmdServe(argv) {
  const { host, port, allowRemote } = parseArgs(argv)
  if (!allowRemote && host !== '127.0.0.1' && host !== 'localhost' && host !== '::1') {
    console.error(`serve: refusing to bind ${host} without --allow-remote (non-loopback).`)
    process.exit(64)
  }
  const token = await loadOrCreateToken()
  const { streamOpenAICompat } = await import('./openai-compat.mjs')
  const { activeAccount, providerByName } = await import('./auth.mjs')

  const server = createServer(async (req, res) => {
    // CORS — local-only by default. For remote allow, callers can use a
    // proxy that adds their own CORS; we don't speak arbitrary origins.
    res.setHeader('Access-Control-Allow-Origin', allowRemote ? '*' : 'http://localhost')
    res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type')
    res.setHeader('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')

    if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return }

    // Auth gate.
    const auth = req.headers['authorization'] || ''
    if (auth !== `Bearer ${token}`) {
      res.writeHead(401, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify({ error: 'Unauthorized — set Authorization: Bearer <token from ~/.lingcode/server.token>' }))
      return
    }

    if (req.method === 'GET' && req.url === '/v1/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify({ ok: true, version: '0.7.0' }))
      return
    }

    if (req.method === 'POST' && req.url === '/v1/agent/ask') {
      // Read body
      let body = ''
      req.setEncoding('utf8')
      for await (const chunk of req) body += chunk
      let payload
      try {
        payload = JSON.parse(body || '{}')
      } catch (error) {
        res.writeHead(400, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify({ error: `Invalid JSON: ${error.message}` }))
        return
      }
      const prompt = typeof payload.prompt === 'string' ? payload.prompt : null
      if (!prompt) {
        res.writeHead(400, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify({ error: 'prompt (string) is required.' }))
        return
      }

      // Resolve provider — explicit `provider` field in body, else active.
      let providerName = payload.provider || null
      const account = providerName
        ? { _name: providerName }
        : await activeAccount()
      if (!account) {
        res.writeHead(400, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify({ error: 'No active provider. Run `lingcode auth login` or pass {"provider": "..."} in body.' }))
        return
      }
      providerName = account._name
      const meta = providerByName(providerName)
      if (!meta) {
        res.writeHead(400, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify({ error: `Unknown provider '${providerName}'.` }))
        return
      }

      // Get secret. Reload store fully for non-active providers.
      const { loadCredentials, readKeyFromEnv } = await import('./auth.mjs')
      const store = await loadCredentials()
      const rec = store.accounts[providerName]
      const stored = rec?.[meta.keyField] || rec?.apiKey || rec?.token
      const secret = readKeyFromEnv(providerName) || stored
      if (!secret) {
        res.writeHead(400, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify({ error: `No secret stored for '${providerName}'.` }))
        return
      }

      // SSE response.
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        Connection: 'keep-alive',
      })
      const send = (event, data) => {
        if (event) res.write(`event: ${event}\n`)
        res.write(`data: ${JSON.stringify(data)}\n\n`)
      }

      const abortController = new AbortController()
      req.on('close', () => abortController.abort())

      // For server mode we deny all mutating tools — security default.
      // Caller can override per-request with payload.permissions: "bypass".
      const permissionMode = payload.permissions === 'bypass' ? 'bypassPermissions' : 'default'

      try {
        if (meta.shape === 'anthropic') {
          // Just notify it's an unsupported route in serve mode for now —
          // the SDK path requires more plumbing (env mutation isn't safe in
          // a multi-request server; would need per-request claude-code spawn).
          send('error', { message: 'serve mode supports OpenAI-compat providers only in this version (no per-request env sandboxing for the Anthropic SDK yet). Switch to an OpenAI-compat provider.' })
          res.end()
          return
        }
        await streamOpenAICompat({
          prompt,
          meta,
          secret,
          abortController,
          permissionCallback: () => (permissionMode === 'bypassPermissions' ? 'allow' : 'deny'),
          onText: (chunk) => send('text', { chunk }),
          onToolStart: (name, input) => send('tool_use', { name, input }),
          onToolResult: (name, content) => send('tool_result', { name, content }),
          onToolDenied: (name) => send('tool_denied', { name }),
        })
        send('done', {})
      } catch (error) {
        send('error', { message: error.message })
      } finally {
        res.end()
      }
      return
    }

    res.writeHead(404, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ error: 'Not found' }))
  })

  server.listen(port, host, () => {
    process.stderr.write(`lingcode serve\n`)
    process.stderr.write(`  Listening on http://${host}:${port}\n`)
    process.stderr.write(`  Bearer token: ${token}\n`)
    process.stderr.write(`  Stored at: ${TOKEN_PATH} (chmod 600)\n`)
    process.stderr.write(`  Endpoints:\n`)
    process.stderr.write(`    GET  /v1/health\n`)
    process.stderr.write(`    POST /v1/agent/ask    body: { prompt, provider?, permissions? }   SSE response\n`)
    process.stderr.write(`  Ctrl-C to stop.\n`)
  })

  const stop = () => {
    process.stderr.write('\nShutting down...\n')
    server.close(() => process.exit(0))
    setTimeout(() => process.exit(0), 2000).unref()
  }
  process.on('SIGINT', stop)
  process.on('SIGTERM', stop)
}
