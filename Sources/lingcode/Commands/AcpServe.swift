import ArgumentParser
import Foundation
import LingCodeAgentCore
import LingCodeACP

/// `lingcode acp-serve` — expose a LingCode agent as an ACP server over
/// stdin/stdout. External ACP clients (Zed, gemini-cli, custom tooling)
/// can drive any of LingCode's three agent loops using the standard
/// JSON-RPC 2.0 / newline-delimited wire format.
///
/// Example Zed config:
/// ```jsonc
/// "agent_servers": {
///   "lingcode-claude":  { "command": "lingcode", "args": ["acp-serve"] },
///   "lingcode-deepseek":{ "command": "lingcode", "args": ["acp-serve", "--agent", "deepseek"] }
/// }
/// ```
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct AcpServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acp-serve",
        abstract: "Serve a LingCode agent over ACP (Agent Client Protocol) on stdin/stdout."
    )

    @Option(name: .long, help: "Agent to serve. One of: claude, deepseek, openai-compat:<provider>. Default: claude.")
    var agent: String = "claude"

    @Option(name: .long, help: "Working directory. Defaults to the current directory.")
    var cwd: String?

    mutating func run() async throws {
        let workingDirectory: URL
        if let cwdStr = cwd, !cwdStr.isEmpty {
            workingDirectory = URL(fileURLWithPath: (cwdStr as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        }

        let server: any ACPAgentServer = try buildServer(agentID: agent.lowercased(), cwd: workingDirectory)
        let host = StdioServerHost(
            server: server,
            logger: { msg in
                FileHandle.standardError.write(Data((msg + "\n").utf8))
            }
        )
        await host.runUntilClosed()
    }

    // MARK: - Server factory

    private func buildServer(agentID: String, cwd: URL) throws -> any ACPAgentServer {
        switch agentID {
        case "claude", "claude-bridge":
            return try buildClaudeServer(agentID: "claude-bridge", displayName: "LingCode", useLingModel: false, useDeepSeekDirect: false)
        case "lingmodel":
            return try buildClaudeServer(agentID: "lingmodel", displayName: "LingCode", useLingModel: true, useDeepSeekDirect: false)
        case "deepseek-direct":
            return try buildClaudeServer(agentID: "deepseek-direct", displayName: "LingCode", useLingModel: false, useDeepSeekDirect: true)
        case "deepseek":
            return try buildDeepSeekServer()
        default:
            // openai-compat:<provider> or a bare provider name
            let providerName: String
            if agentID.hasPrefix("openai-compat:") {
                providerName = String(agentID.dropFirst("openai-compat:".count))
            } else {
                providerName = agentID
            }
            return try buildOpenAICompatServer(providerName: providerName)
        }
    }

    // MARK: - Claude (bridge) server

    private func buildClaudeServer(
        agentID: String,
        displayName: String,
        useLingModel: Bool,
        useDeepSeekDirect: Bool
    ) throws -> any ACPAgentServer {
        let extraNodePaths = [CLIResources.bundledNodePath()].compactMap { $0 }
        guard let nodePath = NodeResolver.resolve(extraSearchPaths: extraNodePaths) else {
            throw ExitCode(1)
        }
        let resources: BridgeResources
        do {
            let bundledRoot = try CLIResources.bundleURL()
            resources = try BridgeResourceLocator(extraSearchRoots: [bundledRoot.path]).locate()
        } catch {
            stderr("lingcode: bridge resources unavailable: \(error)")
            throw ExitCode(1)
        }

        let anthropicKey: String? = resolveClaudeKey(useLingModel: useLingModel, useDeepSeekDirect: useDeepSeekDirect)
        guard let apiKey = anthropicKey, !apiKey.isEmpty else {
            let hint = useLingModel
                ? "Run: lingcode auth login --provider lingmodel"
                : "Run: export ANTHROPIC_API_KEY=sk-ant-..."
            stderr("lingcode acp-serve: API key not set. \(hint)")
            throw ExitCode(1)
        }

        var extraEnv: [String: String] = [:]
        if useLingModel {
            extraEnv["ANTHROPIC_BASE_URL"] = "https://lingcode.dev/api/inference/anthropic"
        } else if useDeepSeekDirect {
            extraEnv["ANTHROPIC_BASE_URL"] = "https://api.deepseek.com/anthropic"
            extraEnv["ANTHROPIC_AUTH_TOKEN"] = apiKey
        }

        let template = AgentBridgeConfiguration.Template(
            nodePath: nodePath,
            resources: resources,
            permissionMode: .default,
            anthropicAPIKey: apiKey,
            extraEnvironment: extraEnv,
            bridgeSocketPath: nil
        )
        return ClaudeBridgeAgentServer(
            agentID: ACPAgentID(agentID),
            displayName: displayName,
            configTemplate: template
        )
    }

    // MARK: - DeepSeek server

    private func buildDeepSeekServer() throws -> any ACPAgentServer {
        // DeepSeek's API is OpenAI-shaped, so it runs on the unified OpenAI-compat
        // ACP server now — the dedicated DeepSeekAgentServer/DeepSeekAgentLoop are
        // retired. Same base URL / key / default model via the deepseek-compat preset.
        return try buildOpenAICompatServer(providerName: "deepseek-compat")
    }

    // MARK: - OpenAI-compat server

    private func buildOpenAICompatServer(providerName: String) throws -> any ACPAgentServer {
        let preset = OpenAICompatProvider(rawValue: providerName.lowercased())
        guard let baseURL = preset?.baseURL else {
            stderr("lingcode acp-serve: unknown provider '\(providerName)'. Use openai-compat:<provider> with a known preset.")
            throw ExitCode(1)
        }
        let baseAccount: String? = {
            switch preset {
            case .openai:         return "openai-api-key"
            case .groq:           return "groq-api-key"
            case .together:       return "together-api-key"
            case .openrouter:     return "openrouter-api-key"
            case .mistral:        return "mistral-api-key"
            case .xai:            return "xai-api-key"
            case .fireworks:      return "fireworks-api-key"
            case .deepseekCompat: return "deepseek-api-key"
            case .gemini:         return "gemini-api-key"
            case .kimi:           return "kimi-api-key"
            case .qwen:           return "qwen-api-key"
            case .zai, .zaiCoding: return "z-ai-api-key"
            case .ollama, .none:  return nil
            }
        }()
        let envVar = preset?.envVar ?? "\(providerName.uppercased().replacingOccurrences(of: "-", with: "_"))_API_KEY"
        let apiKey: String = {
            if let env = ProcessInfo.processInfo.environment[envVar], !env.isEmpty { return env }
            if let base = baseAccount {
                let kAccount = keychainAccount(
                    base: base,
                    account: CLIEnvironment.resolvedAccount(forProvider: providerName)
                )
                if let kc = try? SecretStore.get(service: keychainService, account: kAccount), !kc.isEmpty { return kc }
            }
            return ""
        }()
        if apiKey.isEmpty && preset != .ollama {
            stderr("lingcode acp-serve: \(envVar) is not set.")
            throw ExitCode(1)
        }
        let model = preset?.defaultModel ?? "gpt-5.6-sol"
        let client = OpenAICompatClient(apiKey: apiKey, baseURL: baseURL)
        return OpenAICompatAgentServer(
            agentID: ACPAgentID("openai-compat:\(providerName)"),
            displayName: "LingCode (\(providerName))",
            client: client,
            model: model
        )
    }

    // MARK: - Credential helpers

    private func resolveClaudeKey(useLingModel: Bool, useDeepSeekDirect: Bool) -> String? {
        if useLingModel {
            if let env = ProcessInfo.processInfo.environment["LINGCODE_CLI_TOKEN"], !env.isEmpty { return env }
            let kAccount = keychainAccount(base: "lingmodel-cli-token",
                                           account: CLIEnvironment.resolvedAccount(forProvider: "lingmodel"))
            return try? SecretStore.get(service: keychainService, account: kAccount)
        }
        if useDeepSeekDirect {
            if let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !env.isEmpty { return env }
            let kAccount = keychainAccount(base: "deepseek-api-key",
                                           account: CLIEnvironment.resolvedAccount(forProvider: "deepseek"))
            if let kc = try? SecretStore.get(service: keychainService, account: kAccount), !kc.isEmpty { return kc }
            return ConfigStore.load().deepseekAPIKey
        }
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        let kAccount = keychainAccount(base: "anthropic-api-key",
                                       account: CLIEnvironment.resolvedAccount(forProvider: "anthropic"))
        if let kc = try? SecretStore.get(service: keychainService, account: kAccount), !kc.isEmpty { return kc }
        return ConfigStore.load().anthropicAPIKey
    }

    private func stderr(_ msg: String) {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
    }
}
