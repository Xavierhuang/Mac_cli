# lingcode — LingCode's terminal companion

> **This repository is a read-only mirror, and a host for release binaries.**
>
> Canonical source: **[Xavierhuang/LingCode](https://github.com/Xavierhuang/LingCode)**,
> under `LingCodeCLI/`. Open issues and pull requests there — changes pushed here
> are overwritten on the next release.
>
> It does **not** build standalone: `Package.swift` carries path dependencies
> (`../LingCodeAgentCore`, `../LingCodeACP`, `../LingCodeServer`) that only resolve
> inside the canonical repo. It is here to be read, and so that each release tag
> points at the source the published binaries were actually built from.
>
> Every release lists its upstream commit in the release notes.

Swift Package that builds the `lingcode` binary, a terminal companion to
LingCode.app. Ships inside the app bundle at
`LingCode.app/Contents/Resources/bin/lingcode`.

## What it does

Three modes, picked automatically:

| Situation | What `lingcode ask` does |
| --- | --- |
| LingCode.app is running | Routes the prompt over Unix-socket IPC to the app; streams the reply. |
| App closed, `--provider deepseek` (default) | Calls `api.deepseek.com` directly. Text-only by default; `--yolo` enables tool use (Bash/Edit/Read/…). Needs `DEEPSEEK_API_KEY`. |
| App closed, `--provider claude` | Spawns the bundled Node bridge + `@anthropic-ai/claude-agent-sdk`. Full tool use (Bash/Edit/Read/…). Needs Node.js, `ANTHROPIC_API_KEY`, and LingCode.app installed (for `bridge.mjs`). |

Other subcommands (`ping`, `open`, `status`, `watch`) only work when the
app is running — they drive its Unix socket.

`lingcode serve` starts a long-running HTTP server (SSE for streaming agent
output, plain POST for permission round-trips and cancellation). It uses the
same `AgentBridgeSession` core as `lingcode ask` — see [`lingcode serve`](#lingcode-serve)
below.

## Package layout

```
LingCodeCLI/
├── Package.swift                       # 5.7 tools, macOS 13+
└── Sources/
    ├── LingCodeIPC/                    # Shared wire protocol (imported by app too)
    │   └── IPCProtocol.swift
    └── lingcode/
        ├── LingCodeEntry.swift         # @main AsyncParsableCommand root
        ├── IPCClient.swift             # Unix-socket client
        ├── HeadlessAsk.swift           # DeepSeek headless path
        ├── HeadlessClaude.swift        # Claude-bridge headless path
        └── Commands/
            ├── Ask.swift
            ├── Install.swift
            ├── Open.swift
            ├── Ping.swift
            ├── Status.swift
            └── Watch.swift
```

Headless agent code (`DeepSeekClient`, `AgentBridgeSession`,
`PermissionDecider`, `BridgeResourceLocator`) lives in the sibling
[`LingCodeAgentCore`](../LingCodeAgentCore/) package and is consumed via
`.package(path: "../LingCodeAgentCore")`.

## Build

```bash
cd LingCodeCLI
swift build                           # debug binary → .build/debug/lingcode
swift build --configuration release   # release    → .build/release/lingcode
swift test                            # 20 unit tests in LingCodeAgentCore
```

The release binary is what `ship.sh` copies into
`LingCode.app/Contents/Resources/bin/lingcode` and codesigns.

## Running locally (no app shipped)

Point the Claude bridge locator at your dev `agent-bridge/` directory:

```bash
export LINGCODE_AGENT_BRIDGE_DIR="$PWD/../LingCode/agent-bridge"
export ANTHROPIC_API_KEY=sk-ant-...
.build/debug/lingcode ask --headless --provider claude --yolo "summarise this repo"
```

Or for the DeepSeek path, no bridge is needed:

```bash
export DEEPSEEK_API_KEY=sk-...
.build/debug/lingcode ask --headless "what is in this directory?"
```

## Adding a subcommand

1. New file in `Sources/lingcode/Commands/` with a `struct` conforming to
   `ParsableCommand` (or `AsyncParsableCommand` if it does async work).
2. Add it to the `subcommands:` list in `LingCodeEntry.swift`.
3. If async, annotate with `@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)`.

Async subcommands from a file called `main.swift` do not work — see
[LingCodeEntry.swift](Sources/lingcode/LingCodeEntry.swift) for the working
`@main` pattern.

## `lingcode serve`

Runs an HTTP server that exposes the agent over `/v1/agent/ask` (SSE) so
external clients (VS Code extensions, scripts, web UIs) can drive the same
core that powers `lingcode ask` and the GUI.

```bash
lingcode serve                         # bind 127.0.0.1:7878
lingcode serve --port 8080             # custom port
lingcode serve --bind 0.0.0.0 --allow-remote  # opt in to non-loopback
lingcode serve --new-token             # rotate the bearer token
```

Auth: `Authorization: Bearer <token>`. The token is generated on first start,
written to `~/.lingcode/server.token` (chmod 600), and printed to stderr.
Pass it via env so it doesn't end up in shell history:

```bash
TOKEN=$(cat ~/.lingcode/server.token)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7878/v1/ping
# {"ok":true,"version":"0.8.9","protocol":"v1"}
```

Streaming an agent query (use `curl -N` to disable client-side buffering):

```bash
curl -N -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"provider":"claude","prompt":"list files","cwd":"'"$PWD"'"}' \
     http://127.0.0.1:7878/v1/agent/ask
```

When Claude requests a tool call, you'll see a `permission_request` SSE event.
Approve from a second terminal:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"behavior":"allow"}' \
     http://127.0.0.1:7878/v1/agent/permission/<requestId>
```

Cancel mid-query:

```bash
curl -s -H "Authorization: Bearer $TOKEN" -X POST \
     http://127.0.0.1:7878/v1/agent/cancel/<queryId>
```

Providers supported in M1: `claude` (full tools + permissions), `deepseek`,
and any OpenAI-compatible (`openai`, `groq`, `together`, `openrouter`,
`mistral`, `xai`, `fireworks`, `deepseek-compat`, `ollama`, `gemini`,
`kimi`, `qwen`). API keys are resolved with the same env →
keychain → config-file fallback `lingcode ask` uses.

Bind / TLS / CORS notes and the full endpoint reference live in
[`LingCodeServer/README.md`](../LingCodeServer/README.md).

## Wire protocol

Messages exchanged with the app are defined in
[`LingCodeIPC/IPCProtocol.swift`](Sources/LingCodeIPC/IPCProtocol.swift).
The socket is at `~/Library/Application Support/LingCode/ipc.sock`.

The Claude bridge protocol (Swift ↔ Node) is documented by the event
and command types in
[`AgentBridgeSession.swift`](../LingCodeAgentCore/Sources/LingCodeAgentCore/AgentBridgeSession.swift)
and the command dispatcher in
[`bridge.mjs`](../LingCode/agent-bridge/bridge.mjs).

## License

Same as the parent LingCode project.
