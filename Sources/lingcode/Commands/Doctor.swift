import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingCodeAgentCore

/// `lingcode doctor` — a single-shot environment diagnosis. Same checks as
/// `/doctor` in the REPL plus a few that only make sense outside an active
/// session (network reachability, version, on-disk session storage health).
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose the LingCode environment (node, keys, bridge, network, etc.)."
    )

    @Flag(name: .long, help: "Skip the network reachability probe to Anthropic (offline runs).")
    var noNetwork: Bool = false

    func run() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        DoctorReport.run(cwd: cwd, includeNetwork: !noNetwork)
    }
}

/// Shared check runner used by both `lingcode doctor` and the REPL's `/doctor`.
/// Keeps the logic in one place so the two surfaces don't drift.
enum DoctorReport {
    static func run(cwd: URL, includeNetwork: Bool) {
        Swift.print(ANSI.styled("LingCode doctor — \(version())", ANSI.bold, fd: STDOUT_FILENO))

        // — Node toolchain
        let bundledNode = CLIResources.bundledNodePath()
        if let n = NodeResolver.resolve(extraSearchPaths: [bundledNode].compactMap { $0 }) {
            if let bundledNode, n == bundledNode {
                ok("node: \(n) (bundled)")
            } else {
                ok("node: \(n)")
            }
        } else {
            if bundledNode == nil {
                bad("node: bundled runtime missing (reinstall lingcode), and no system node on PATH. Fallback: install from https://nodejs.org or `brew install node`.")
            } else {
                bad("node: not executable at bundled path or on PATH — try `chmod +x \(bundledNode!)` or reinstall lingcode.")
            }
        }

        // — API key resolution (per provider)
        let cfg = ConfigStore.load()
        for (label, env, kAccount, configValue) in [
            ("anthropic", "ANTHROPIC_API_KEY", "anthropic-api-key", cfg.anthropicAPIKey),
            ("deepseek",  "DEEPSEEK_API_KEY",  "deepseek-api-key",  cfg.deepseekAPIKey)
        ] {
            let active = cfg.activeAccountName(for: label)
            let actLabel = active.map { " (account=\($0))" } ?? ""
            let envVal = ProcessInfo.processInfo.environment[env]?.trimmingCharacters(in: .whitespaces) ?? ""
            let kc = (try? SecretStore.get(service: keychainService, account: keychainAccount(base: kAccount, account: active))) ?? ""
            if !envVal.isEmpty {
                ok("\(label) key: env\(actLabel)")
            } else if !kc.isEmpty {
                ok("\(label) key: keychain\(actLabel)")
            } else if !(configValue ?? "").isEmpty {
                ok("\(label) key: config\(actLabel)")
            } else {
                bad("\(label) key: not configured\(actLabel) — `lingcode auth login --provider \(label)`")
            }
        }

        // — Agent bridge
        let bundleURL = try? CLIResources.bundleURL()
        let bundledRoot = bundleURL?.appendingPathComponent("agent-bridge").path
        if let bundledRoot,
           let loc = try? BridgeResourceLocator(extraSearchRoots: [bundledRoot]).locate() {
            ok("agent bridge: \(loc.bridgeScriptPath)")
            if let v = sdkVersion(at: loc.bridgeScriptPath) {
                info("  bundled sdk: \(v)")
            }
        } else {
            bad("agent bridge: missing — reinstall lingcode")
        }

        // — Project artifacts
        let hasClaudeMd = FileManager.default.fileExists(atPath: cwd.appendingPathComponent("CLAUDE.md").path)
        if hasClaudeMd { ok("CLAUDE.md present") } else { neutral("CLAUDE.md not found — `lingcode init` to generate") }

        let mcps = MCPConfig.load(cwd: cwd)
        if mcps.isEmpty { neutral("MCP servers: none configured") } else { ok("MCP servers: \(mcps.keys.sorted().joined(separator: ", "))") }

        let hooks = HooksConfig.load(cwd: cwd)
        let hookCount = hooks.rules.values.reduce(0) { $0 + $1.count }
        if hookCount == 0 {
            neutral("hooks: none")
        } else {
            // Break down by event so users can see which lifecycle points are wired.
            let breakdown = hooks.rules
                .filter { !$0.value.isEmpty }
                .map { "\($0.key.rawValue):\($0.value.count)" }
                .sorted()
                .joined(separator: ", ")
            ok("hooks: \(hookCount) configured (\(breakdown))")
        }

        // Trust state for the project at cwd. v1 displays only; v1.1 will enforce.
        let projectSettings = cwd.appendingPathComponent(".claude/settings.json")
        if FileManager.default.fileExists(atPath: projectSettings.path) {
            if HookTrustStore.isTrusted(cwd: cwd) {
                ok("hook trust: project trusted (cwd recorded in ~/.lingcode/trusted-hooks.json)")
            } else {
                neutral("hook trust: project NOT trusted — run `lingcode trust` to opt in (gating starts in v1.1)")
            }
        }

        let agents = Subagent.list(cwd: cwd)
        if agents.isEmpty { neutral("subagents: none") } else { ok("subagents: \(agents.count) (\(agents.prefix(5).joined(separator: ", "))\(agents.count > 5 ? "…" : ""))") }

        let outputStyles = listFiles(cwd.appendingPathComponent(".claude/output-styles"), homeFallback: ".claude/output-styles")
        if outputStyles.isEmpty { neutral("output styles: built-in only") } else { ok("output styles: \(outputStyles.count) custom") }

        let plugins = countPlugins(cwd: cwd)
        if plugins == 0 { neutral("plugins: none") } else { ok("plugins: \(plugins) installed") }

        // — On-disk session state
        let sessionsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".lingcode/sessions")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDir.path)) ?? []
        info("session pointers on disk: \(entries.count)")

        // CostEstimator's pricing table goes stale as vendors change rates.
        // Warn when it's been more than 90 days since the last manual review so
        // a maintainer notices before a release.
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
        if let updated = f.date(from: CostEstimator.rateTableUpdated + "T00:00:00Z") {
            let days = Int(Date().timeIntervalSince(updated) / 86_400)
            if days > 90 {
                bad("cost estimator rates: \(days) days stale (last updated \(CostEstimator.rateTableUpdated)) — refresh CostEstimator.swift")
            } else {
                ok("cost estimator rates: \(days) days old (last updated \(CostEstimator.rateTableUpdated))")
            }
        }

        // — Network probe (Anthropic API reachability)
        if includeNetwork {
            switch probeAnthropic(timeout: 4.0) {
            case .ok(let ms):       ok("anthropic.com reachable (\(ms) ms)")
            case .timeout:          bad("anthropic.com unreachable — check network/firewall")
            case .httpError(let s): bad("anthropic.com returned HTTP \(s) — possible outage; check status.anthropic.com")
            case .skipped:          neutral("network probe skipped")
            }
        } else {
            neutral("network probe skipped (--no-network)")
        }
    }

    // MARK: helpers

    private static func ok(_ s: String)      { Swift.print("  \(ANSI.styled("✓", ANSI.green,  fd: STDOUT_FILENO)) \(s)") }
    private static func bad(_ s: String)     { Swift.print("  \(ANSI.styled("✗", ANSI.red,    fd: STDOUT_FILENO)) \(s)") }
    private static func neutral(_ s: String) { Swift.print("  \(ANSI.styled("•", ANSI.dim,    fd: STDOUT_FILENO)) \(s)") }
    private static func info(_ s: String)    { Swift.print("  \(ANSI.styled("·", ANSI.dim,    fd: STDOUT_FILENO)) \(s)") }

    private static func version() -> String {
        // Falls back to the configuration-pinned string if Bundle.main isn't useful.
        return "v0.8.16"
    }

    /// Reads `package.json` from the agent-bridge node_modules to surface the
    /// shipped Agent SDK version. Helps users tell us "I'm on SDK X" in bug reports.
    private static func sdkVersion(at bridgePath: String) -> String? {
        let dir = (bridgePath as NSString).deletingLastPathComponent
        let pj = URL(fileURLWithPath: dir).appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk/package.json")
        guard let data = try? Data(contentsOf: pj),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj["version"] as? String else { return nil }
        return v
    }

    private static func listFiles(_ url: URL, homeFallback: String) -> [String] {
        var combined = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(homeFallback)
        combined += (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return combined.filter { $0.hasSuffix(".md") }
    }

    private static func listDirs(_ url: URL, homeFallback: String) -> [String] {
        var combined = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(homeFallback)
        combined += (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return combined
    }

    /// A plugin only counts when its directory contains a `manifest.json`. Skips
    /// stray symlinks, .DS_Store, and other detritus that the previous heuristic
    /// (raw directory entry count) was over-counting.
    private static func countPlugins(cwd: URL) -> Int {
        let dirs = [
            cwd.appendingPathComponent(".claude/plugins"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/plugins")
        ]
        var seen = Set<String>()
        for parent in dirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { continue }
            for entry in entries {
                let manifest = parent.appendingPathComponent(entry).appendingPathComponent("manifest.json")
                if FileManager.default.fileExists(atPath: manifest.path) {
                    seen.insert(entry)
                }
            }
        }
        return seen.count
    }

    enum NetworkProbeResult {
        case ok(latencyMs: Int), timeout, httpError(Int), skipped
    }

    /// HEAD request to api.anthropic.com with a short timeout. We don't actually
    /// hit a real endpoint that requires auth — just measure connectability.
    /// Synchronous over a dispatch group; doctor isn't a hot path.
    private static func probeAnthropic(timeout: TimeInterval) -> NetworkProbeResult {
        let url = URL(string: "https://api.anthropic.com")!
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "HEAD"
        let group = DispatchGroup()
        group.enter()
        var result: NetworkProbeResult = .timeout
        let start = Date()
        URLSession.shared.dataTask(with: req) { _, response, error in
            defer { group.leave() }
            if let _ = error { result = .timeout; return }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
                result = .httpError(http.statusCode)
            } else {
                result = .ok(latencyMs: ms)
            }
        }.resume()
        _ = group.wait(timeout: .now() + timeout + 1)
        return result
    }
}
