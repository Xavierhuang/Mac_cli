// CryptoKit is Apple-only and the account token lives in the macOS Keychain that
// LingCode.app writes, so the whole file is gated. On Linux there is no signed-in
// Mac app to inherit a session from, and `lingcode` there simply has no cloud MCP —
// the same posture AuthMigrate takes for its AES-GCM round-trip.
#if canImport(CryptoKit)
import CryptoKit
import Foundation
import LingCodeAgentCore

/// Registers the `lingcode-cloud` MCP server for the standalone CLI, so
/// `lingcode ask` / `lingcode repl` reach the same account tools — and the same
/// local `deploy_app` — that the Mac app's agent tabs get.
///
/// The Mac app writes this server into a workspace `.mcp.json` via
/// `LingCodeCloudMCPSetup.connect`, pointing at the proxy inside LingCode.app. That
/// only helps a machine with the app installed, and only for folders the user has
/// explicitly connected. This resolves the CLI's OWN bundled proxy instead, so the
/// standalone binary works on its own.
///
/// Mirrors `LingCodeCloudMCPSetup` (Mac). Keep the env keys and the project-key
/// hash in step with it — a different key means a different backend for the same
/// folder, which looks like data loss to the user.
enum CloudMCP {
    static let serverName = "lingcode-cloud"
    static let accountMcpURL = "https://lingcode.dev/api/cloud/account/mcp"

    /// Keychain coordinates of the account session written by LingCode.app.
    /// Reading it from a differently-signed binary prompts once per session; that
    /// is expected and is why this is resolved lazily, at MCP bootstrap, rather
    /// than on every command.
    private static let keychainService = "LingCode"
    private static let keychainAccount = "lingcode_auth_access_token"

    /// Stable per-workspace project key. MUST match
    /// `LingCodeCloudMCPSetup.projectKey(for:)` — SHA-256 of the standardized path,
    /// first 20 hex chars, `proj_` prefixed.
    static func projectKey(for workspace: URL) -> String {
        let path = workspace.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "proj_" + String(hex.prefix(20))
    }

    /// Canonical project id from `<workspace>/.lingcode/project.json`, when the
    /// folder carries one — that is what resolves a SHARED backend by membership.
    static func projectId(for workspace: URL) -> String? {
        let url = workspace.appendingPathComponent(".lingcode/project.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = json["projectId"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    /// The bundled stdio proxy, resolved from the CLI's own resources (falling back
    /// to an installed LingCode.app via the shared locator). nil when neither is
    /// present — an older CLI tarball predating the proxy, for instance.
    static func proxyScriptPath() -> String? {
        var roots: [String] = []
        if let bundled = try? CLIResources.bundleURL().appendingPathComponent("agent-bridge").path {
            roots.append(bundled)
        }
        // `bridgeScriptPath` is bridge.mjs; the proxy is its sibling.
        if let located = try? BridgeResourceLocator(extraSearchRoots: roots).locate() {
            roots.insert((located.bridgeScriptPath as NSString).deletingLastPathComponent, at: 0)
        }
        for root in roots {
            let candidate = (root as NSString).appendingPathComponent("lingcode-cloud-mcp.mjs")
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The `lingcode-cloud` server to merge into the MCP set for `cwd`, or nil when
    /// signed out / the proxy or Node is missing. Never throws: a CLI run must not
    /// fail because the cloud session is absent.
    static func serverConfig(for cwd: URL) -> MCPServerConfig? {
        guard let token = try? SecretStore.get(service: keychainService, account: keychainAccount),
              !token.isEmpty,
              let script = proxyScriptPath(),
              let node = NodeResolver.resolve(extraSearchPaths: [(script as NSString).deletingLastPathComponent])
        else { return nil }

        var env: [String: String] = [
            "LINGCODE_MCP_URL": accountMcpURL,
            "LINGCODE_TOKEN": token,
            "LINGCODE_PROJECT": projectKey(for: cwd),
            // The local deploy tools read the build output off disk, and the proxy
            // is spawned without a guaranteed cwd.
            "LINGCODE_WORKSPACE": cwd.standardizedFileURL.path,
        ]
        if let pid = projectId(for: cwd) { env["LINGCODE_PROJECT_ID"] = pid }
        return MCPServerConfig(type: "stdio", command: node, args: [script], env: env)
    }

    /// Server map to hand `MCPManager.bootstrap(extraServers:)`. Empty when signed
    /// out, so the caller needs no branch.
    static func extraServers(for cwd: URL) -> [String: MCPServerConfig] {
        guard let cfg = serverConfig(for: cwd) else { return [:] }
        return [serverName: cfg]
    }
}
#endif

import Foundation
import LingCodeAgentCore

/// Platform-independent entry point for the MCP bootstrap call sites, so they don't
/// each have to carry the CryptoKit gate. Empty on non-Apple platforms and whenever
/// the user isn't signed in.
func cloudMCPServers(for cwd: URL) -> [String: MCPServerConfig] {
    #if canImport(CryptoKit)
    return CloudMCP.extraServers(for: cwd)
    #else
    return [:]
    #endif
}

/// Merge the cloud server into a set already loaded from disk, on-disk winning.
///
/// For the Claude provider and `lingcode doctor` there is no `MCPManager` to hand
/// `extraServers` to — those paths call `MCPConfig.load` directly and pass the result
/// straight to the bridge. Claude is the DEFAULT provider, so without this `lingcode
/// ask` would be the one surface that never sees the cloud tools.
func mergingCloudMCP(_ onDisk: [String: MCPServerConfig], cwd: URL) -> [String: MCPServerConfig] {
    var merged = onDisk
    merged.merge(cloudMCPServers(for: cwd)) { fromDisk, _ in fromDisk }
    return merged
}
