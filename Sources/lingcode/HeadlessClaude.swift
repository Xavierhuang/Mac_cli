import ArgumentParser
import Foundation
import LingCodeAgentCore

private func headlessEstimateCost(input: Int, output: Int, cache: Int) -> String {
    let cost = Double(input) / 1_000_000 * 3.0
              + Double(output) / 1_000_000 * 15.0
              + Double(cache) / 1_000_000 * 0.30
    if cost < 0.001 { return "<$0.001" }
    return String(format: "$%.3f", cost)
}

/// Returns a one-line "next step" hint for a bridge or network failure. Picks
/// based on substring heuristics — the bridge surfaces freeform messages from
/// the Agent SDK and we try to convert them into something the user can act on
/// (retry, sign in, run doctor, etc.). Never throws; falls back to a generic hint.
func retryHint(for message: String) -> String {
    let lower = message.lowercased()
    if lower.contains("401") || lower.contains("unauthor") || lower.contains("authentication") {
        return "  → check your API key (`lingcode auth status`) or refresh it via `lingcode auth login`."
    }
    if lower.contains("429") || lower.contains("rate") || lower.contains("overload") {
        return "  → rate limited; wait a moment and retry with `lingcode ask --continue \"...\"`."
    }
    if lower.contains("network") || lower.contains("connection") || lower.contains("timeout") || lower.contains("refused") {
        return "  → network error; check connectivity and retry with `lingcode ask --continue \"...\"`."
    }
    if lower.contains("node") || lower.contains("bridge") || lower.contains("sdk-bundle") {
        return "  → bridge issue; run `lingcode doctor` to diagnose, or reinstall lingcode."
    }
    return "  → retry with `lingcode ask --continue \"...\"`. If it persists, run `lingcode doctor`."
}

/// Heuristic match on common rate-limit / overload error messages surfaced by the
/// Anthropic API and the Agent SDK. Matched case-insensitively.
func isRateLimitError(_ message: String) -> Bool {
    let needles = [
        "rate_limit", "rate limit",
        "too many requests", "429",
        "overloaded", "529",
        "temporarily", "retry",
    ]
    let lower = message.lowercased()
    return needles.contains(where: { lower.contains($0) })
}

/// True when the bridge surfaced a transient-looking network or server error
/// that's worth one or two automatic retries before giving up. Different from
/// `isRateLimitError` because the cooldown should be shorter (network blips
/// resolve in seconds, not minutes) and we don't want to trigger on user-error
/// 4xx responses. Used by the headless retry loop to make `lingcode ask`
/// resilient to brief connection drops without users having to retype `--continue`.
func isTransientNetworkError(_ message: String) -> Bool {
    let lower = message.lowercased()
    let needles = [
        "connection reset", "connection refused", "connection closed",
        "broken pipe", "eof", "premature close", "socket hang up",
        "timed out", "timeout", "etimedout", "econnreset", "econnrefused",
        "enotfound", "enetdown", "ehostunreach", "network is unreachable",
        "operation timed out", "request timeout",
        "502", "503", "504", "gateway", "internal server error", "500",
    ]
    return needles.contains(where: { lower.contains($0) })
}

/// Whether `message` looks recoverable by an auto-retry — covers both the
/// classic rate-limit / overload signals and the new transient-network signals.
func isRecoverableError(_ message: String) -> Bool {
    isRateLimitError(message) || isTransientNetworkError(message)
}

/// Exponential backoff sleep. `attempt` is 1-indexed. Caps at 60s.
func rateLimitBackoffSleep(attempt: Int) async {
    let seconds = min(60.0, pow(2.0, Double(attempt)))
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// Emit a single newline-delimited JSON line to stdout (stream-json mode).
func emitStreamJson(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let str = String(data: data, encoding: .utf8) else { return }
    FileHandle.standardOutput.write(Data((str + "\n").utf8))
}

struct QueryResult: Codable {
    let sessionId: String?
    let text: String
    let toolCallCount: Int
    let ok: Bool
}

@discardableResult
func runHeadlessClaude(
    prompt: String,
    project: String?,
    yolo: Bool,
    permissionMode: String,
    modelOverride: String?,
    includeClaudeMd: Bool,
    includeSkills: Bool = true,
    resumeSessionId: String?,
    attachments: [BridgeAttachment] = [],
    maxTurns: Int = 50,
    jsonOutput: Bool = false,
    outputFile: String? = nil,
    suppressOutput: Bool = false,
    allowedTools: [String] = [],
    disallowedTools: [String] = [],
    useMCP: Bool = true,
    systemPromptOverride: String? = nil,
    appendSystemPrompt: String? = nil,
    verbose: Bool = false,
    streamJson: Bool = false,
    additionalDirectories: [String] = [],
    mcpConfigOverride: String? = nil,
    thinking: Bool = false,
    agentDefinitions: [String: [String: String]] = [:],
    agentName: String? = nil,
    bridgeSocketPath: String? = nil,
    /// When true, route through LingCode's hosted proxy instead of
    /// hitting api.anthropic.com directly. Pulls the user's CLI token
    /// from the `lingmodel-cli-token` keychain entry and sets
    /// ANTHROPIC_BASE_URL on the bridge env so the SDK posts to
    /// `https://lingcode.dev/api/inference/anthropic/v1/messages`.
    useLingModel: Bool = false,
    /// When true, route the Agent SDK at DeepSeek's `/anthropic`-compatible
    /// endpoint with the user's DeepSeek key. Same loop as Claude/LingModel,
    /// transparent provider (no LingModel identity opacity). Mirrors the REPL's
    /// `--provider deepseek-claude` plumbing so `lingcode ask` reaches the same
    /// runtime.
    useDeepSeekDirect: Bool = false
) async throws -> String {
    let cwd: URL
    if let project = project, !project.isEmpty {
        cwd = URL(fileURLWithPath: (project as NSString).expandingTildeInPath)
    } else {
        cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    let extraNodePaths = [CLIResources.bundledNodePath()].compactMap { $0 }
    guard let nodePath = NodeResolver.resolve(extraSearchPaths: extraNodePaths) else {
        let msg = """
            lingcode: bundled Node.js runtime is missing and no system `node` was found.

            Reinstall lingcode to restore the bundled runtime, or install Node.js
            (https://nodejs.org / `brew install node`) as a fallback. Run
            `lingcode doctor` for diagnostics.

            """
        FileHandle.standardError.write(Data(msg.utf8))
        throw ExitCode(1)
    }

    let resources: BridgeResources
    do {
        let bundledRoot = try CLIResources.bundleURL()
            .appendingPathComponent("agent-bridge").path
        resources = try BridgeResourceLocator(extraSearchRoots: [bundledRoot]).locate()
    } catch let err as CLIResources.LookupError {
        let msg = """
            lingcode: \(err.description)

            Reinstall the CLI:
              curl -fsSL https://lingcode.dev/install-cli.sh | sh

            """
        FileHandle.standardError.write(Data(msg.utf8))
        throw ExitCode(1)
    } catch let err as BridgeResourceLocator.LocationError {
        let msg = """
            lingcode: \(err.description)

            Install LingCode.app at /Applications, or set LINGCODE_AGENT_BRIDGE_DIR to a
            directory containing bridge.mjs (and ideally sdk-bundle.mjs).

            """
        FileHandle.standardError.write(Data(msg.utf8))
        throw ExitCode(1)
    }

    // API key resolution order: env var → SecretStore (Keychain on macOS,
    // chmod-600 file on Linux) → ConfigStore on-disk fallback. The keychain
    // step was missing previously, which made `lingcode auth login` save the
    // key successfully but the REPL fail with "ANTHROPIC_API_KEY is not set".
    //
    // useLingModel: read from the `lingmodel-cli-token` slot instead and
    // route through the hosted proxy via ANTHROPIC_BASE_URL.
    let lingModelBaseURL = "https://lingcode.dev/api/inference/anthropic"
    let deepseekDirectBaseURL = "https://api.deepseek.com/anthropic"
    let anthropicKey: String? = {
        if useLingModel {
            if let env = ProcessInfo.processInfo.environment["LINGCODE_CLI_TOKEN"], !env.isEmpty {
                return env
            }
            let kAccount = keychainAccount(
                base: "lingmodel-cli-token",
                account: CLIEnvironment.resolvedAccount(forProvider: "lingmodel")
            )
            if let kc = try? SecretStore.get(service: keychainService, account: kAccount),
               !kc.isEmpty {
                return kc
            }
            return nil
        }
        if useDeepSeekDirect {
            if let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !env.isEmpty {
                return env
            }
            let kAccount = keychainAccount(
                base: "deepseek-api-key",
                account: CLIEnvironment.resolvedAccount(forProvider: "deepseek")
            )
            if let kc = try? SecretStore.get(service: keychainService, account: kAccount),
               !kc.isEmpty {
                return kc
            }
            return ConfigStore.load().deepseekAPIKey
        }
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty {
            return env
        }
        let kAccount = keychainAccount(
            base: "anthropic-api-key",
            account: CLIEnvironment.resolvedAccount(forProvider: "anthropic")
        )
        if let kc = try? SecretStore.get(service: keychainService, account: kAccount),
           !kc.isEmpty {
            return kc
        }
        return ConfigStore.load().anthropicAPIKey
    }()
    if anthropicKey == nil || anthropicKey?.isEmpty == true {
        let msg: String
        if useLingModel {
            msg = """
                lingcode: no LingModel CLI token configured.

                Sign in once at https://lingcode.dev/cli-token.html, copy the
                token, then run:

                  lingcode auth login --provider lingmodel

                …and paste the token when prompted. Free tier ships with the
                same hosted quota as the Mac app and the web playground.

                """
        } else if useDeepSeekDirect {
            msg = """
                lingcode: DEEPSEEK_API_KEY is not set.

                Set it via:
                  lingcode auth login --provider deepseek
                  export DEEPSEEK_API_KEY=sk-...

                """
        } else {
            msg = """
                lingcode: ANTHROPIC_API_KEY is not set.

                Set it in your shell or via config:
                  export ANTHROPIC_API_KEY=sk-ant-...
                  lingcode config set anthropic-api-key sk-ant-...

                """
        }
        FileHandle.standardError.write(Data(msg.utf8))
        throw ExitCode(1)
    }

    let modeRaw = yolo ? "bypassPermissions" : permissionMode
    let mode = BridgePermissionMode(rawValue: modeRaw) ?? .default

    if resources.bundledSDKPath == nil {
        FileHandle.standardError.write(Data("lingcode: warning: sdk-bundle.mjs not found alongside bridge.mjs; relying on LINGCODE_CLAUDE_AGENT_SDK_PATH from env.\n".utf8))
    }

    // Wrap with HardcodedDenyDecider so built-in security tripwires
    // (rm -rf /, fork bomb, system file writes, …) fire even under --yolo.
    // bypassPermissions mode in the SDK skips canUseTool entirely — for that
    // case the user has explicitly opted out of all gating.
    let baseDecider: any PermissionDecider = {
        if yolo { return AllowAllPermissionDecider() }
        if isatty(fileno(stdin)) != 0 { return TTYPermissionDecider() }
        return DenyAllPermissionDecider()
    }()
    let decider: any PermissionDecider = HardcodedDenyDecider(baseDecider)

    // Resolve model: flag → config → nil (bridge default). For LingModel
    // mode, default to `lingmodel-standard` (hosted Standard tier mapping in bridge; legacy alias `lingmodel-fast`).
    // For DeepSeek-direct, default to V4-Pro 1M context (mirrors REPL).
    let resolvedModel: String? = modelOverride
        ?? (useLingModel ? "lingmodel-standard"
            : useDeepSeekDirect ? "deepseek-v4-pro[1m]"
            : ConfigStore.load().defaultClaudeModel)

    let mcpServers = useMCP ? MCPConfig.load(cwd: cwd, overridePath: mcpConfigOverride) : [:]
    // LingModel mode: redirect the Anthropic SDK to our proxy. The bridge
    // already passes ANTHROPIC_API_KEY through extraEnvironment via the
    // `anthropicAPIKey` field; we just need to add the base URL.
    var extraEnv: [String: String] = [:]
    if useLingModel { extraEnv["ANTHROPIC_BASE_URL"] = lingModelBaseURL }
    if useDeepSeekDirect, let key = anthropicKey {
        // Mirrors DeepSeek's official Claude Code integration guide. AUTH_TOKEN
        // is what their compat layer expects; the *_DEFAULT_*_MODEL vars catch
        // internal SDK calls asking for "opus"/"sonnet"/"haiku" and remap them
        // onto DeepSeek model names. Subagent → flash to keep cost down.
        extraEnv["ANTHROPIC_BASE_URL"] = deepseekDirectBaseURL
        extraEnv["ANTHROPIC_AUTH_TOKEN"] = key
        extraEnv["ANTHROPIC_MODEL"] = "deepseek-v4-pro[1m]"
        extraEnv["ANTHROPIC_DEFAULT_OPUS_MODEL"] = "deepseek-v4-pro[1m]"
        extraEnv["ANTHROPIC_DEFAULT_SONNET_MODEL"] = "deepseek-v4-pro[1m]"
        extraEnv["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = "deepseek-v4-flash"
        extraEnv["CLAUDE_CODE_SUBAGENT_MODEL"] = "deepseek-v4-flash"
        extraEnv["CLAUDE_CODE_EFFORT_LEVEL"] = "max"
    }

    let config = AgentBridgeConfiguration(
        nodePath: nodePath,
        resources: resources,
        workingDirectory: cwd,
        permissionMode: mode,
        maxTurns: maxTurns,
        modelOverride: resolvedModel,
        claudeBinaryPath: ClaudeBinaryResolver.resolve(),
        anthropicAPIKey: anthropicKey,
        extraEnvironment: extraEnv,
        mcpServers: mcpServers,
        systemPrompt: systemPromptOverride,
        appendSystemPrompt: appendSystemPrompt,
        additionalDirectories: additionalDirectories,
        thinking: thinking,
        bridgeSocketPath: bridgeSocketPath
    )

    let session = AgentBridgeSession(configuration: config, decider: decider)

    // Subscribe BEFORE start() — bridge can emit `ready` within ms of spawn;
    // if continuation isn't attached yet the event is dropped and we hang.
    let stream = await session.events()

    try await session.start()

    // Hooks (parity with `lingcode repl`): load from `.claude/settings.json` /
    // `.claude/settings.local.json` and dispatch UserPromptSubmit / PreToolUse /
    // PostToolUse / Stop around bridge events. Hooks run in Swift land — the bridge
    // doesn't need to know about them.
    let hooks = HooksConfig.load(cwd: cwd)

    let claudeMd = includeClaudeMd ? ProjectContext.loadClaudeMd(startingAt: cwd) : nil
    let skills = includeSkills ? SkillsContext.loadSkills(cwd: cwd) : []
    let wrappedPrompt = SkillsContext.wrap(
        prompt: ProjectContext.wrap(prompt: prompt, claudeMd: claudeMd),
        skills: skills
    )

    var sentStart = false
    var lastWasNewline = true
    var sawAssistant = false
    var lastSessionId: String?
    // Tracks the most-recent .toolUse so PostToolUse hooks can see the same
    // toolName/toolInput in env vars — bridge events don't repeat them on .toolResult.
    var lastToolName = ""
    var lastToolInput = ""
    var responseText = ""
    var toolCallCount = 0
    var totalInputTokens = 0
    var totalOutputTokens = 0
    var totalCacheTokens = 0
    var retryAttempt = 0
    let maxRetries = 5

    do {
        for try await event in stream {
            switch event {
            case .ready:
                if !sentStart {
                    sentStart = true
                    let _upsPayload = HookPayload(
                        event: .userPromptSubmit,
                        sessionId: lastSessionId ?? "headless-claude-pending",
                        cwd: cwd.path,
                        userPrompt: prompt,
                        provider: "claude"
                    )
                    _ = await hooks.fire(event: .userPromptSubmit, payload: _upsPayload, cwd: cwd)
                    _ = try await session.send(
                        prompt: wrappedPrompt,
                        resumeSessionId: resumeSessionId,
                        attachments: attachments,
                        allowedTools: allowedTools,
                        disallowedTools: disallowedTools,
                        agentDefinitions: agentDefinitions,
                        agentName: agentName
                    )
                }
            case .assistantText(let text):
                sawAssistant = true
                responseText += text
                if streamJson {
                    emitStreamJson(["type": "assistant_text", "text": text])
                } else if !jsonOutput && !suppressOutput {
                    FileHandle.standardOutput.write(Data(text.utf8))
                    lastWasNewline = text.hasSuffix("\n")
                }
            case .toolUse(let name, let input, _):
                toolCallCount += 1
                lastToolName = name
                lastToolInput = input
                let _preTUPayload = HookPayload(
                    event: .preToolUse,
                    sessionId: lastSessionId ?? "headless-claude-pending",
                    cwd: cwd.path,
                    toolName: name,
                    toolInput: input,
                    provider: "claude"
                )
                let _preTUOutcome = await hooks.fire(
                    event: .preToolUse,
                    toolName: name,
                    payload: _preTUPayload,
                    cwd: cwd
                )
                // Claude path limitation: by the time .toolUse arrives, the bridge
                // has already settled permission and is about to execute. A `.blocked`
                // hook outcome here can't actually stop the tool. v1.1 fixes this by
                // moving PreToolUse fire into AgentBridgeSession before the bridge's
                // permission flow (see docs/HOOKS.md "v1.1 follow-ups").
                if case .blocked(let reason) = _preTUOutcome {
                    FileHandle.standardError.write(Data(
                        "[hook] PreToolUse wanted to block \(name): \(reason) — Claude path can't block until v1.1\n".utf8
                    ))
                }
                if streamJson {
                    emitStreamJson(["type": "tool_use", "name": name, "input": input])
                } else if !jsonOutput {
                    let shown = verbose ? input : (input.count > 200 ? String(input.prefix(200)) + "…" : input)
                    let line = (lastWasNewline ? "" : "\n") + "» \(name) \(shown)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
                lastWasNewline = true
            case .toolResult(let content, let isError, _):
                let _postTUPayload = HookPayload(
                    event: .postToolUse,
                    sessionId: lastSessionId ?? "headless-claude-pending",
                    cwd: cwd.path,
                    toolName: lastToolName,
                    toolInput: lastToolInput,
                    toolOutput: content,
                    toolError: isError,
                    provider: "claude"
                )
                _ = await hooks.fire(
                    event: .postToolUse,
                    toolName: lastToolName,
                    payload: _postTUPayload,
                    cwd: cwd
                )
                // Note: PostToolUse stdout injection (ratified design) doesn't reach
                // the model on the Claude path — the bridge has already consumed the
                // tool result. v1.1's AgentBridgeSession surgery closes this gap.
                if streamJson {
                    emitStreamJson(["type": "tool_result", "content": content, "is_error": isError])
                } else if !jsonOutput {
                    let label = isError ? "✗" : "✓"
                    let shown: String = verbose
                        ? content
                        : {
                            let t = content.count > 200 ? String(content.prefix(200)) + "…" : content
                            return t.replacingOccurrences(of: "\n", with: " ")
                        }()
                    let line = "\(label) \(shown)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
                lastWasNewline = true
            case .tokenUsage(let inp, let out, let cacheRead, let cacheCreation):
                totalInputTokens  += inp
                totalOutputTokens += out
                // Cache read + cache creation both occupy context window
                // slots; lump them as "cache tokens" for cost-display.
                totalCacheTokens  += cacheRead + cacheCreation
            case .permissionRequested:
                continue
            case .permissionResolved:
                continue
            case .queryFinished(let sid, _):
                for cmd in hooks.commands(for: .stop) {
                    await runHook(cmd, prompt: prompt, cwd: cwd)
                }
                if !jsonOutput && !lastWasNewline {
                    FileHandle.standardOutput.write(Data("\n".utf8))
                }
                if let sid = sid, !sid.isEmpty {
                    lastSessionId = sid
                    SessionStore.save(
                        sessionId: sid,
                        forCwd: cwd,
                        promptPreview: String(prompt.prefix(80))
                    )
                    if !jsonOutput, !suppressOutput, !CLIEnvironment.quiet, isatty(fileno(stderr)) != 0 {
                        FileHandle.standardError.write(Data("(continue with: lingcode ask --continue \"…\")\n".utf8))
                    }
                }
                if !jsonOutput, !suppressOutput, !CLIEnvironment.quiet, isatty(fileno(stderr)) != 0,
                    (totalInputTokens + totalOutputTokens) > 0 {
                    let cost = headlessEstimateCost(input: totalInputTokens, output: totalOutputTokens, cache: totalCacheTokens)
                    let nf = NumberFormatter(); nf.numberStyle = .decimal
                    let inStr  = nf.string(from: NSNumber(value: totalInputTokens))  ?? "\(totalInputTokens)"
                    let outStr = nf.string(from: NSNumber(value: totalOutputTokens)) ?? "\(totalOutputTokens)"
                    FileHandle.standardError.write(Data("↑ \(inStr) ↓ \(outStr) tokens (~\(cost))\n".utf8))
                }
                await session.shutdown()

                if streamJson {
                    emitStreamJson([
                        "type": "result",
                        "session_id": lastSessionId ?? "",
                        "text": responseText,
                        "tool_call_count": toolCallCount,
                        "input_tokens": totalInputTokens,
                        "output_tokens": totalOutputTokens,
                        "cache_tokens": totalCacheTokens,
                        "ok": true,
                    ])
                } else if jsonOutput {
                    let result = QueryResult(
                        sessionId: lastSessionId,
                        text: responseText,
                        toolCallCount: toolCallCount,
                        ok: true
                    )
                    if let data = try? JSONEncoder().encode(result),
                       let str = String(data: data, encoding: .utf8) {
                        print(str)
                    }
                }

                if let path = outputFile {
                    let outURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                    try? responseText.write(to: outURL, atomically: true, encoding: .utf8)
                }

                if !jsonOutput && !sawAssistant {
                    FileHandle.standardError.write(Data("lingcode: query finished without any assistant output.\n".utf8))
                }
                return responseText

            case .queryFailed(let m):
                // Rate-limit, overloaded, or transient network error: back off
                // and retry transparently. Network blips use a shorter base wait
                // since they typically resolve in seconds, not minutes.
                if isRecoverableError(m) && retryAttempt < maxRetries {
                    retryAttempt += 1
                    let isNetwork = !isRateLimitError(m)
                    let wait: Int = isNetwork
                        ? Int(min(15.0, 1.0 + pow(2.0, Double(retryAttempt - 1))))
                        : Int(min(60.0, pow(2.0, Double(retryAttempt))))
                    let kind = isNetwork ? "network blip" : "rate limited"
                    if !jsonOutput && !suppressOutput {
                        FileHandle.standardError.write(Data(
                            "lingcode: \(kind) (attempt \(retryAttempt)/\(maxRetries)) — retrying in \(wait)s…\n".utf8
                        ))
                    }
                    try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                    // Reset per-turn output state so only the successful retry's output is emitted.
                    responseText = ""
                    sawAssistant = false
                    lastWasNewline = true
                    do {
                        _ = try await session.send(
                            prompt: wrappedPrompt,
                            resumeSessionId: resumeSessionId,
                            attachments: attachments,
                            allowedTools: allowedTools,
                            disallowedTools: disallowedTools
                        )
                    } catch {
                        FileHandle.standardError.write(Data("lingcode: retry send failed: \(error)\n".utf8))
                        await session.shutdown()
                        throw ExitCode(1)
                    }
                    continue
                }
                if jsonOutput {
                    let result = QueryResult(sessionId: nil, text: "", toolCallCount: toolCallCount, ok: false)
                    if let data = try? JSONEncoder().encode(result),
                       let str = String(data: data, encoding: .utf8) {
                        print(str)
                    }
                }
                FileHandle.standardError.write(Data("lingcode: query failed: \(m)\n".utf8))
                await session.shutdown()
                throw ExitCode(1)
            case .queryCancelled(let m):
                FileHandle.standardError.write(Data("lingcode: cancelled: \(m)\n".utf8))
                await session.shutdown()
                throw ExitCode(130)
            case .bridgeError(let m, let code):
                let codeStr = code.map { " [\($0)]" } ?? ""
                FileHandle.standardError.write(Data("lingcode: bridge error\(codeStr): \(m)\n\(retryHint(for: m))\n".utf8))
            case .bridgeExited(let code, let stderr):
                if code != 0 {
                    let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    let detail = trimmed.isEmpty ? "" : "\n\(trimmed)"
                    FileHandle.standardError.write(Data("lingcode: bridge exited with code \(code)\(detail)\n\(retryHint(for: trimmed))\n".utf8))
                    throw ExitCode(1)
                }
                return responseText
            case .queryStarted:
                continue

            case .userInputRequested(let request):
                // No interactive question UI in headless mode — decline so the
                // model is told the user didn't answer rather than parking the
                // turn waiting on a selection that can't be made here.
                await session.respondToUserInput(requestId: request.id, answers: [:], cancelled: true)
                continue

            case .sdkMessage, .subagentStarted, .subagentFinished, .sessionRecovered,
                 .memoryWriteRequest, .skillWriteRequest, .sessionSearchRequest:
                continue
            }
        }
    } catch let exit as ExitCode {
        await session.shutdown()
        throw exit
    } catch {
        await session.shutdown()
        FileHandle.standardError.write(Data("lingcode: \(error)\n".utf8))
        throw ExitCode(1)
    }
    return responseText
}

