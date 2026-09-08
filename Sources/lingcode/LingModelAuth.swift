import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingCodeAgentCore

/// Shared LingModel credential handling for the CLI.
///
/// Exists because three surfaces need the same two answers — where does the
/// token come from, and is it still alive — and were drifting: `doctor`, the
/// REPL's startup preflight, and `/login`. The resolution order in particular
/// has to match `Repl`/`HeadlessClaude` exactly, or we verify one credential
/// and then send a different one.
enum LingModelAuth {
    /// Anthropic-shape inference base. Also handed to the bridge as
    /// `LINGCODE_PROXY_BASE_URL`, which is what lets `applyProviderEnv`
    /// hot-swap the token on a live session instead of requiring a restart.
    static let inferenceBaseURL = "https://lingcode.dev/api/inference/anthropic"

    /// Cheap authenticated GET used for verification. See `probe(token:timeout:)`.
    static let entitlementURL = "https://lingcode.dev/api/entitlement"

    static let mintURL = "https://lingcode.dev/cli-token.html"

    /// The tag the bridge resolves to when the REPL carries no explicit model
    /// (mirrors `ANTHROPIC_DEFAULT_SONNET_MODEL` in the LingModel bridge env).
    ///
    /// A live re-auth has to name a model — the bridge's `set_model` requires one,
    /// and `applyProviderEnv` only swaps the token for tags `isLingModelTag()`
    /// accepts. Without this fallback a re-auth on a session that never set a model
    /// silently does nothing.
    static let defaultModelTag = "lingmodel-standard"

    /// Keychain slot for `account` (nil → the legacy un-suffixed key).
    static func keychainSlot(account: String?) -> String {
        keychainAccount(base: "lingmodel-cli-token", account: account)
    }

    /// Env override first (`LINGCODE_CLI_TOKEN`), then keychain — the same order
    /// the REPL and headless paths resolve in, so what we verify is what gets sent.
    static func resolveToken(account: String?) -> (token: String, source: String)? {
        let env = ProcessInfo.processInfo.environment["LINGCODE_CLI_TOKEN"]?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !env.isEmpty { return (env, "env") }
        let kc = (try? SecretStore.get(service: keychainService, account: keychainSlot(account: account))) ?? ""
        return kc.isEmpty ? nil : (kc, "keychain")
    }

    static func save(token: String, account: String?) throws {
        try SecretStore.set(service: keychainService, account: keychainSlot(account: account), secret: token)
    }

    static func delete(account: String?) throws {
        try SecretStore.delete(service: keychainService, account: keychainSlot(account: account))
    }

    enum ProbeResult {
        /// Server resolved the token to a live account. `tier` as reported.
        case valid(tier: String?)
        /// Authenticated fine; just over a quota window right now.
        case rateLimited
        /// 401/403 — the server found no live row for this token.
        case rejected
        /// Network failure or server-side 5xx. Says nothing about the token, so
        /// callers must not render it as a failure — that blames the credential
        /// for someone's flaky wifi.
        case unreachable
    }

    /// Verifies a token against `GET /api/entitlement`.
    ///
    /// Deliberately NOT `/v1/messages`: that route runs real inference upstream
    /// and charges the caller's daily prompt cap, so probing it would cost the
    /// user quota on every `doctor` run and every REPL launch. `/api/entitlement`
    /// authenticates through the identical `getUserFromRequest` → `resolveToken`
    /// path and returns tier/quota state without touching the model, so a pass
    /// here is a pass there.
    ///
    /// Synchronous over a dispatch group — no caller is on a hot path.
    static func probe(token: String, timeout: TimeInterval = 4.0) -> ProbeResult {
        guard let url = URL(string: entitlementURL) else { return .unreachable }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let group = DispatchGroup()
        group.enter()
        var result: ProbeResult = .unreachable
        URLSession.shared.dataTask(with: req) { data, response, error in
            defer { group.leave() }
            if error != nil { return }
            guard let http = response as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 200:
                let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                result = .valid(tier: obj?["tier"] as? String)
            case 401, 403:
                result = .rejected
            case 429:
                result = .rateLimited
            default:
                result = .unreachable
            }
        }.resume()
        _ = group.wait(timeout: .now() + timeout + 1)
        return result
    }

    /// One-line recovery instruction. Single source so `doctor`, the preflight
    /// and the 401 path can't drift into telling users three different things.
    static var remintHint: String {
        "mint one at \(mintURL), then `/login` here (or `lingcode auth login --provider lingmodel`)"
    }
}
