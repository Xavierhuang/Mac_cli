import Foundation
#if canImport(Security)
import Security
#endif

/// Detects whether Claude can authenticate from a **subscription** rather than a
/// metered API key.
///
/// LingCode cannot offer a "Sign in with Claude" button — Anthropic does not issue
/// OAuth client IDs to third-party CLIs, which is why `lingcode auth login` asks for
/// an API key. But a Pro or Max subscriber who has already signed into Claude Code
/// has a credential on this machine, and the bundled Agent SDK knows how to use it.
///
/// Before this existed, `lingcode ask --provider claude` exited with
/// "ANTHROPIC_API_KEY is not set" **before ever starting the bridge** — so a
/// subscriber with perfectly good credentials was stopped by a precondition check
/// rather than by an authentication failure, and told to go buy API credits they did
/// not need. The same shape as a doctor that reports a broken install as healthy:
/// the check disagreed with reality.
enum ClaudeSubscriptionAuth {

    enum Source {
        /// `claude setup-token` mints this from a Pro/Max plan for headless use.
        case oauthTokenEnv
        /// Claude Code is signed in on this machine; its credential is in the Keychain.
        case claudeCodeCredentials

        var describedForDoctor: String {
            switch self {
            case .oauthTokenEnv:         return "subscription (CLAUDE_CODE_OAUTH_TOKEN)"
            case .claudeCodeCredentials: return "subscription (signed in to Claude Code)"
            }
        }
    }

    /// The Keychain service Claude Code stores its session under.
    private static let claudeCodeKeychainService = "Claude Code-credentials"

    /// Non-nil when Claude can run without an API key.
    static func detect() -> Source? {
        let env = ProcessInfo.processInfo.environment
        if let token = env["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty {
            return .oauthTokenEnv
        }
        return hasClaudeCodeCredentials() ? .claudeCodeCredentials : nil
    }

    /// Existence probe only — `kSecReturnData: false`.
    ///
    /// Deliberately never reads the secret. macOS prompts on a DATA read of an item
    /// this binary does not own, and the Claude Code credential is owned by a
    /// differently-signed process; reading it would put a password dialog in front of
    /// anyone who merely ran `lingcode doctor`. An attribute-only query answers the
    /// question we actually have — "is there a session here" — and never prompts.
    private static func hasClaudeCodeCredentials() -> Bool {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeKeychainService,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        #else
        return false
        #endif
    }
}
