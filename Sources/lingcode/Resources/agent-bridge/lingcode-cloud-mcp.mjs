#!/usr/bin/env node
// lingcode-cloud-mcp.mjs — a tiny STDIO ⇆ HTTP MCP proxy.
//
// The native LingCode agent (and Cursor / Claude Desktop) speak MCP over stdio.
// LingCode Cloud's account MCP server is stateless Streamable-HTTP (the response
// comes back in the POST body). This proxy bridges the two: it reads
// newline-delimited JSON-RPC messages from stdin, POSTs each to the account MCP
// endpoint with the user's Bearer token + project header, and writes the JSON
// response to stdout. No npm deps — Node 18+ builtins only (global fetch).
//
// Two methods are NOT blindly forwarded: `tools/list` (the remote list is
// forwarded, then the local deploy tools are appended) and `tools/call` (handled
// here when the name is local). See lib/cloud-deploy-tools.mjs for why deploy has
// to run client-side. Everything else — notifications, the 202 path, the error
// mapping — is untouched.
//
// .mcp.json usage:
//   { "mcpServers": { "lingcode-cloud": {
//       "type": "stdio", "command": "node", "args": ["…/lingcode-cloud-mcp.mjs"],
//       "env": { "LINGCODE_MCP_URL": "https://lingcode.dev/api/cloud/account/mcp",
//                "LINGCODE_TOKEN": "<api_access_token>", "LINGCODE_PROJECT": "<project key>",
//                "LINGCODE_WORKSPACE": "<absolute workspace path>" } } } }

import readline from 'node:readline';
import {
  LOCAL_TOOLS, isLocalTool, callLocalTool, apiOriginFromMcpUrl,
} from './lib/cloud-deploy-tools.mjs';

const URL_ = process.env.LINGCODE_MCP_URL || 'https://lingcode.dev/api/cloud/account/mcp';
// LINGCODE_CLOUD_TOKEN is the Codex path: its `-c` overrides become part of the
// command string, so the token rides in through the process env instead of argv.
const TOKEN = process.env.LINGCODE_TOKEN || process.env.LINGCODE_CLOUD_TOKEN || '';
const PROJECT = process.env.LINGCODE_PROJECT || 'default';
// Canonical project id (from <workspace>/.lingcode/project.json). When present
// the server resolves a SHARED backend by membership; the path-hash PROJECT is
// only the solo fallback. Empty for un-migrated / unshared projects.
const PROJECT_ID = process.env.LINGCODE_PROJECT_ID || '';
// The local tools read the user's build output, so they need the workspace root.
// The proxy is spawned without a guaranteed cwd, hence the explicit env var.
const WORKSPACE = process.env.LINGCODE_WORKSPACE || process.cwd();

const localCtx = {
  workspace: WORKSPACE,
  origin: apiOriginFromMcpUrl(URL_),
  token: TOKEN,
  project: PROJECT,
  projectId: PROJECT_ID,
  fetchImpl: (...a) => fetch(...a),
};

function out(obj) { process.stdout.write(JSON.stringify(obj) + '\n'); }

function post(msg) {
  return fetch(URL_, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'authorization': 'Bearer ' + TOKEN,
      'x-lingcode-project': PROJECT,
      ...(PROJECT_ID ? { 'x-lingcode-project-id': PROJECT_ID } : {}),
    },
    body: JSON.stringify(msg),
  });
}

async function forward(msg) {
  const isNotification = (msg.id === undefined || msg.id === null);
  try {
    const res = await post(msg);
    if (res.status === 202) return;            // notification accepted, no body
    const text = await res.text();
    if (!text) return;
    if (!res.ok) {
      // HTTP-level failure (e.g. 401). Surface as a JSON-RPC error so the agent sees it.
      if (!isNotification) out({ jsonrpc: '2.0', id: msg.id, error: { code: -32001, message: `HTTP ${res.status}: ${text.slice(0, 200)}` } });
      return;
    }
    process.stdout.write(text.endsWith('\n') ? text : text + '\n'); // pass the JSON-RPC response through
  } catch (e) {
    if (!isNotification) out({ jsonrpc: '2.0', id: msg.id, error: { code: -32002, message: String((e && e.message) || e) } });
  }
}

/**
 * Forward the remote tool list, then append the local ones. If the server is
 * paginating, only the final page gets the additions — appending to every page
 * would list them once per page.
 */
async function forwardToolsList(msg) {
  try {
    const res = await post(msg);
    const text = await res.text();
    if (!res.ok) {
      out({ jsonrpc: '2.0', id: msg.id, error: { code: -32001, message: `HTTP ${res.status}: ${text.slice(0, 200)}` } });
      return;
    }
    let body;
    try { body = JSON.parse(text); } catch {
      // Unparseable but successful: pass it through rather than dropping the
      // remote tools, and lose only the local additions.
      process.stdout.write(text.endsWith('\n') ? text : text + '\n');
      return;
    }
    if (body && body.result && Array.isArray(body.result.tools) && !body.result.nextCursor) {
      body.result.tools = body.result.tools.concat(LOCAL_TOOLS);
    }
    out(body);
  } catch (e) {
    out({ jsonrpc: '2.0', id: msg.id, error: { code: -32002, message: String((e && e.message) || e) } });
  }
}

async function handleToolCall(msg) {
  const name = msg.params && msg.params.name;
  if (!isLocalTool(name)) return forward(msg);
  const result = await callLocalTool(name, (msg.params && msg.params.arguments) || {}, localCtx);
  out({ jsonrpc: '2.0', id: msg.id, result });
}

function route(msg) {
  const isRequest = !(msg.id === undefined || msg.id === null);
  if (isRequest && msg.method === 'tools/list') return forwardToolsList(msg);
  if (isRequest && msg.method === 'tools/call') return handleToolCall(msg);
  return forward(msg);
}

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
  const s = line.trim();
  if (!s) return;
  let msg;
  try { msg = JSON.parse(s); } catch { return; } // ignore non-JSON lines
  route(msg);
});
