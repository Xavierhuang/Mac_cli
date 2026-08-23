import Foundation
import LingCodeAgentCore

enum HeadlessOpenAICompatExit: Error {
    case missingAPIKey(String)
    case upstream(String)
}

/// Streams a chat completion through any OpenAI-compatible endpoint.
/// Text-only by default; pass `yolo: true` to enable the Swift-native tool harness
/// (Read/Write/Bash/Grep) with an agent loop.
func runHeadlessOpenAICompat(
    prompt: String,
    project: String?,
    providerName: String,
    model: String?,
    baseURLOverride: String?,
    apiKeyEnvOverride: String?,
    includeClaudeMd: Bool,
    includeSkills: Bool = true,
    imagePaths: [String] = [],
    yolo: Bool = false,
    permissionMode: String? = nil,
    maxTurns: Int = 20,
    verbose: Bool = false,
    outputFile: String? = nil,
    allowedTools: [String] = [],
    disallowedTools: [String] = [],
    mcpEnabled: Bool = true,
    mcpConfigPath: String? = nil,
    timeoutFlag: Int? = nil,
    // Pre-existing conversation, looked up via OpenAICompatSessionStore.
    // Only consumed in the agent path — text-only mode discards them with
    // a warning, since the chat completions endpoint isn't worth the overhead
    // for plain Q&A.
    priorMessages: [OpenAICompatClient.Message] = [],
    sessionId: String? = nil
) async throws {
    let isAzure = providerName.lowercased() == "azure"

    // Preset lookup (e.g. "openai", "groq") falls back to custom + env override.
    let preset = OpenAICompatProvider(rawValue: providerName.lowercased())

    // Azure: read AZURE_OPENAI_ENDPOINT + AZURE_OPENAI_DEPLOYMENT, or let --base-url override.
    let azureApiVersion = ProcessInfo.processInfo.environment["AZURE_OPENAI_API_VERSION"] ?? "2024-06-01"
    let baseURL: URL = {
        if let override = baseURLOverride, let u = URL(string: override) { return u }
        if isAzure {
            let endpoint = ProcessInfo.processInfo.environment["AZURE_OPENAI_ENDPOINT"] ?? ""
            let deployment = ProcessInfo.processInfo.environment["AZURE_OPENAI_DEPLOYMENT"] ?? ""
            if endpoint.isEmpty || deployment.isEmpty {
                return URL(string: "https://invalid.local")!
            }
            let stripped = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
            return URL(string: "\(stripped)/openai/deployments/\(deployment)")!
        }
        if let preset { return preset.baseURL }
        return URL(string: "https://invalid.local")!
    }()
    if baseURL.host == "invalid.local" {
        let hint = isAzure
            ? "set AZURE_OPENAI_ENDPOINT + AZURE_OPENAI_DEPLOYMENT, or pass --base-url https://<resource>.openai.azure.com/openai/deployments/<deployment>"
            : "provider '\(providerName)' is not a known preset. Pass --base-url explicitly."
        FileHandle.standardError.write(Data("lingcode: \(hint)\n".utf8))
        throw HeadlessOpenAICompatExit.missingAPIKey("base-url")
    }

    let envVar = apiKeyEnvOverride ?? (isAzure ? "AZURE_OPENAI_API_KEY" : (preset?.envVar ?? "OPENAI_API_KEY"))
    let rawKey: String = {
        let env = ProcessInfo.processInfo.environment[envVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty { return env }
        // Keychain fallback for providers whose keys can be stored via
        // `lingcode auth login` / `auth set`. Account names mirror
        // Auth.swift's `knownProviders` so a key saved via the picker is
        // immediately reachable here. Ollama is keyless by convention;
        // .none means the user passed --base-url with no preset, in which
        // case --api-key-env is the only way to provide a key.
        let keychainAccount: String? = {
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
        if let baseAccount = keychainAccount {
            let kAccount = LingCodeAgentCore.keychainAccount(base: baseAccount, account: CLIEnvironment.resolvedAccount(forProvider: providerName))
            if let kc = try? SecretStore.get(service: keychainService, account: kAccount),
               !kc.isEmpty {
                return kc
            }
        }
        return ""
    }()
    // Ollama commonly runs keyless; allow empty key only for ollama preset.
    if rawKey.isEmpty && preset != .ollama {
        FileHandle.standardError.write(Data("""
            lingcode: \(envVar) is not set.

            Set it in your shell:
              export \(envVar)=<your-key>

            Or for generic providers use --api-key-env MY_KEY_VAR.

            """.utf8))
        throw HeadlessOpenAICompatExit.missingAPIKey(envVar)
    }

    let cwd: URL
    if let project, !project.isEmpty {
        cwd = URL(fileURLWithPath: (project as NSString).expandingTildeInPath)
    } else {
        cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    // Azure's "model" in the request body is ignored — the deployment is in the URL — but OpenAI SDKs
    // still expect the field to be present, so pass a harmless placeholder if the user didn't specify.
    let resolvedModel = model ?? (isAzure ? "deployment" : (preset?.defaultModel ?? "gpt-4o-mini"))
    let authStyle: OpenAICompatClient.AuthStyle = isAzure
        ? .azureKey(apiVersion: azureApiVersion)
        : .bearer
    let timeoutSeconds = OpenAICompatClient.resolveTimeoutSeconds(flag: timeoutFlag)
    let urlSession = OpenAICompatClient.makeURLSession(timeoutSeconds: timeoutSeconds)
    let client = OpenAICompatClient(apiKey: rawKey, baseURL: baseURL, authStyle: authStyle, urlSession: urlSession)
    if verbose {
        FileHandle.standardError.write(Data(
            "lingcode: http idle timeout = \(Int(timeoutSeconds))s\n".utf8
        ))
    }

    // Build system + user messages. CLAUDE.md + skills (if requested) fold into the
    // user prompt the same way `runHeadlessAsk` does, keeping behavior consistent across providers.
    let claudeMd = includeClaudeMd ? ProjectContext.loadClaudeMd(startingAt: cwd) : nil
    let skills = includeSkills ? SkillsContext.loadSkills(cwd: cwd) : []
    let userPrompt = SkillsContext.wrap(
        prompt: ProjectContext.wrap(prompt: prompt, claudeMd: claudeMd),
        skills: skills
    )

    // Resolve --image attachments up front. On failure we emit a clear error
    // and bail rather than silently dropping the image — users expect their
    // attachment to actually reach the model.
    var imageDataURLs: [String] = []
    for path in imagePaths {
        do {
            imageDataURLs.append(try ImageAttachment.dataURL(forPath: path, cwd: cwd))
        } catch {
            FileHandle.standardError.write(Data("lingcode: \(error)\n".utf8))
            throw HeadlessOpenAICompatExit.upstream(String(describing: error))
        }
    }

    let resolved = PermissionResolver.resolve(yolo: yolo, permissionMode: permissionMode, settingsCwd: cwd)

    let resolvedSessionId = sessionId ?? OpenAICompatSessionStore.newSessionId()
    var responseText = ""
    do {
        if resolved.useAgentLoop {
            try await runOpenAICompatAgentic(
                client: client,
                model: resolvedModel,
                prompt: userPrompt,
                cwd: cwd,
                decider: resolved.decider,
                maxTurns: maxTurns,
                verbose: verbose,
                allowedTools: allowedTools,
                disallowedTools: disallowedTools,
                mcpEnabled: mcpEnabled,
                mcpConfigPath: mcpConfigPath,
                images: imageDataURLs,
                priorMessages: priorMessages,
                providerName: providerName,
                sessionId: resolvedSessionId,
                accumulatedText: &responseText
            )
        } else {
            if !priorMessages.isEmpty {
                FileHandle.standardError.write(Data(
                    "lingcode: --continue/--resume only persists in agent mode (--yolo or --permission-mode acceptEdits/plan); starting fresh.\n".utf8
                ))
            }
            try await runOpenAICompatTextOnly(
                client: client,
                model: resolvedModel,
                prompt: userPrompt,
                images: imageDataURLs,
                accumulatedText: &responseText,
                providerName: providerName
            )
        }
    } catch {
        FileHandle.standardError.write(Data("lingcode: \(error.localizedDescription)\n".utf8))
        throw HeadlessOpenAICompatExit.upstream(error.localizedDescription)
    }

    if let path = outputFile {
        let outURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? responseText.write(to: outURL, atomically: true, encoding: .utf8)
    }
}

private func runOpenAICompatTextOnly(
    client: OpenAICompatClient,
    model: String,
    prompt: String,
    images: [String] = [],
    accumulatedText: inout String,
    providerName: String = ""
) async throws {
    let systemPrompt = "You are a coding assistant running in a terminal. Answer concisely. You cannot edit files in this mode — describe changes the user should apply manually."
    let request = OpenAICompatClient.Request(
        model: model,
        messages: [
            .init(role: "system", content: systemPrompt),
            .init(role: "user", content: prompt, images: images.isEmpty ? nil : images),
        ]
    )
    var sawContent = false
    var usageInput = 0
    var usageOutput = 0
    for try await piece in client.stream(request) {
        switch piece {
        case .content(let text):
            sawContent = true
            accumulatedText += text
            FileHandle.standardOutput.write(Data(text.utf8))
        case .reasoning:
            // CoT trace; headless one-shot doesn't render it.
            continue
        case .toolCall:
            continue
        case .usage(let p, let c, _, _):
            usageInput = p
            usageOutput = c
        case .done:
            if sawContent { FileHandle.standardOutput.write(Data("\n".utf8)) }
            if !CLIEnvironment.quiet, (usageInput + usageOutput) > 0, isatty(fileno(stderr)) != 0 {
                let nf = NumberFormatter(); nf.numberStyle = .decimal
                let inStr  = nf.string(from: NSNumber(value: usageInput))  ?? "\(usageInput)"
                let outStr = nf.string(from: NSNumber(value: usageOutput)) ?? "\(usageOutput)"
                let costSuffix: String = {
                    if let cost = CostEstimator.estimate(provider: providerName, model: model, inputTokens: usageInput, outputTokens: usageOutput) {
                        return "  ~\(CostEstimator.format(cost))"
                    }
                    return ""
                }()
                FileHandle.standardError.write(Data("↑ \(inStr) ↓ \(outStr) tokens\(costSuffix)\n".utf8))
            }
        }
    }
}

private func runOpenAICompatAgentic(
    client: OpenAICompatClient,
    model: String,
    prompt: String,
    cwd: URL,
    decider: any PermissionDecider,
    maxTurns: Int,
    verbose: Bool,
    allowedTools: [String],
    disallowedTools: [String],
    mcpEnabled: Bool,
    mcpConfigPath: String?,
    images: [String] = [],
    priorMessages: [OpenAICompatClient.Message] = [],
    providerName: String = "",
    sessionId: String = "",
    accumulatedText: inout String
) async throws {
    // Images are attached to the first user turn. The model must support
    // vision (e.g. kimi-k2.6 / kimi-k2.5 or moonshot-v1-*-vision-preview for Kimi; gpt-4o for OpenAI;
    // gemini-1.5-* for Gemini) — text-only models will 400 from upstream,
    // which we surface as-is rather than guessing the model's capabilities.
    let builtins = BuiltinTools.filtered(
        BuiltinTools.defaultRegistry(),
        allowed: allowedTools,
        disallowed: disallowedTools
    )

    var mcpManager: MCPManager? = nil
    var mcpExecutors: [any ToolExecutor] = []
    if mcpEnabled {
        let (mgr, result) = await MCPManager.bootstrap(cwd: cwd, overridePath: mcpConfigPath,
                                                       extraServers: cloudMCPServers(for: cwd))
        mcpManager = mgr
        mcpExecutors = result.executors
        for status in result.statuses {
            switch status.state {
            case .failed(let reason):
                FileHandle.standardError.write(Data("lingcode: MCP server '\(status.name)' failed: \(reason)\n".utf8))
            case .skipped(let reason):
                if verbose {
                    FileHandle.standardError.write(Data("lingcode: MCP server '\(status.name)' skipped — \(reason)\n".utf8))
                }
            case .connected, .terminated:
                break
            }
        }
    }
    defer {
        if let mgr = mcpManager {
            Task { await mgr.shutdownAll() }
        }
    }

    let baseRegistry: ToolRegistry = mcpExecutors.isEmpty
        ? builtins
        : ToolRegistry(Array(builtins.executors.values) + mcpExecutors)
    // Wire the Task tool so the model can spawn subagents from .claude/agents/.
    let taskTool = TaskTool(
        client: client,
        defaultModel: model,
        decider: decider,
        parentToolRegistry: baseRegistry,
        maxTurns: maxTurns
    )
    let registry = ToolRegistry(Array(baseRegistry.executors.values) + [taskTool])
    let agent = OpenAICompatAgent(client: client)
    let options = OpenAICompatAgentOptions(
        cwd: cwd,
        model: model,
        systemPrompt: OpenAICompatAgentPrompt.systemPrompt(
            cwd: cwd,
            toolNames: registry.specs.map { $0.name }
        ),
        tools: registry,
        decider: decider,
        maxTurns: maxTurns
    )

    // Build the initial message list. If `priorMessages` is non-empty we're
    // resuming: keep the existing system + history and append a new user turn.
    // Otherwise it's a fresh chat with the standard system + user pair.
    let initialMessages: [OpenAICompatClient.Message]
    if !priorMessages.isEmpty {
        var msgs = priorMessages
        msgs.append(.init(role: "user", content: prompt, images: images.isEmpty ? nil : images))
        initialMessages = msgs
    } else {
        initialMessages = [
            .init(role: "system", content: options.systemPrompt),
            .init(role: "user", content: prompt, images: images.isEmpty ? nil : images)
        ]
    }

    var sawText = false
    let createdAt = priorMessages.isEmpty ? Date() : (OpenAICompatSessionStore.load(id: sessionId)?.createdAt ?? Date())
    for try await event in agent.runConversation(initial: initialMessages, options: options) {
        switch event {
        case .thinking:
            continue
        case .assistantText(let t):
            sawText = true
            accumulatedText += t
            FileHandle.standardOutput.write(Data(t.utf8))
        case .toolCallRequested(let name, let args, _):
            if verbose {
                FileHandle.standardError.write(Data("\n[tool: \(name) \(args)]\n".utf8))
            } else {
                FileHandle.standardError.write(Data("\n[\(name)]".utf8))
            }
        case .permissionDenied(let name, let reason, _):
            FileHandle.standardError.write(Data("\n[denied \(name): \(reason)]\n".utf8))
        case .toolResult(let name, let content, let isError, _):
            if verbose {
                let label = isError ? "error" : "result"
                FileHandle.standardError.write(Data("\n[\(name) \(label)]\n\(content)\n".utf8))
            } else {
                let marker = isError ? "✗ " : "✓ "
                FileHandle.standardError.write(Data(marker.utf8))
            }
        case .turnComplete:
            continue
        case .conversationSnapshot(let messages):
            // Persist after every turn so a Ctrl-C between turns still leaves
            // a resumable record. `--continue` reads `last-<cwd-hash>` and
            // picks up exactly where this run left off.
            if !sessionId.isEmpty {
                let record = OpenAICompatSessionStore.Record(
                    id: sessionId,
                    cwd: cwd.standardizedFileURL.path,
                    provider: providerName,
                    model: model,
                    createdAt: createdAt,
                    updatedAt: Date(),
                    messages: messages
                )
                OpenAICompatSessionStore.save(record)
            }
            continue
        case .deepseekConversationSnapshot:
            // OpenAI-compat path will never see this, but the switch must be exhaustive.
            continue
        case .done:
            if sawText { FileHandle.standardOutput.write(Data("\n".utf8)) }
        }
    }
}
