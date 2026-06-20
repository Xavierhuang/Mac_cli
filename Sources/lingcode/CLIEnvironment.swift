import Foundation
import LingCodeAgentCore

/// Process-wide CLI flags that cross-cut subcommands.
///
/// Set early in a subcommand's `run()` from parsed flags, or via env vars:
///   - `NO_COLOR` (no-color.org)        → disables color (handled in `ANSI`)
///   - `LINGCODE_QUIET=1`                → suppresses spinners, banners, summaries
enum CLIEnvironment {
    /// True when the user passed `--quiet` or set `LINGCODE_QUIET=1`. Read by spinner,
    /// welcome banner, and post-turn token summary code paths.
    static var quiet: Bool = {
        if let q = ProcessInfo.processInfo.environment["LINGCODE_QUIET"],
           !q.isEmpty, q != "0" {
            return true
        }
        return false
    }()

    /// Account label override from `--account <name>`, also honored from
    /// `LINGCODE_ACCOUNT`. Read by every keychain lookup site to pick a labelled
    /// API key (e.g. `anthropic-api-key:work`) instead of the default slot.
    /// `nil` falls back to `ConfigStore.activeAccountName(for:)`, then default slot.
    static var account: String? = {
        let env = ProcessInfo.processInfo.environment["LINGCODE_ACCOUNT"]?
            .trimmingCharacters(in: .whitespaces)
        return (env?.isEmpty == false) ? env : nil
    }()

    /// Apply `--no-color` / `--quiet` / `--account` flags from a subcommand.
    /// Idempotent; flags only set values when explicitly provided. Also propagates
    /// the account scope into `SessionStore` and `SessionHistory` so multi-account
    /// users get separate per-account session pointers and history files.
    static func apply(noColor: Bool = false, quiet: Bool = false, account: String? = nil) {
        if noColor { ANSI.override = false }
        if quiet { Self.quiet = true }
        if let a = account?.trimmingCharacters(in: .whitespaces), !a.isEmpty {
            Self.account = a
        }
        // Propagate the resolved scope (flag/env > config active > nil) into
        // the per-process session/history namespaces.
        let scope = Self.account ?? ConfigStore.load().activeAccountName(for: "anthropic")
        SessionStore.accountScope = scope
        SessionHistory.accountScope = scope
    }

    /// Resolves the effective account name for `provider` using:
    ///   1. CLI flag / env override (`--account` / `LINGCODE_ACCOUNT`)
    ///   2. Persisted active account from `lingcode auth use`
    ///   3. nil → keychain reads use the legacy un-suffixed key
    static func resolvedAccount(forProvider provider: String) -> String? {
        if let a = account, !a.isEmpty { return a }
        return ConfigStore.load().activeAccountName(for: provider)
    }
}
