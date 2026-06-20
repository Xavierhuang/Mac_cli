# lingcode CLI — Deferred items + design notes

This file tracks the feature work that's been *partially* shipped or *intentionally
deferred* with a working stub. It exists so a future focused session can pick up
without re-deriving the design. Each item has: the user-visible problem, what
ships today (the "Lite" version), what the full version requires, and the
acceptance criteria the full implementation should hit.

---

## 1. Resumable streaming (full version)

**What ships today (Lite).** [HeadlessClaude.swift](../Sources/lingcode/HeadlessClaude.swift)
auto-retries `queryFailed` events that match `isRecoverableError(_:)` — both
classic rate-limit signals and transient-network signals (connection reset,
timeout, 5xx). Backoff is shorter for network errors (~1–15s) than rate limits
(~2–60s). When a stream dies mid-assistant-text, the retry restarts the query
from scratch — the partial output already on screen is **not** stitched into the
new run; the model just produces a fresh response.

**What full resumable streaming would add.** Output continuity across a
mid-stream failure — the user sees one coherent assistant response even when
the bridge had to retry under the hood.

**Design sketch.**

1. **Track assistant_text by index.** Bridge emits `{type: "assistant_text",
   text, index}` where `index` is a monotonically-increasing offset over
   characters emitted in the current query. Client buffers and dedupes.
2. **Resume contract on retry.** When the bridge is asked to resume after a
   failure mid-stream, it sends `{type: "resume_from", index: N}` so the client
   can drop the first N characters of the new response.
3. **Two strategies, pick by SDK capability.**
   - **Real resume** (preferred): if the Anthropic SDK ever exposes
     mid-conversation resume, we pass `lastMessageId` through and let the API
     pick up where it left off. Currently it doesn't.
   - **Continue-from prompt** (fallback): on retry we prepend
     `[Your previous response was interrupted at: "<last 200 chars>". Continue
     exactly where you left off without repeating that text.]` to a new query.
     Less elegant; works today.
4. **Idempotency for tool calls.** If a tool call had already started before the
   stream died, the SDK should not re-execute it. This needs a bridge-side
   dedupe by tool_use_id.

**Acceptance criteria.**
- Killing the network mid-response (`sudo ifconfig en0 down`) and bringing it
  back within 30s yields a single coherent response in the terminal.
- Killing the network mid-tool-call doesn't re-run the tool when the bridge
  reconnects.
- `--no-retry` opt-out for users who'd rather see the failure.
- Add an integration test under `LingCodeCLITests/` that simulates network blips
  with a mock bridge.

**Estimated scope.** ~300 LOC across `bridge.mjs`, `AgentBridgeSession`, and
`HeadlessClaude`. Plus a test harness for fault injection (~150 LOC).

---

## 2. Multi-client warm-bridge daemon (full version)

**What ships today (single-client daemon).**
[Bridge.swift](../Sources/lingcode/Commands/Bridge.swift) `daemon-start/stop/
status/ping` commands plus `bridge.mjs --daemon-socket <path>` mode. The daemon
listens on `~/.lingcode/bridge/daemon.sock`, accepts **one** client at a time
(second client gets an immediate `daemon_busy` error and disconnect), keeps
Node + the Agent SDK warm between connections, idle-times-out after a
configurable interval. `lingcode bridge daemon-ping` confirms IPC works
end-to-end. **Not yet wired**: `lingcode ask --via-daemon` — the client side
needs a `SocketBridgeSession` that speaks the same protocol over a Unix socket
instead of stdin/stdout. That's the natural next deliverable.

**What full multi-client adds.** Concurrent sessions in one daemon — `lingcode
ask` from terminal A and `lingcode repl` in terminal B share one warm Node
process.

**Design sketch.**

1. **Per-connection session state in `bridge.mjs`.** Today `currentSessionId`
   and `defaultPermissionMode` are module-globals. They need to move into a
   per-connection context object passed to `handleCommand`.
2. **Fairness.** Round-robin or priority-aware request scheduling if multiple
   clients have queries in flight. Easiest first cut: serialize at the SDK level
   (one `query()` call active at a time across all clients), queue the rest.
3. **Backpressure.** A slow client shouldn't stall the daemon; per-socket write
   buffers with high-water-mark + drop-with-error if a client falls behind.
4. **Lifecycle UX.** `lingcode bridge daemon-status` should show per-client
   connection info (pid that connected, current query id, queued requests).
5. **Wiring `--via-daemon`.** In `AgentBridgeSession`, factor the I/O layer
   into a protocol (read-line / write-line). Today it's bound to a `Process`
   stdin/stdout pair; a `SocketTransport` would connect to the daemon socket.
   Same `BridgeEvent` stream shape on the consumer side.

**Acceptance criteria.**
- Two `lingcode ask --via-daemon` invocations from different shells run
  concurrently without seeing each other's output.
- Daemon survives a crashed client (broken pipe doesn't take it down).
- `lingcode bridge daemon-status` reports per-client info.
- Restarting the daemon under load doesn't lose acknowledged requests
  (write-ahead log of pending queries to `~/.lingcode/bridge/queue/`).
- Memory growth bounded — long-running daemon shouldn't leak by query count.

**Estimated scope.** ~600 LOC across `bridge.mjs`, a new
`SocketBridgeSession.swift`, and the daemon control surface. Plus a soak-test
script (~100 LOC) to detect leaks under load.

---

## 3. Web/HTTP server mode

**Status.** Not started. Open question: protocol shape — REST + SSE? gRPC?
JSON-RPC over WebSocket? Match what Claude Code's `--print` / `--api` shapes
look like for compatibility, since users may script against both. Touch the
existing IPC subcommands (`ping`, `status`, `watch`) as the natural starting
point — they already speak Unix sockets to LingCode.app; the HTTP mode would
be the same protocol over TCP.

---

## 4. Workflow scripting

**Status.** Not started. Sketch:

```yaml
# .lingcode/workflows/release.yaml
name: release
on: [manual, cron("0 9 * * 1")]
steps:
  - id: bump
    prompt: "Bump the patch version in Package.swift and CHANGELOG.md."
  - id: tests
    run: swift test
    requires: [bump]
  - id: ship
    prompt: "Commit, tag, and push v{{ bump.version }} after tests pass."
    requires: [tests]
```

`lingcode workflow run release` would thread context between steps, surface a
single transcript, and stop on failure. Substantial — needs a YAML schema, a
DAG executor with conditional/loop primitives, and integration with `--continue`
so each step can land in the same session.

---

## 5. Custom Swift-native tool plugins

**Status.** Not started. Currently extra tools must come through MCP (separate
process, JSON-RPC handshake). A Swift-native plugin would `dlopen` a `.dylib`
that conforms to a `LingCodeTool` protocol (name, JSON-schema input, async
handler). Better latency than MCP but security-sensitive: arbitrary code in the
host process. Would need code signing checks, sandboxing options, and a clear
opt-in install gesture.

---

## 6. Bridge protocol versioning

**Status.** Not started. Today `bridge.mjs` and `AgentBridgeSession` ship as a
matched pair — version drift between them isn't possible because they're
co-versioned in the binary. Once the daemon (#2) becomes long-lived and
upgradable independently of clients, we'll need:

- `{"type": "hello", "client_protocol": 2}` handshake on connect.
- Daemon responds with `{"type": "ready", "server_protocol": 2, "supported": [1,2]}`.
- Refuse-or-degrade if no overlap.

Small foundation (~30 LOC) but pointless to build before #2 is multi-client.

---

## Acceptance criteria for "the CLI is done"

We won't reach 100% feature parity with Claude Code — that's not the goal.
Reasonable shipping bar:

- All single-machine workflows work without the user having to edit a config
  file or set non-obvious env vars.
- The CLI runs without LingCode.app installed.
- Tab completion, exit codes, JSON output for the four primary verbs
  (`ask`, `repl`, `auth list`, `mcp list`).
- Doctor exits 0 in a green-field install on a fresh Mac.
- All shipped subcommands have working `--help`.

The 19 subcommands today + the deferred items above cover everything in the
above list except the daemon's actual integration into `ask` (item 2 above).
