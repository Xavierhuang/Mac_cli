import ArgumentParser
import Foundation
import LingCodeAgentCore

// Single source of truth for the providers `auth` knows how to manage.
// New providers go here — the picker, accountFor, and status all read from this list.
struct AuthProvider {
    let name: String        // canonical CLI name
    let display: String     // human label for the picker
    let envVar: String      // shell env var users may set instead
    let consoleURL: String  // where to send users to mint a key (empty = no portal)
    let account: String     // keychain account
}

private let knownProviders: [AuthProvider] = [
    // LingModel — the hosted free/pro path. Mints a CLI token tied to
    // your LingCode account; the CLI routes requests through the proxy
    // at lingcode.dev/api/inference/anthropic instead of hitting Anthropic
    // directly. No third-party API key needed.
    .init(name: "lingmodel",  display: "LingModel (your LingCode account)", envVar: "LINGCODE_CLI_TOKEN", consoleURL: "https://lingcode.dev/cli-token.html",                 account: "lingmodel-cli-token"),
    .init(name: "anthropic",  display: "Anthropic (Claude)",          envVar: "ANTHROPIC_API_KEY",   consoleURL: "https://console.anthropic.com/settings/keys",        account: "anthropic-api-key"),
    .init(name: "openai",     display: "OpenAI",                      envVar: "OPENAI_API_KEY",      consoleURL: "https://platform.openai.com/api-keys",               account: "openai-api-key"),
    .init(name: "deepseek",   display: "DeepSeek",                    envVar: "DEEPSEEK_API_KEY",    consoleURL: "https://platform.deepseek.com/api_keys",             account: "deepseek-api-key"),
    // Alias: shares the deepseek-api-key keychain entry. Exists so users who pick
    // --provider deepseek-claude in `ask`/`repl` (bridge-routed via DeepSeek's
    // /anthropic shim) can run `auth login --provider deepseek-claude` without
    // surprise. One key, two routing paths.
    .init(name: "deepseek-claude", display: "DeepSeek (via Claude Code agent loop)", envVar: "DEEPSEEK_API_KEY", consoleURL: "https://platform.deepseek.com/api_keys",     account: "deepseek-api-key"),
    .init(name: "gemini",     display: "Google Gemini",               envVar: "GEMINI_API_KEY",      consoleURL: "https://aistudio.google.com/app/apikey",             account: "gemini-api-key"),
    .init(name: "groq",       display: "Groq",                        envVar: "GROQ_API_KEY",        consoleURL: "https://console.groq.com/keys",                      account: "groq-api-key"),
    .init(name: "together",   display: "Together",                    envVar: "TOGETHER_API_KEY",    consoleURL: "https://api.together.ai/settings/api-keys",          account: "together-api-key"),
    .init(name: "openrouter", display: "OpenRouter",                  envVar: "OPENROUTER_API_KEY",  consoleURL: "https://openrouter.ai/keys",                         account: "openrouter-api-key"),
    .init(name: "mistral",    display: "Mistral",                     envVar: "MISTRAL_API_KEY",     consoleURL: "https://console.mistral.ai/api-keys/",               account: "mistral-api-key"),
    .init(name: "xai",        display: "xAI (Grok)",                  envVar: "XAI_API_KEY",         consoleURL: "https://console.x.ai/",                              account: "xai-api-key"),
    .init(name: "fireworks",  display: "Fireworks",                   envVar: "FIREWORKS_API_KEY",   consoleURL: "https://fireworks.ai/account/api-keys",              account: "fireworks-api-key"),
    .init(name: "kimi",       display: "Kimi (Moonshot)",             envVar: "MOONSHOT_API_KEY",    consoleURL: "https://platform.moonshot.cn/console/api-keys",      account: "kimi-api-key"),
    .init(name: "qwen",       display: "Qwen (DashScope)",            envVar: "DASHSCOPE_API_KEY",   consoleURL: "https://dashscope.console.aliyun.com/apiKey",        account: "qwen-api-key"),
    .init(name: "z-ai",       display: "z.ai (GLM)",                  envVar: "ZAI_API_KEY",         consoleURL: "https://z.ai/manage-apikey/apikey-list",             account: "z-ai-api-key"),
]

private func providerByName(_ name: String) -> AuthProvider? {
    knownProviders.first { $0.name == name.lowercased() }
}

/// True when no usable credential (env var, keychain, or config) is configured
/// for `defaultProvider`. The REPL uses this to launch first-run onboarding (the
/// `auth login` picker) instead of dead-ending on a missing key. Maps the REPL's
/// provider id onto the `auth` table; an unknown/custom provider returns false so
/// onboarding never intercepts a deliberately-configured BYO setup.
func firstRunCredentialMissing(defaultProvider: String) -> Bool {
    let name: String
    switch defaultProvider.lowercased() {
    case "", "claude", "anthropic":                        name = "anthropic"
    case "deepseek-claude", "deepseek-compat", "deepseek": name = "deepseek"
    default:                                               name = defaultProvider.lowercased()
    }
    guard let p = providerByName(name) else { return false }
    if let env = ProcessInfo.processInfo.environment[p.envVar], !env.isEmpty { return false }
    let acct = keychainAccount(base: p.account, account: CLIEnvironment.resolvedAccount(forProvider: name))
    if let kc = try? SecretStore.get(service: keychainService, account: acct), !kc.isEmpty { return false }
    let cfg = ConfigStore.load()
    if name == "anthropic", let k = cfg.anthropicAPIKey, !k.isEmpty { return false }
    if name == "deepseek", let k = cfg.deepseekAPIKey, !k.isEmpty { return false }
    if name == "lingmodel",
       let env = ProcessInfo.processInfo.environment["LINGCODE_CLI_TOKEN"], !env.isEmpty { return false }
    return true
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Auth: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage API key credentials.",
        discussion: """
        Store, retrieve, or delete API keys. Keys are saved in the macOS Keychain
        and sourced automatically at runtime (env vars still take precedence).

        Supported providers: \(knownProviders.map(\.name).joined(separator: ", ")).

        Examples:
          lingcode auth login                     # interactive picker
          lingcode auth login --provider openai   # skip the picker
          lingcode auth set anthropic sk-ant-...  # direct
          lingcode auth status
          lingcode auth delete deepseek
        """,
        subcommands: Auth.allSubcommands
    )

    /// AuthExport / AuthImport require CryptoKit (Apple-only). On Linux those
    /// two subcommands are dropped from `lingcode auth` until we add a
    /// swift-crypto fallback.
    private static var allSubcommands: [ParsableCommand.Type] {
        var subs: [ParsableCommand.Type] = [
            Login.self, SetKey.self, GetKey.self, DeleteKey.self,
            AuthStatus.self, ListAccounts.self, UseAccount.self,
        ]
        #if canImport(CryptoKit)
        subs.append(contentsOf: [AuthExport.self, AuthImport.self])
        #endif
        return subs
    }

    // MARK: - login (browser-assisted)

    struct Login: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "login",
            abstract: "Pick a provider, open its console, and paste in your API key.",
            discussion: """
            Without --provider, prompts with a numbered picker. With --provider, jumps
            straight to that provider's console.

            Anthropic does not issue OAuth client IDs to third-party CLIs, so a true
            OAuth flow is not possible. This browser-assisted flow is the next best thing.
            """
        )

        @Option(name: .long, help: "Provider name. Omit to choose from a picker.")
        var provider: String?

        @Option(name: .long, help: "Account label (e.g. \"work\", \"personal\"). Allows storing multiple keys per provider; omit to use the default slot.")
        var account: String?

        @Flag(name: .long, help: "Do not open a browser; just prompt for the key.")
        var noBrowser: Bool = false

        /// Set by first-run REPL onboarding (not a CLI flag): always make the
        /// chosen provider the default, skipping the "[y/N]" prompt — a fresh
        /// setup has no existing default worth preserving.
        var forceDefault: Bool = false

        func run() throws {
            let chosen: AuthProvider
            if let name = provider {
                guard let p = providerByName(name) else {
                    let known = knownProviders.map(\.name).joined(separator: ", ")
                    FileHandle.standardError.write(Data("lingcode: unknown provider '\(name)'. Known: \(known)\n".utf8))
                    throw ExitCode(2)
                }
                chosen = p
            } else {
                guard let p = try pickProviderInteractively() else {
                    FileHandle.standardError.write(Data("lingcode: no provider selected.\n".utf8))
                    throw ExitCode(1)
                }
                chosen = p
            }

            // Device flow: only for lingmodel (the hosted-account path), and
            // only when we can open a browser. Falls back to manual paste on
            // any failure so users on locked-down environments still work.
            #if canImport(Network)
            if chosen.name == "lingmodel", !noBrowser {
                Swift.print("Opening browser to sign in…")
                if let token = runDeviceFlow(consoleURL: chosen.consoleURL) {
                    let kAccount = keychainAccount(base: chosen.account, account: account)
                    try SecretStore.set(service: keychainService, account: kAccount, secret: token)
                    try? registerAccount(provider: chosen.name, account: account)
                    let label = (account?.isEmpty == false) ? " (\(account!))" : ""
                    Swift.print("✓ \(chosen.name)\(label) token saved to keychain.")
                    return
                } else {
                    FileHandle.standardError.write(Data("Browser handoff did not complete — falling back to manual paste.\n".utf8))
                }
            }
            #endif

            if !noBrowser, !chosen.consoleURL.isEmpty {
                Swift.print("Opening \(chosen.consoleURL)")
                let open = Process()
                open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                open.arguments = [chosen.consoleURL]
                try? open.run()
                open.waitUntilExit()
            } else if !chosen.consoleURL.isEmpty {
                Swift.print("Visit \(chosen.consoleURL) to generate a key, then paste it below.")
            }

            guard let tty = TTYIO.open() else {
                FileHandle.standardError.write(Data("lingcode: cannot open /dev/tty for key entry.\n".utf8))
                throw ExitCode(1)
            }
            defer { tty.close() }
            tty.write("Paste your \(chosen.display) API key: ")
            let raw = tty.readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !raw.isEmpty else {
                FileHandle.standardError.write(Data("lingcode: no key entered, aborting.\n".utf8))
                throw ExitCode(1)
            }
            let kAccount = keychainAccount(base: chosen.account, account: account)
            try SecretStore.set(service: keychainService, account: kAccount, secret: raw)
            try? registerAccount(provider: chosen.name, account: account)
            let label = (account?.isEmpty == false) ? " (\(account!))" : ""
            Swift.print("✓ \(chosen.name)\(label) API key saved to keychain.")

            // Offer to make this the default provider — saving a key alone
            // doesn't switch what `lingcode` uses, which surprises users.
            if chosen.name != "anthropic" {
                let providerForRepl = (chosen.name == "deepseek") ? "deepseek-compat" : chosen.name
                let makeDefault: Bool
                if forceDefault {
                    makeDefault = true
                } else {
                    tty.write("Make \(chosen.display) the default provider? [y/N]: ")
                    let ans = (tty.readLine()?.trimmingCharacters(in: .whitespaces).lowercased()) ?? ""
                    makeDefault = (ans == "y" || ans == "yes")
                }
                if makeDefault {
                    var cfg = ConfigStore.load()
                    cfg.defaultProvider = providerForRepl
                    try ConfigStore.save(cfg)
                    Swift.print("✓ default provider → \(providerForRepl)")
                }
            }
        }

        /// Synchronous bridge for the async `CLIDeviceFlow.run()`. Returns nil
        /// on any failure (timeout, port bind error, browser refusal) so the
        /// caller can fall back to the manual paste flow without crashing the
        /// `ParsableCommand`-style sync `run()` body.
        #if canImport(Network)
        private func runDeviceFlow(consoleURL: String) -> String? {
            // Run the async flow on a background queue so we can `wait()` on
            // its completion semaphore from the calling thread (which here is
            // the synchronous ParsableCommand.run body).
            let semaphore = DispatchSemaphore(value: 0)
            var token: String? = nil
            let url = consoleURL.isEmpty ? "https://lingcode.dev/cli-token.html" : consoleURL
            Task.detached {
                do {
                    let result = try await CLIDeviceFlow.run(baseURL: url)
                    token = result.token
                } catch {
                    FileHandle.standardError.write(Data("device flow: \(error)\n".utf8))
                }
                semaphore.signal()
            }
            semaphore.wait()
            return token
        }
        #endif

        private func pickProviderInteractively() throws -> AuthProvider? {
            guard let tty = TTYIO.open() else {
                FileHandle.standardError.write(Data("lingcode: cannot open /dev/tty for picker.\n".utf8))
                throw ExitCode(1)
            }
            defer { tty.close() }

            let labels = knownProviders.map { $0.display }
            guard let idx = tty.pick(prompt: "Choose a provider (↑↓ Enter):", items: labels) else {
                return nil
            }
            return knownProviders[idx]
        }
    }

    // MARK: - set

    struct SetKey: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Store an API key in the macOS SecretStore."
        )

        @Argument(help: "Provider name (run `lingcode auth login` to see all).")
        var provider: String

        @Argument(help: "API key value")
        var key: String

        @Option(name: .long, help: "Account label for multi-account setups (e.g. \"work\"). Omit for the default slot.")
        var account: String?

        func run() throws {
            let base = try accountFor(provider)
            let kAccount = keychainAccount(base: base, account: account)
            try SecretStore.set(service: keychainService, account: kAccount, secret: key)
            try? registerAccount(provider: provider, account: account)
            let label = (account?.isEmpty == false) ? " (\(account!))" : ""
            Swift.print("✓ \(provider)\(label) API key saved to keychain.")
        }
    }

    // MARK: - get

    struct GetKey: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Print a stored API key (to stdout — handle with care)."
        )

        @Argument(help: "Provider name")
        var provider: String

        @Option(name: .long, help: "Account label for multi-account setups. Omit to read the default slot.")
        var account: String?

        func run() throws {
            let base = try accountFor(provider)
            let kAccount = keychainAccount(base: base, account: account)
            if let value = try? SecretStore.get(service: keychainService, account: kAccount) {
                Swift.print(value)
            } else {
                let label = (account?.isEmpty == false) ? " (\(account!))" : ""
                FileHandle.standardError.write(Data("lingcode: no key stored for \(provider)\(label)\n".utf8))
                throw ExitCode(1)
            }
        }
    }

    // MARK: - delete

    struct DeleteKey: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Remove a stored API key from the SecretStore."
        )

        @Argument(help: "Provider name")
        var provider: String

        @Option(name: .long, help: "Account label to delete. Omit to remove the default slot.")
        var account: String?

        func run() throws {
            let base = try accountFor(provider)
            let kAccount = keychainAccount(base: base, account: account)
            try? SecretStore.delete(service: keychainService, account: kAccount)
            try? unregisterAccount(provider: provider, account: account)
            let label = (account?.isEmpty == false) ? " (\(account!))" : ""
            Swift.print("✓ \(provider)\(label) API key removed from keychain.")
        }
    }

    // MARK: - status

    struct AuthStatus: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show which API keys are configured (env / keychain / config), with values masked."
        )

        func run() throws {
            let cfg = ConfigStore.load()
            for p in knownProviders {
                let active = cfg.activeAccountName(for: p.name)
                let kAccount = keychainAccount(base: p.account, account: active)
                let envValue = ProcessInfo.processInfo.environment[p.envVar]?.trimmingCharacters(in: .whitespaces)
                let keychainValue = try? SecretStore.get(service: keychainService, account: kAccount)
                let configValue: String? = (p.name == "anthropic") ? cfg.anthropicAPIKey
                                         : (p.name == "deepseek")  ? cfg.deepseekAPIKey
                                         : nil
                let accountLabel = active.map { " account=\($0)" } ?? ""
                let source: String
                let masked: String
                if let v = envValue, !v.isEmpty {
                    source = "env"; masked = maskKey(v)
                } else if let v = keychainValue, !v.isEmpty {
                    source = "keychain"; masked = maskKey(v)
                } else if let v = configValue, !v.isEmpty {
                    source = "config"; masked = maskKey(v)
                } else {
                    Swift.print("  \(p.name.padding(toLength: 12, withPad: " ", startingAt: 0))  ✗ not configured\(accountLabel)")
                    continue
                }
                Swift.print("  \(p.name.padding(toLength: 12, withPad: " ", startingAt: 0))  ✓ \(masked)  [\(source)]\(accountLabel)")
            }
        }
    }
}

    // MARK: - list

    struct ListAccounts: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List all stored accounts per provider, with the active selection marked."
        )

        @Flag(name: .long, help: "Emit machine-readable JSON instead of the human table.")
        var json: Bool = false

        func run() throws {
            let cfg = ConfigStore.load()
            let known = cfg.accounts ?? [:]
            if json {
                var out: [String: Any] = [:]
                for p in knownProviders.map(\.name) {
                    guard let names = known[p], !names.isEmpty else { continue }
                    out[p] = [
                        "accounts": names,
                        "active": cfg.activeAccountName(for: p) as Any? as Any
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                return
            }
            if known.isEmpty {
                Swift.print("No labelled accounts. (`lingcode auth login --account <name>` to add one.)")
                return
            }
            for p in knownProviders.map(\.name) {
                guard let names = known[p], !names.isEmpty else { continue }
                let active = cfg.activeAccountName(for: p)
                Swift.print("  \(p):")
                for name in names {
                    let marker = (name == active) ? "* " : "  "
                    Swift.print("    \(marker)\(name)")
                }
            }
            Swift.print("\n* = active. `lingcode auth use <provider> --account <name>` to switch.")
        }
    }

    // MARK: - use

    struct UseAccount: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "use",
            abstract: "Switch which account a provider uses by default in subsequent runs."
        )

        @Argument(help: "Provider name (run `lingcode auth list` to see configured accounts).")
        var provider: String

        @Option(name: .long, help: "Account label to make active. Omit to clear (revert to default slot).")
        var account: String?

        func run() throws {
            _ = try accountFor(provider) // validate provider name
            var cfg = ConfigStore.load()
            var map = cfg.activeAccount ?? [:]
            if let name = account, !name.isEmpty {
                let known = cfg.accounts?[provider.lowercased()] ?? []
                guard known.contains(name) else {
                    let knownStr = known.isEmpty ? "(none)" : known.joined(separator: ", ")
                    FileHandle.standardError.write(Data("lingcode: account '\(name)' is not registered for \(provider). Known: \(knownStr)\n".utf8))
                    throw ExitCode(2)
                }
                map[provider.lowercased()] = name
                Swift.print("✓ active \(provider) account → \(name)")
            } else {
                map.removeValue(forKey: provider.lowercased())
                Swift.print("✓ \(provider) reverted to default slot")
            }
            cfg.activeAccount = map
            try ConfigStore.save(cfg)
        }
    }

// MARK: - Helpers

/// Adds `account` to the per-provider list in config.json so `auth list`/`auth use`
/// can enumerate stored accounts. nil/empty = default slot, no-op.
private func registerAccount(provider: String, account: String?) throws {
    guard let name = account?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
    var cfg = ConfigStore.load()
    var map = cfg.accounts ?? [:]
    var list = map[provider.lowercased()] ?? []
    if !list.contains(name) { list.append(name) }
    map[provider.lowercased()] = list
    cfg.accounts = map
    try ConfigStore.save(cfg)
}

/// Inverse of `registerAccount`. Clears the active selection if it pointed here.
private func unregisterAccount(provider: String, account: String?) throws {
    guard let name = account?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
    var cfg = ConfigStore.load()
    var map = cfg.accounts ?? [:]
    var list = map[provider.lowercased()] ?? []
    list.removeAll { $0 == name }
    if list.isEmpty {
        map.removeValue(forKey: provider.lowercased())
    } else {
        map[provider.lowercased()] = list
    }
    cfg.accounts = map
    var active = cfg.activeAccount ?? [:]
    if active[provider.lowercased()] == name { active.removeValue(forKey: provider.lowercased()) }
    cfg.activeAccount = active
    try ConfigStore.save(cfg)
}

private func accountFor(_ provider: String) throws -> String {
    if let p = providerByName(provider) { return p.account }
    let known = knownProviders.map(\.name).joined(separator: ", ")
    FileHandle.standardError.write(Data("lingcode: unknown provider '\(provider)'. Known: \(known)\n".utf8))
    throw ExitCode(2)
}

private func maskKey(_ key: String) -> String {
    guard key.count > 8 else { return "****" }
    return String(key.prefix(8)) + String(repeating: "*", count: min(key.count - 8, 20))
}
