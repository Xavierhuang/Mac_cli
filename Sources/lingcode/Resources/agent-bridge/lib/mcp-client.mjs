// mcp-client.mjs — stdio MCP client for the OpenAI-compat agent loop.
//
// For Anthropic-shape providers, claude-agent-sdk's `mcpServers` option does
// this automatically. For the 13 OpenAI-shape providers, we manage stdio MCP
// servers ourselves, list their tools, and merge them into the function-call
// schema sent to the model. Tools are name-prefixed `mcp__<server>__<tool>`
// so they don't collide with our native Read/Write/etc.
//
// We use the bundled @modelcontextprotocol/sdk that ships as a transitive
// dep of @anthropic-ai/claude-agent-sdk (installed by `npm ci` in this dir).

import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'

const MCP_NAME_RE = /^mcp__([^_]+(?:_[^_]+)*?)__(.+)$/ // mcp__<server>__<tool>

// Connect to all configured MCP servers in parallel. Returns:
//   { clients: Map<serverName, Client>, tools: Array<openai-fn-schema> }
// Failed servers are logged to stderr and skipped — they don't abort the
// rest. Caller is responsible for calling closeAll(clients) when done.
export async function startMCPServers(mcpConfig, { onWarn } = {}) {
  const clients = new Map()
  const tools = []
  if (!mcpConfig || typeof mcpConfig !== 'object') return { clients, tools }

  const startOne = async ([name, cfg]) => {
    if (!cfg || typeof cfg !== 'object') return
    // We only support stdio MCP servers in v0.5; SSE / HTTP MCP would need
    // separate transport plumbing and aren't in the OpenAI-compat shape's
    // critical path. Skip non-stdio with a soft warning.
    const type = cfg.type || (cfg.command ? 'stdio' : null)
    if (type !== 'stdio') {
      onWarn?.(`MCP server '${name}': type='${type}' isn't supported in this CLI yet (stdio only).`)
      return
    }
    if (!cfg.command) {
      onWarn?.(`MCP server '${name}': missing 'command' field.`)
      return
    }

    let client
    try {
      const transport = new StdioClientTransport({
        command: cfg.command,
        args: Array.isArray(cfg.args) ? cfg.args : [],
        env: { ...process.env, ...(cfg.env && typeof cfg.env === 'object' ? cfg.env : {}) },
      })
      client = new Client(
        { name: 'lingcode-cli', version: '0.5.0' },
        { capabilities: {} }
      )
      await client.connect(transport)
    } catch (error) {
      onWarn?.(`MCP server '${name}' failed to start: ${error.message}`)
      try { await client?.close() } catch { /* ignore */ }
      return
    }

    // Enumerate tools.
    let listing
    try {
      listing = await client.listTools()
    } catch (error) {
      onWarn?.(`MCP server '${name}' listTools failed: ${error.message}`)
      try { await client.close() } catch { /* ignore */ }
      return
    }
    if (!Array.isArray(listing?.tools)) {
      onWarn?.(`MCP server '${name}' returned no tools.`)
      try { await client.close() } catch { /* ignore */ }
      return
    }

    clients.set(name, client)
    for (const t of listing.tools) {
      if (!t.name) continue
      tools.push({
        type: 'function',
        function: {
          name: `mcp__${name}__${t.name}`,
          description: t.description || `(MCP tool ${name}/${t.name})`,
          parameters: t.inputSchema && typeof t.inputSchema === 'object'
            ? t.inputSchema
            : { type: 'object', properties: {} },
        },
      })
    }
  }

  await Promise.all(Object.entries(mcpConfig).map(startOne))
  return { clients, tools }
}

// Returns { server, tool } for an MCP-prefixed name, or null otherwise.
export function parseMCPName(name) {
  const m = MCP_NAME_RE.exec(name)
  return m ? { server: m[1], tool: m[2] } : null
}

// Invoke an MCP tool. Returns a string result suitable for the OpenAI
// `role:tool` content. Throws on transport / tool errors so the caller can
// embed them as the tool message.
export async function callMCPTool(clients, prefixedName, input) {
  const parsed = parseMCPName(prefixedName)
  if (!parsed) throw new Error(`Not an MCP tool name: ${prefixedName}`)
  const client = clients.get(parsed.server)
  if (!client) throw new Error(`No MCP server registered for '${parsed.server}'.`)
  const result = await client.callTool({ name: parsed.tool, arguments: input || {} })
  if (result?.isError) {
    const text = result.content?.map((c) => c.text || '').join('\n') || 'MCP tool returned isError=true'
    throw new Error(text)
  }
  // Flatten content blocks to a string. MCP tool results are an array of
  // content blocks (text / image / resource) — we only render text here.
  if (!Array.isArray(result?.content)) return JSON.stringify(result || {})
  return result.content
    .map((c) => (typeof c.text === 'string' ? c.text : JSON.stringify(c)))
    .join('\n')
}

export async function closeAll(clients) {
  await Promise.all([...clients.values()].map(async (c) => {
    try { await c.close() } catch { /* ignore */ }
  }))
}
