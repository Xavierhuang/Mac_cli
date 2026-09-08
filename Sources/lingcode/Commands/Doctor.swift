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

    @Flag(name: .long, help: "Run the iOS device-readiness checks even outside an Xcode project.")
    var ios: Bool = false

    func run() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        DoctorReport.run(cwd: cwd, includeNetwork: !noNetwork, forceIOS: ios)
    }
}

/// Shared check runner used by both `lingcode doctor` and the REPL's `/doctor`.
/// Keeps the logic in one place so the two surfaces don't drift.
enum DoctorReport {
    static func run(cwd: URL, includeNetwork: Bool, forceIOS: Bool = false) {
        Swift.print(ANSI.styled("LingCode doctor — \(version())", ANSI.bold, fd: STDOUT_FILENO))

        // — Node toolchain
        // Say WHICH node this is, not just that one exists. A tarball install that
        // silently falls back to a system node looks identical to a healthy one here,
        // and that is exactly how a resource-layout bug survived: doctor reported a
        // green Homebrew node while the CLI's own bundled copy sat unused. On a
        // machine with no system node — the machine this tarball exists for — the
        // same install simply does not run.
        let bundledNode = CLIResources.bundledNodePath()
        if let n = NodeResolver.resolve(extraSearchPaths: [bundledNode].compactMap { $0 }) {
            if let bundledNode, n == bundledNode {
                ok("node: \(n) (bundled)")
            } else if bundledNode == nil {
                warn("node: \(n) (system — this install has no bundled runtime, so it depends on your PATH)")
            } else {
                ok("node: \(n) (system — bundled runtime also present)")
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
            } else if label == "anthropic", let sub = ClaudeSubscriptionAuth.detect() {
                // A Pro/Max subscriber has no API key and needs none. Reporting a red
                // ✗ here sent them to buy metered credits they already had covered.
                ok("anthropic: \(sub.describedForDoctor) — no API key needed")
            } else {
                bad("\(label) key: not configured\(actLabel) — `lingcode auth login --provider \(label)`")
            }
        }

        // — LingModel hosted token. Kept out of the loop above: it has its own env
        // var and no ConfigStore fallback, but mainly because presence is not health
        // here. A vendor API key is valid until the user rotates it; a LingModel
        // token is server-side state that can be revoked out from under the machine
        // holding it — expiry, an explicit revoke, or the active-token cap silently
        // retiring the oldest (account-tokens.js `active_token_cap_exceeded`). A
        // green ✓ on mere presence is exactly how a dead credential on the DEFAULT
        // provider passed this check while every `lingcode` run 401'd. So verify it.
        let lmActive = cfg.activeAccountName(for: "lingmodel")
        let lmActLabel = lmActive.map { " (account=\($0))" } ?? ""
        let lmIsDefault = cfg.defaultProvider.lowercased() == "lingmodel"

        if let (lmToken, lmSource) = LingModelAuth.resolveToken(account: lmActive) {
            if !includeNetwork {
                neutral("lingmodel token: \(lmSource)\(lmActLabel) — present but NOT verified (--no-network)")
            } else {
                switch LingModelAuth.probe(token: lmToken) {
                case .valid(let tier):
                    ok("lingmodel token: \(lmSource)\(lmActLabel) — valid\(tier.map { " (tier=\($0))" } ?? "")")
                case .rateLimited:
                    ok("lingmodel token: \(lmSource)\(lmActLabel) — valid (currently rate-limited)")
                case .rejected:
                    bad("lingmodel token: \(lmSource)\(lmActLabel) — present but REJECTED by the server (expired, revoked, or retired by the active-token cap): \(LingModelAuth.remintHint)")
                case .unreachable:
                    neutral("lingmodel token: \(lmSource)\(lmActLabel) — present, could not verify (server unreachable)")
                }
            }
        } else if lmIsDefault {
            // Only an error when it's the provider bare `lingcode` will actually use.
            bad("lingmodel token: not configured\(lmActLabel) — and lingmodel is your DEFAULT provider, so every `lingcode` run will fail: \(LingModelAuth.remintHint)")
        } else {
            neutral("lingmodel token: not configured\(lmActLabel) — `lingcode auth login --provider lingmodel`")
        }

        // — Agent bridge
        let bundleURL = try? CLIResources.bundleURL()
        let bundledRoot = bundleURL?.appendingPathComponent("agent-bridge").path
        if let bundledRoot,
           let loc = try? BridgeResourceLocator(extraSearchRoots: [bundledRoot]).locate() {
            // The locator also searches an installed LingCode.app. Resolving there is
            // fine on this machine and misleading everywhere else, so name which one
            // answered rather than reporting a bare ✓.
            if loc.bridgeScriptPath.hasPrefix(bundledRoot) {
                ok("agent bridge: \(loc.bridgeScriptPath) (bundled)")
            } else {
                warn("agent bridge: \(loc.bridgeScriptPath) (LingCode.app — this install's own copy was not found)")
            }
            if let v = sdkVersion(at: loc.bridgeScriptPath) {
                info("  bundled sdk: \(v)")
            }
        } else {
            bad("agent bridge: missing — reinstall lingcode")
        }

        // — Project artifacts
        let hasClaudeMd = FileManager.default.fileExists(atPath: cwd.appendingPathComponent("CLAUDE.md").path)
        if hasClaudeMd { ok("CLAUDE.md present") } else { neutral("CLAUDE.md not found — `lingcode init` to generate") }

        // Includes the programmatically-injected `lingcode-cloud` server, so doctor
        // reports what a run will ACTUALLY start — not just what is on disk.
        let mcps = mergingCloudMCP(MCPConfig.load(cwd: cwd), cwd: cwd)
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

        // Trust state for the project at cwd. Enforced in HooksConfig.load.
        let projectSettings = cwd.appendingPathComponent(".claude/settings.json")
        if FileManager.default.fileExists(atPath: projectSettings.path) {
            if HookTrustStore.isTrusted(cwd: cwd) {
                ok("hook trust: project trusted (cwd recorded in ~/.lingcode/trusted-hooks.json)")
            } else {
                neutral("hook trust: project NOT trusted — project hooks are SKIPPED. Run `lingcode trust` to enable them.")
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

        #if os(macOS)
        // — iOS device readiness. Only for Apple app projects, or on request:
        // most projects never target a phone, and doctor earns its keep by staying
        // short enough to read.
        if forceIOS || looksLikeAppleAppProject(cwd) {
            iosDeviceReadiness()
        }
        #endif

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

    /// `DEVELOPMENT_TEAM` as declared in the project's pbxproj, or nil when no
    /// configuration sets it. Read from the file rather than via
    /// `xcodebuild -showBuildSettings`, which needs a scheme and takes seconds.
    private static func developmentTeam(in cwd: URL) -> String? {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: cwd, includingPropertiesForKeys: nil),
              let proj = children.first(where: { $0.pathExtension == "xcodeproj" }),
              let text = try? String(contentsOf: proj.appendingPathComponent("project.pbxproj"), encoding: .utf8)
        else { return nil }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("DEVELOPMENT_TEAM"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let value = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ;\t\""))
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// Leading integer of a version string — "26.5.1" → 26.
    private static func majorVersion(_ version: String) -> Int? {
        guard let first = version.split(separator: ".").first else { return nil }
        return Int(first)
    }

    /// Highest `iphoneos<major>` SDK the selected Xcode ships.
    private static func iPhoneOSSDKMajor() -> Int? {
        guard let out = capture("/usr/bin/xcodebuild", ["-showsdks"])?.stdout else { return nil }
        var best: Int?
        for token in out.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline }) {
            // "iphonesimulator26.5" must not match — the two can differ.
            guard token.hasPrefix("iphoneos") else { continue }
            guard let m = majorVersion(String(token.dropFirst("iphoneos".count))) else { continue }
            best = max(best ?? m, m)
        }
        return best
    }

    private static func ok(_ s: String)      { Swift.print("  \(ANSI.styled("✓", ANSI.green,  fd: STDOUT_FILENO)) \(s)") }
    private static func bad(_ s: String)     { Swift.print("  \(ANSI.styled("✗", ANSI.red,    fd: STDOUT_FILENO)) \(s)") }
    /// Works right now, but not the way the user probably assumes — a fallback that
    /// will not hold on a different machine. Distinct from ✓ on purpose: reporting
    /// these as healthy is how a broken install passes its own check.
    private static func warn(_ s: String)    { Swift.print("  \(ANSI.styled("⚠", ANSI.yellow, fd: STDOUT_FILENO)) \(s)") }
    private static func neutral(_ s: String) { Swift.print("  \(ANSI.styled("•", ANSI.dim,    fd: STDOUT_FILENO)) \(s)") }
    private static func info(_ s: String)    { Swift.print("  \(ANSI.styled("·", ANSI.dim,    fd: STDOUT_FILENO)) \(s)") }

    private static func version() -> String {
        // Falls back to the configuration-pinned string if Bundle.main isn't useful.
        return CLIVersion.display
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

    // MARK: iOS device readiness

    #if os(macOS)

    private static func looksLikeAppleAppProject(_ cwd: URL) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: cwd.path)) ?? []
        return entries.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }

    /// The four things that actually gate "run it on my iPhone".
    ///
    /// Deliberately does NOT check for a simulator runtime. Runtimes live outside
    /// Xcode.app (`/Library/Developer/CoreSimulator/Volumes`) and device builds use
    /// the `iphoneos` SDK, so a user can decline every runtime download and still
    /// install on a phone. Telling them otherwise sends them after a ~7 GB file
    /// they do not need.
    /// DEBUG-only test hooks, matching the ones in the app's XcodeToolchainService.
    ///
    /// Every branch below is unreachable on a working machine, so without these the
    /// failure messages ship having never been printed once. Signing out of Xcode
    /// does not reproduce the unsigned state either — codesigning certificates live
    /// in the login keychain and survive account removal.
    ///
    ///     LINGCODE_FAKE_NO_XCODE=1       no developer dir at all
    ///     LINGCODE_FAKE_CLT_ONLY=1       developer dir is Command Line Tools
    ///     LINGCODE_FAKE_NO_SIGNING=1     no codesigning identity
    ///     LINGCODE_FAKE_NO_PROFILES=1    no provisioning profiles yet
    ///     LINGCODE_FAKE_NO_DEVICE=1      nothing paired
    ///     LINGCODE_FAKE_DEV_MODE_OFF=1   paired, Developer Mode off
    ///
    /// Never compiled into Release builds.
    private static func fakeFlag(_ name: String) -> Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment[name] == "1"
        #else
        return false
        #endif
    }

    private static func iosDeviceReadiness() {
        // 1. Active developer directory + iOS SDK. The Command Line Tools package
        // ships macOS SDKs only, so `xcode-select --install` is never sufficient —
        // and a CLT-selected developer dir is the most common cause of "no iOS SDK".
        var devDir = (capture("/usr/bin/xcode-select", ["-p"])?.stdout ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if fakeFlag("LINGCODE_FAKE_NO_XCODE") { devDir = "" }
        if fakeFlag("LINGCODE_FAKE_CLT_ONLY") { devDir = "/Library/Developer/CommandLineTools" }

        if devDir.isEmpty {
            bad("iOS SDK: no Xcode found — install Xcode from the App Store. The iOS SDK ships inside Xcode.app; the Command Line Tools package alone is not enough.")
        } else if devDir.hasSuffix("CommandLineTools") {
            bad("iOS SDK: active developer dir is the Command Line Tools package, which has no iOS SDK — `sudo xcode-select -s /Applications/Xcode.app`")
        } else if let sdks = capture("/usr/bin/xcodebuild", ["-showsdks"])?.stdout,
                  let line = sdks.split(separator: "\n").first(where: { $0.contains("-sdk iphoneos") }) {
            let name = line.components(separatedBy: "-sdk ").last?
                .trimmingCharacters(in: .whitespaces) ?? "iphoneos"
            ok("iOS SDK: \(name)")
        } else {
            bad("iOS SDK: Xcode at \(devDir) reports no iphoneos SDK — open Xcode once to finish first-launch setup.")
        }

        // 1b. A development team on the project. Every host-level check above
        // can pass and a device build still fails with "Signing for X requires
        // a development team", because this is a property of the project rather
        // than the Mac. The GUI panel checks it; without this the CLI reported
        // a clean bill of health on a project that could not build.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        switch developmentTeam(in: cwd) {
        case .some(let team):
            ok("development team: \(team)")
        case nil:
            bad("development team: not set — a device build will fail with \"Signing for … requires a development team\". "
                + "Set it in LingCode (Settings → Build & Ship → Signing & Teams) or Xcode (Target → Signing & Capabilities). The simulator does not need it.")
        }

        // 2. A usable signing identity. A free Apple ID is enough to install on
        // your own phone (the app expires after 7 days); the paid program is only
        // needed to keep it installed or to use TestFlight.
        if let ids = capture("/usr/bin/security", ["find-identity", "-p", "codesigning", "-v"])?.stdout {
            var count = ids.split(separator: "\n")
                .first { $0.contains("valid identities found") }
                .map { String($0.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }) }
                .flatMap(Int.init) ?? 0
            if fakeFlag("LINGCODE_FAKE_NO_SIGNING") { count = 0 }
            if count > 0 {
                ok("signing identity: \(count) available")
            } else {
                // Same wording as the app's onboarding row and InstallErrorInterpreter:
                // names the menu bar, because ⌘, only reaches Xcode when Xcode holds
                // focus and its welcome window shows no Settings item on screen.
                bad("signing identity: none — in Xcode's menu bar choose Xcode → Settings → Accounts (or ⌘,) and add your Apple ID. A free account is enough for your own phone.")
            }
        }

        // 3. Provisioning profiles. Absence is not an error: automatic signing
        // creates the first one during the first device build.
        let profileDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles")
        var profiles = ((try? FileManager.default.contentsOfDirectory(atPath: profileDir.path)) ?? [])
            .filter { $0.hasSuffix(".mobileprovision") || $0.hasSuffix(".provisionprofile") }
        if fakeFlag("LINGCODE_FAKE_NO_PROFILES") { profiles = [] }
        if profiles.isEmpty {
            neutral("provisioning profiles: none yet — automatic signing creates one on the first device build")
        } else {
            ok("provisioning profiles: \(profiles.count)")
        }

        // 4. A reachable phone with Developer Mode on.
        reportDevices()
    }

    /// One physical iOS device as `devicectl` sees it.
    private struct DeviceCTLDevice {
        let name: String
        let reachable: Bool
        let developerMode: String?
        /// Needed to catch a phone whose iOS major is ahead of the selected
        /// Xcode's SDK — that phone reports its state as "unknown", so without
        /// the version the only thing to say is "couldn't read Developer Mode".
        var osVersion: String?
    }

    /// Parses `xcrun devicectl list devices --json-output`. Field mapping was taken
    /// from real output rather than the man page:
    ///   `hardwareProperties.reality` — "physical" | "simulated" (simulators appear
    ///     in this list too, and reporting one as a phone would be a lie)
    ///   `connectionProperties.tunnelState` — "unavailable" means not reachable;
    ///     "disconnected" is what Xcode shows as "available (paired)"
    ///   `deviceProperties.developerModeStatus` — "enabled" | "unknown" | absent
    private static func reportDevices() {
        if fakeFlag("LINGCODE_FAKE_NO_DEVICE") {
            bad("device: no iPhone or iPad paired — connect one by cable and tap Trust on the device")
            return
        }
        if fakeFlag("LINGCODE_FAKE_DEV_MODE_OFF") {
            reportDeveloperModeOff(name: "iPhone 16 Pro", status: "unknown")
            return
        }
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lingcode-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }

        // devicectl has its own --timeout, so doctor cannot hang here.
        guard let result = capture("/usr/bin/xcrun",
                                   ["devicectl", "list", "devices",
                                    "--json-output", out.path, "--timeout", "5"]),
              result.exitCode == 0,
              let data = try? Data(contentsOf: out),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (root["result"] as? [String: Any])?["devices"] as? [[String: Any]]
        else {
            neutral("device: could not query devicectl (needs Xcode 15+) — skipping")
            return
        }

        let phones: [DeviceCTLDevice] = devices.compactMap { entry in
            let hardware = entry["hardwareProperties"] as? [String: Any] ?? [:]
            // Only "iOS" was observable on the machine this was written against;
            // iPadOS is accepted too rather than risk telling an iPad user that no
            // device is paired. A Mac or Watch target is not what this check is for.
            let platform = hardware["platform"] as? String ?? ""
            guard hardware["reality"] as? String == "physical",
                  platform == "iOS" || platform == "iPadOS" else { return nil }
            let props = entry["deviceProperties"] as? [String: Any] ?? [:]
            let conn = entry["connectionProperties"] as? [String: Any] ?? [:]
            return DeviceCTLDevice(
                name: props["name"] as? String ?? "iPhone",
                reachable: (conn["tunnelState"] as? String) != "unavailable",
                developerMode: props["developerModeStatus"] as? String,
                osVersion: props["osVersionNumber"] as? String
            )
        }

        guard !phones.isEmpty else {
            bad("device: no iPhone or iPad paired — connect one by cable and tap Trust on the device")
            return
        }

        guard let live = phones.first(where: { $0.reachable }) else {
            let names = phones.map(\.name).prefix(3).joined(separator: ", ")
            bad("device: \(phones.count) paired but none reachable (\(names)) — plug in and unlock the phone, or join it to this Wi-Fi network")
            return
        }

        // Checked before Developer Mode, deliberately. Xcode ships no device
        // support for an OS released after it, so such a phone often reports
        // its Developer Mode as "unknown" — and saying so sends the user to fix
        // a setting that is already correct. The version gap is the real cause,
        // and the build succeeding is what makes it confusing, so say that too.
        if let os = live.osVersion, let deviceMajor = majorVersion(os),
           let sdkMajor = iPhoneOSSDKMajor(), deviceMajor > sdkMajor {
            bad("device: \(live.name) runs iOS \(os) but the selected Xcode carries the iOS \(sdkMajor) SDK — "
                + "compiling and signing succeed, the install fails and the debugger will not attach. "
                + "Select a newer Xcode (`sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer`) or update Xcode.")
        } else if live.developerMode == "enabled" {
            ok("device: \(live.name) ready")
        } else {
            reportDeveloperModeOff(name: live.name, status: live.developerMode)
        }
    }

    /// Single source for the Developer Mode message so the DEBUG fake exercises the
    /// text that actually ships rather than a copy of it.
    ///
    /// Apple: "Developer Mode only appears in Settings if you initiate pairing or if
    /// you previously paired the device to a Mac." Pointing at Settings alone sends
    /// first-timers hunting for a row that is not there yet, and the trigger is
    /// pairing rather than a build.
    private static func reportDeveloperModeOff(name: String, status: String?) {
        bad("device: \(name) reachable but Developer Mode is \(status ?? "not reported") — on the device: Settings → Privacy & Security → Developer Mode → on → Restart, then swipe up and tap Enable with your passcode. The row only appears once the device has been paired to this Mac.")
    }

    private struct CaptureResult {
        let exitCode: Int32
        let stdout: String
    }

    /// Runs a tool and captures stdout. Returns nil when the executable is missing
    /// or cannot be launched, which the callers treat as "not installed".
    private static func capture(_ launchPath: String, _ args: [String]) -> CaptureResult? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        // Drain before waiting: a full pipe buffer would deadlock the child.
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        proc.waitUntilExit()
        return CaptureResult(exitCode: proc.terminationStatus,
                             stdout: String(data: data, encoding: .utf8) ?? "")
    }

    #endif

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
