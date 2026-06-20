// Mac-only: depends on LingCodeServer (NWListener under the hood). On Linux
// the package dep is gated out in Package.swift, so this whole file compiles
// to nothing.
#if os(macOS)
import ArgumentParser
import Foundation
import LingCodeAgentCore
import LingCodeServer

@available(macOS 13, *)
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run an HTTP server that exposes the agent over /v1/agent/ask (SSE).",
        discussion: """
        Runs `lingcode` as an HTTP server so external clients (VS Code extensions,
        scripts, web UIs) can drive the agent the same way the GUI and `lingcode ask` do.

        Defaults to 127.0.0.1; non-loopback binds require --allow-remote.
        Every request must carry `Authorization: Bearer <token>`. The token is
        generated on first start, persisted at ~/.lingcode/server.token (chmod 600),
        and printed to stderr.

        Endpoints (v1):
          GET  /v1/ping                                  liveness + version
          POST /v1/agent/ask                             SSE stream of agent events
          POST /v1/agent/permission/{requestId}          allow/deny a tool call
          POST /v1/agent/cancel/{queryId}                cancel an in-flight query
          POST /v1/workspace/read                        read file → base64
          POST /v1/workspace/write                       write base64 → file
          POST /v1/workspace/list                        list a directory
          POST /v1/workspace/delete                      delete file or directory
          POST /v1/workspace/stat                        stat a path
          POST /v1/workspace/exec                        run a shell command
          GET  /v1/workspace/watch?path=/dir             SSE stream of FS events

        Smoke test:
          lingcode serve &
          TOKEN=$(cat ~/.lingcode/server.token)
          curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7878/v1/ping

        TLS is not implemented; front with caddy/nginx/cloudflared if exposing
        beyond the host.
        """
    )

    @Option(name: .long, help: "Bind host (default 127.0.0.1).")
    var bind: String = "127.0.0.1"

    @Option(name: .long, help: "Bind port (default 7878).")
    var port: Int = 7878

    @Flag(name: .long, help: "Required to bind a non-loopback host. Without this, --bind is ignored unless it's localhost.")
    var allowRemote: Bool = false

    @Flag(name: .long, help: "Regenerate the bearer token before starting.")
    var newToken: Bool = false

    @Option(name: .long, help: "Path to the bearer-token file (default ~/.lingcode/server.token).")
    var tokenFile: String?

    @Option(name: .long, help: "Cap on simultaneous SSE streams. Excess clients get 429. Default 8.")
    var maxConcurrent: Int = 8

    @Option(name: .long, help: "Account label for multi-account installs (controls which keychain entries the server reads). Per-request body field `account` overrides this.")
    var account: String?

    @Option(name: .long, help: "Reuse the bridge daemon at this Unix socket path instead of spawning a fresh Node process per Claude query (~200-500ms faster cold-start). 'auto' resolves to ~/.lingcode/bridge/daemon.sock if it exists.")
    var bridgeDaemon: String?

    @Option(name: .customLong("web-origin"), help: "Allow this browser origin to call the server cross-origin (e.g. 'https://lingcode.dev'). Repeatable. Without this, browsers can't reach the server even with a valid token. Non-browser clients (curl, scripts) are unaffected.")
    var webOrigins: [String] = []

    @Option(name: .customLong("workspace-root"), help: "Absolute path that bounds all /v1/workspace/* file operations. Requests resolving outside this root return 403. Defaults to the CWD where 'lingcode serve' was launched.")
    var workspaceRoot: String?

    @Flag(name: .shortAndLong, help: "Suppress startup banner.")
    var quiet: Bool = false

    func run() async throws {
        CLIEnvironment.apply(noColor: false, quiet: quiet, account: account)

        let path = tokenFile.map { ($0 as NSString).expandingTildeInPath } ?? TokenStore.defaultTokenPath()
        let (token, freshlyGenerated): (String, Bool)
        do {
            (token, freshlyGenerated) = try TokenStore.loadOrCreate(at: path, regenerate: newToken)
        } catch {
            FileHandle.standardError.write(Data("lingcode serve: \(error)\n".utf8))
            throw ExitCode(1)
        }

        let resolvedWorkspaceRoot: String = {
            if let raw = workspaceRoot, !raw.isEmpty {
                let expanded = (raw as NSString).expandingTildeInPath
                // Normalize to absolute via FileManager; relative input is
                // anchored to CWD at launch time, not whatever a request's
                // resolution context might imply.
                let url = URL(fileURLWithPath: expanded).standardizedFileURL
                return url.path
            }
            return FileManager.default.currentDirectoryPath
        }()

        if !PathSandbox.validateRootIsDirectory(resolvedWorkspaceRoot) {
            FileHandle.standardError.write(Data(
                "lingcode serve: warning: workspace-root '\(resolvedWorkspaceRoot)' does not exist or is not a directory — /v1/workspace/* requests will fail until it does\n".utf8
            ))
        }

        let configuration = ServerConfiguration(
            bindHost: bind,
            port: port,
            allowRemote: allowRemote,
            token: token,
            maxConcurrentQueries: maxConcurrent,
            allowedWebOrigins: webOrigins,
            workspaceRoot: resolvedWorkspaceRoot
        )
        let resolvedDaemon = resolveDaemonSocketPath()
        let hooks = CLIServerHooks(account: account, bridgeDaemonSocket: resolvedDaemon)
        let server = HTTPServer(configuration: configuration, hooks: hooks)

        do {
            try server.start()
        } catch {
            FileHandle.standardError.write(Data("lingcode serve: \(error)\n".utf8))
            throw ExitCode(1)
        }

        // Session lifecycle for the long-running daemon. SessionStart fires once on
        // boot; SessionEnd fires from the signal handler on SIGINT/SIGTERM (the
        // `Task.sleep(forever)` below parks the process until then). The unreachable
        // server.stop() at the bottom of run() also fires SessionEnd defensively in
        // case the sleep ever returns. Per-request session hooks are out of scope —
        // the daemon is treated as one long session per [docs/HOOKS.md](docs/HOOKS.md).
        let _serveCwd = URL(fileURLWithPath: resolvedWorkspaceRoot)
        let _sessionId = await SessionLifecycleHook.fireStart(
            command: "serve",
            provider: "server",
            model: "n/a",
            cwd: _serveCwd
        )
        SessionLifecycleHook.installSignalHandlers(
            sessionId: _sessionId,
            provider: "server",
            model: "n/a",
            cwd: _serveCwd,
            turnCountProvider: { 0 }
        )

        if !CLIEnvironment.quiet {
            var banner = """
                lingcode serve listening on http://\(bind):\(port)
                token: \(token)\(freshlyGenerated ? "  (newly generated)" : "")
                token file: \(path)
                workspace root: \(resolvedWorkspaceRoot)
                """
            if let daemon = resolvedDaemon {
                banner += "\nbridge daemon: \(daemon)"
            }
            FileHandle.standardError.write(Data((banner + "\n").utf8))
        }

        // Park forever — the listener runs on its own queue. We only return on
        // SIGINT/SIGTERM. (Process inherits stdin/stdout, so users get a real
        // Ctrl-C; ArgumentParser converts the EXC into ExitCode 130.)
        try await Task.sleep(nanoseconds: UInt64.max / 2)
        // Unreachable, but cleanly stop the server if the sleep ever returns.
        server.stop()
        await SessionLifecycleHook.fireEnd(
            sessionId: _sessionId, provider: "server", model: "n/a",
            cwd: _serveCwd, turnCount: 0, terminatedBy: "completion"
        )
    }

    /// Resolve `--bridge-daemon`: nil → no daemon, "auto" → default daemon
    /// path if it exists, otherwise treat as a literal socket path.
    private func resolveDaemonSocketPath() -> String? {
        guard let raw = bridgeDaemon, !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        if raw.lowercased() == "auto" {
            let defaultPath = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".lingcode/bridge/daemon.sock")
                .path
            return FileManager.default.fileExists(atPath: defaultPath) ? defaultPath : nil
        }
        return expanded
    }
}

/// CLI-side `ServerHooks` impl: resolves Node + bridge resources via the same
/// helpers `lingcode ask --provider claude` uses, and reads API keys with the
/// same env → keychain → config fallback order.
private struct CLIServerHooks: ServerHooks {
    let account: String?
    let bridgeDaemonSocket: String?

    var version: String { LingCode.configuration.version }

    func nodePath() throws -> String {
        let extras = [CLIResources.bundledNodePath()].compactMap { $0 }
        guard let path = NodeResolver.resolve(extraSearchPaths: extras) else {
            throw ServerHooksError.nodeMissing
        }
        return path
    }

    func bridgeResources() throws -> BridgeResources {
        do {
            let bundledRoot = try CLIResources.bundleURL()
                .appendingPathComponent("agent-bridge").path
            return try BridgeResourceLocator(extraSearchRoots: [bundledRoot]).locate()
        } catch let err as CLIResources.LookupError {
            throw ServerHooksError.bridgeMissing(err.description)
        } catch let err as BridgeResourceLocator.LocationError {
            throw ServerHooksError.bridgeMissing(err.description)
        }
    }

    func bridgeDaemonSocketPath() -> String? { bridgeDaemonSocket }

    func anthropicAPIKey(account requestAccount: String?) -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty {
            return env
        }
        let resolvedAccount = requestAccount ?? CLIEnvironment.resolvedAccount(forProvider: "anthropic")
        let kAccount = keychainAccount(base: "anthropic-api-key", account: resolvedAccount)
        if let kc = try? SecretStore.get(service: keychainService, account: kAccount), !kc.isEmpty {
            return kc
        }
        return ConfigStore.load().anthropicAPIKey
    }

    func deepseekAPIKey(account requestAccount: String?) -> String? {
        if let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !env.isEmpty {
            return env
        }
        let resolvedAccount = requestAccount ?? CLIEnvironment.resolvedAccount(forProvider: "deepseek")
        let kAccount = keychainAccount(base: "deepseek-api-key", account: resolvedAccount)
        if let kc = try? SecretStore.get(service: keychainService, account: kAccount), !kc.isEmpty {
            return kc
        }
        return ConfigStore.load().deepseekAPIKey
    }

    func openAICompatAPIKey(provider: String, account requestAccount: String?) -> String? {
        // Map LingCode's provider name → the canonical OpenAICompatProvider so
        // we know which env var + keychain slot to read.
        let normalized = provider == "openai-compat" ? "openai" : provider
        guard let preset = OpenAICompatProvider(rawValue: normalized) else { return nil }
        let envVar = preset.envVar
        if let env = ProcessInfo.processInfo.environment[envVar], !env.isEmpty {
            return env
        }
        let base = envVar.lowercased().replacingOccurrences(of: "_", with: "-")
        let resolvedAccount = requestAccount ?? CLIEnvironment.resolvedAccount(forProvider: provider)
        let kAccount = keychainAccount(base: base, account: resolvedAccount)
        if let kc = try? SecretStore.get(service: keychainService, account: kAccount), !kc.isEmpty {
            return kc
        }
        return nil
    }
}
#endif
