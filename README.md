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

`lingcode` is an agentic coding assistant for the terminal. It runs standalone —
the tarballs on the [releases page](https://github.com/Xavierhuang/Mac_cli/releases)
bundle their own Node runtime, so there are no prerequisites — and it also ships
inside LingCode.app at `Contents/Resources/bin/lingcode`, where it talks to the
running app over a Unix socket.

## Install

```bash
curl -fsSL https://lingcode.dev/install-cli.sh | sh
```

Windows (PowerShell):

```powershell
iwr -useb https://lingcode.dev/install-cli.ps1 | iex
```

The installer detects your OS and architecture, unpacks the bundle to
`~/.lingcode/cli`, and symlinks the binary to `~/.local/bin/lingcode`. If that
directory is not on your `PATH` it says so. macOS builds are signed and
notarized, so Gatekeeper will not block them.

Then add a key and check the install:

```bash
lingcode auth login          # store a provider API key in the Keychain
lingcode doctor              # node, keys, bridge, MCP servers, network
lingcode                     # interactive session
```

`lingcode upgrade` re-runs the installer in place.

## What it does

`lingcode ask` picks its route automatically:

| Situation | What happens |
| --- | --- |
| LingCode.app is running | Routes the prompt over Unix-socket IPC to the app and streams the reply back. |
| App closed, `--provider claude` | Spawns the bundled Node bridge and the Claude Agent SDK. Full tool use — Bash, Read, Edit, Glob, Grep, MCP. |
| App closed, any other provider | Runs the OpenAI-compatible agent loop natively in Swift, with the same tool registry. |

Providers: `claude`, `openai`, `gemini`, `deepseek`, `groq`, `mistral`, `xai`,
`together`, `openrouter`, `fireworks`, `kimi`, `qwen`, `ollama`, `lingmodel`,
plus any OpenAI-compatible endpoint you point it at. Keys live in the macOS
Keychain (a chmod-600 file on Linux) — see `lingcode auth`.

`ping`, `open`, `status` and `watch` require the app to be running; they drive
its socket. Everything else works standalone.

## Commands

31 subcommands. `lingcode <command> --help` for detail on any of them.

| | |
| --- | --- |
| `ask` | Send a prompt and stream the answer |
| `repl` | Interactive multi-turn session |
| `build` | Scaffold a project and run an autonomous build |
| `init` | Generate a CLAUDE.md for the project |
| `doctor` | Diagnose the environment — node, keys, bridge, MCP, network |
| `auth` | Manage API-key credentials (incl. encrypted export/import) |
| `config` | Get or set CLI configuration |
| `mcp` | Manage MCP servers in this project's `.mcp.json` |
| `plugin` | List, install or remove plugin bundles |
| `trust` | Manage trusted projects for hook execution |
| `worktree` | Git worktrees for parallel agent runs |
| `history` / `export` | List past sessions; export a transcript as markdown |
| `serve` | HTTP server exposing the agent over SSE |
| `acp-serve` | Serve the agent over ACP on stdin/stdout |
| `deploy` | Ship an iOS app to TestFlight or the App Store |
| `convert` | Convert a Flutter app to native iOS, Android and macOS |
| `generate-xcodeproj` | Build an Xcode project from a folder of Swift sources |
| `positioning` | Maintain PRODUCT.md — the product thesis and its evidence |
| `bridge` | Inspect or clean up Node agent-bridge subprocesses |
| `install` / `upgrade` | Symlink into PATH; re-run the installer |
| `open` / `ping` / `status` / `watch` | Drive a running LingCode.app |
| `completion` | Shell completion script |
| `telemetry` | Toggle anonymous usage telemetry |

## LingCode Cloud

When you are signed in to LingCode Cloud, the CLI registers a `lingcode-cloud`
MCP server automatically — no `.mcp.json` entry needed. `lingcode doctor` lists
it. That gives the agent a managed Postgres backend with auth, storage, email
and serverless functions, plus tools to deploy against it.

Frontend hosting is included:

- **`deploy_app`** — publish a built web app and get a live URL back. You (or
  the agent) run the project's own build; the tool packages the output directory
  and uploads it. Creating a new public app previews first and asks for
  confirmation; re-deploys update the same app and URL.
- **`list_apps`** / **`rollback_app`** — see what is deployed, roll code back to
  a retained version.

Native iOS, Android and React Native projects are refused before anything is
packaged, with the reason. Flutter, Expo, Capacitor and Ionic deploy their web
build and say so in the preview, so it is clear that what went live is the web
target rather than the mobile app.

## Package layout

```
.
├── Package.swift                       # 5.7 tools, macOS 13+
├── Sources/
│   ├── LingCodeIPC/                    # Shared wire protocol (the app imports this too)
│   │   └── IPCProtocol.swift
│   └── lingcode/
│       ├── LingCodeEntry.swift         # @main AsyncParsableCommand root
│       ├── IPCClient.swift             # Unix-socket client
│       ├── HeadlessClaude.swift        # Claude bridge path
│       ├── HeadlessOpenAICompat.swift  # OpenAI-compatible providers
│       ├── HeadlessCodex.swift         # Codex path
│       ├── CloudMCP.swift              # Registers the lingcode-cloud MCP server
│       ├── SecretStore.swift           # Keychain (macOS) / chmod-600 file (Linux)
│       ├── CLIResources.swift          # Bundle lookup — never use Bundle.module
│       ├── Commands/                   # One file per subcommand
│       └── Resources/agent-bridge/     # Bundled Node bridge + MCP proxy
└── Tests/
    ├── LingCodeCLITests/
    └── LingCodeIPCTests/
```

Agent internals (`AgentBridgeSession`, the OpenAI-compat loop, `MCPManager`,
`PermissionDecider`, `BridgeResourceLocator`) live in the sibling
`LingCodeAgentCore` package.

## Build

Build from the canonical repo — the path dependencies do not resolve here.

```bash
cd LingCodeCLI
swift build                           # debug   → .build/debug/lingcode
swift build --configuration release   # release → .build/release/lingcode
swift test                            # LingCodeCLITests + LingCodeIPCTests
```

Cutting a release tarball (signed and notarized, both architectures):

```bash
SIGN_AND_NOTARIZE=1 ./scripts/build-cli-standalone.sh <version> arm64
SIGN_AND_NOTARIZE=1 ./scripts/build-cli-standalone.sh <version> x86_64
```

That embeds a universal Node runtime so the tarball has no prerequisites, and
re-syncs `agent-bridge/` from the app source, which is its source of truth.

## Running from a dev build

```bash
export LINGCODE_AGENT_BRIDGE_DIR="$PWD/../LingCode/agent-bridge"
export ANTHROPIC_API_KEY=sk-ant-...
.build/debug/lingcode ask --provider claude "summarise this repo"
```

Any OpenAI-compatible provider needs no bridge:

```bash
export DEEPSEEK_API_KEY=sk-...
.build/debug/lingcode ask --provider deepseek "what is in this directory?"
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
[`LingCodeServer/README.md`](https://github.com/Xavierhuang/LingCode/blob/main/LingCodeServer/README.md).

## Wire protocol

Messages exchanged with the app are defined in
[`LingCodeIPC/IPCProtocol.swift`](Sources/LingCodeIPC/IPCProtocol.swift).
The socket is at `~/Library/Application Support/LingCode/ipc.sock`.

The Claude bridge protocol (Swift ↔ Node) is documented by the event
and command types in
[`AgentBridgeSession.swift`](https://github.com/Xavierhuang/LingCode/blob/main/LingCodeAgentCore/Sources/LingCodeAgentCore/AgentBridgeSession.swift)
and the command dispatcher in
[`bridge.mjs`](https://github.com/Xavierhuang/LingCode/blob/main/LingCode/agent-bridge/bridge.mjs).

## License

Same as the parent LingCode project.
