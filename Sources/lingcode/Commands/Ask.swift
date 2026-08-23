import ArgumentParser
import Foundation
import LingCodeAgentCore
import LingCodeIPC

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Ask: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "Send a prompt to LingCode and stream the answer.",
        discussion: """
        When LingCode.app is running, the prompt is routed to the app over IPC.
        Otherwise (or with --headless) it runs locally.

        Providers (all support text; see --yolo / --permission-mode for tool use):
          claude          Agent SDK (MCP + hooks + sessions). Needs ANTHROPIC_API_KEY.
          deepseek        DeepSeek native API. Needs DEEPSEEK_API_KEY.
          openai          OpenAI (GPT-4o, o1, GPT-5, …). Needs OPENAI_API_KEY.
          azure           Azure OpenAI. Needs AZURE_OPENAI_ENDPOINT + _DEPLOYMENT + _API_KEY (+ optional _API_VERSION).
          gemini          Google Gemini (2.5 Flash/Pro). Needs GEMINI_API_KEY.
          kimi            Moonshot Kimi K2. Needs MOONSHOT_API_KEY.
          qwen            Alibaba Qwen (DashScope intl). Needs DASHSCOPE_API_KEY.
          groq            Groq (very fast Llama/Qwen). Needs GROQ_API_KEY.
          together        Together AI. Needs TOGETHER_API_KEY.
          openrouter      OpenRouter aggregator. Needs OPENROUTER_API_KEY.
          mistral         Mistral AI. Needs MISTRAL_API_KEY.
          xai             xAI (Grok). Needs XAI_API_KEY.
          fireworks       Fireworks AI. Needs FIREWORKS_API_KEY.
          ollama          Local Ollama server (http://localhost:11434). No key needed.
          deepseek-compat DeepSeek via OpenAI-compatible path (shares DEEPSEEK_API_KEY).

        Agentic mode on non-Claude providers:
          --yolo                              auto-approve every tool call (dangerous)
          --permission-mode default           prompt per tool call at the TTY (recommended)
          --permission-mode bypassPermissions same as --yolo
          --permission-mode dontAsk           deny all tool calls (tools visible but blocked)

        Tool filtering:
          --allowed-tools "Read,Grep"         whitelist (all other builtin tools hidden)
          --disallowed-tools "Write,Edit"     blacklist specific tools
          Tools: Read, Write, Edit, MultiEdit, Bash, Grep, Glob
          NB: blocking Write without also blocking Bash still lets the model write via
              shell commands (`echo > file`). For a true read-only mode, pass
              --disallowed-tools "Write,Edit,MultiEdit,Bash"
              or use --allowed-tools "Read,Grep,Glob".

        Custom OpenAI-compatible endpoints:
          lingcode ask --provider openai --base-url https://my-proxy/v1 --api-key-env MY_KEY ...

        Pipe content as additional context:  cat error.log | lingcode ask "explain"
        Read the entire prompt from stdin:    echo "what is 2+2?" | lingcode ask -
        """
    )

    @Argument(help: "Prompt to send. Use `-` to read from stdin.")
    var prompt: String?

    @Option(name: .long, help: "Project directory for headless mode (defaults to cwd).")
    var project: String?

    @Flag(name: .long, help: "Force headless mode even if LingCode.app is running.")
    var headless: Bool = false

    @Option(name: .long, help: "Provider: claude | deepseek | deepseek-claude | openai | gemini | kimi | qwen | groq | together | openrouter | mistral | xai | fireworks | ollama | deepseek-compat. (deepseek-claude routes the user's DeepSeek key through the Claude Code agent loop via DeepSeek's /anthropic endpoint.) (default: from config, else claude)")
    var provider: String?

    @Option(name: .long, help: "DeepSeek model: deepseek-v4-pro, deepseek-v4-flash (default), or legacy deepseek-chat / deepseek-reasoner (retiring 2026-07-24). (deepseek provider only)")
    var model: String = "deepseek-v4-flash"

    @Option(name: .long, help: "Override Claude model (e.g. claude-sonnet-4-6). (claude provider only)")
    var claudeModel: String?

    @Option(name: .long, help: "Bridge permission mode: default, acceptEdits, plan, dontAsk. Ignored with --yolo. (claude provider only)")
    var permissionMode: String?

    @Flag(name: .long, help: "Auto-allow every tool call. Dangerous — only with trusted prompts. (claude provider only)")
    var yolo: Bool = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Include top-level file listing in system prompt. (deepseek provider only)")
    var tree: Bool = true

    @Flag(name: .long, inversion: .prefixedNo, help: "Auto-load CLAUDE.md files from cwd up to $HOME.")
    var claudeMd: Bool = true

    @Flag(name: .long, inversion: .prefixedNo, help: "Auto-load .claude/skills/*/SKILL.md (project) and ~/.claude/skills/ (user) into the prompt.")
    var skills: Bool = true

    @Option(name: .long, help: "Resume a specific session by id. (claude, deepseek, openai-compat)")
    var resume: String?

    @Option(name: .long, help: "Fork from an existing session id. Duplicates the session's messages under a new id, prints it, and exits. Continue the fork with `lingcode ask --resume <new-id> \"...\"`. (deepseek + openai-compat session stores only; claude path TBD)")
    var forkFrom: String?

    @Flag(name: .long, help: "Continue the most recent session for this directory. (claude, deepseek, openai-compat)")
    var `continue`: Bool = false

    @Option(name: .long, help: "Attach a file to the prompt (may be repeated; type inferred from extension). (claude provider only)")
    var file: [String] = []

    @Option(name: .long, help: "Attach an image (png/jpg/gif/webp) to the prompt. May be repeated. (OpenAI-compatible providers only; use --file for Claude).")
    var image: [String] = []

    @Option(name: .long, help: "Maximum agent turns. (claude provider only)")
    var maxTurns: Int = 50

    @Flag(name: .long, help: "Output result as JSON {sessionId, text, toolCallCount, ok}.")
    var json: Bool = false

    @Option(name: .long, help: "Write assistant response to this file path.")
    var output: String?

    @Option(name: .long, help: "Allow only these tools (comma-separated, e.g. Read,Write). (claude only)")
    var allowedTools: String?

    @Option(name: .long, help: "Disallow these tools (comma-separated). (claude only)")
    var disallowedTools: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Load MCP servers from .mcp.json / ~/.claude.json. (all providers)")
    var mcp: Bool = true

    @Option(name: .long, help: "Override the system prompt. (claude only)")
    var systemPrompt: String?

    @Option(name: .long, help: "Append additional content to the system prompt. (claude only)")
    var appendSystemPrompt: String?

    @Flag(name: .long, help: "Show full tool input/output without truncation.")
    var verbose: Bool = false

    @Option(name: .long, help: "Output format: text (default), json, stream-json.")
    var outputFormat: String = "text"

    @Option(name: .customLong("output-schema"), help: "Path to a JSON Schema file describing the model's final response shape. (codex only — forwards to `codex exec --output-schema`)")
    var outputSchemaPath: String?

    @Option(name: .long, help: "Extra directory Claude can read/write (repeatable). (claude only)")
    var addDir: [String] = []

    @Option(name: .long, help: "Path to an MCP config JSON (overrides .mcp.json / ~/.claude.json).")
    var mcpConfig: String?

    @Flag(name: .long, help: "Enable Claude's extended thinking mode. (claude only)")
    var thinking: Bool = false

    @Option(name: .long, help: "Base URL override for openai-compatible providers.")
    var baseUrl: String?

    @Option(name: .long, help: "Environment variable name for the API key (overrides provider default).")
    var apiKeyEnv: String?

    @Option(name: .long, help: "Run as a subagent loaded from .claude/agents/<name>.md (project) or ~/.claude/agents/. Applies the agent's system prompt, tool allowlist, and model override. (claude provider only)")
    var agent: String?

    @Option(name: .long, help: "Subagent dispatch mode: 'lite' (default — edit the prompt+tools client-side) or 'full' (register with the SDK; experimental). Ignored without --agent.")
    var agentMode: SubagentMode = .lite

    @Option(name: .long, help: "Account label for multi-account setups (`lingcode auth login --account work`). Omit to use the active account from `lingcode auth use`, or the default slot.")
    var account: String?

    @Flag(name: .customLong("no-color"), help: "Disable ANSI color output even on a TTY (also honored: NO_COLOR=1).")
    var noColor: Bool = false

    @Flag(name: .shortAndLong, help: "Suppress progress output and post-run token summary (also honored: LINGCODE_QUIET=1).")
    var quiet: Bool = false

    @Flag(name: .shortAndLong, help: "After the one-shot finishes, drop into an interactive REPL with --continue (same session). Requires a TTY.")
    var interactive: Bool = false

    @Flag(name: .long, help: "Connect to the running bridge daemon (`lingcode bridge daemon-start`) instead of cold-spawning Node. Saves ~1–3s per invocation; useful in tight scripting loops. (claude provider only)")
    var viaDaemon: Bool = false

    @Option(name: .long, help: "HTTP idle timeout in seconds for streaming OpenAI-compatible providers. Raise it for slow upstreams (z.ai, deepseek-reasoner) that drop on time-to-first-token. Default 120; also honored: LINGCODE_HTTP_TIMEOUT.")
    var timeout: Int?

    func run() async throws {
        CLIEnvironment.apply(noColor: noColor, quiet: quiet, account: account)
        // Anonymous heartbeat — fire-and-forget, opt-out via `lingcode telemetry off`.
        Task.detached { await TelemetryClient.shared.sendHeartbeatIfDue(version: CLIVersion.current) }

        // Session lifecycle hooks. SessionStart fires before any provider dispatch;
        // SessionEnd fires only on clean completion at the end of run(). Early
        // returns (IPC hand-off to running Mac app, codex exec) deliberately don't
        // fire SessionEnd — those paths transfer control to a different process
        // that owns its own lifecycle. SIGINT/SIGTERM fires SessionEnd via the
        // signal handlers installed below.
        let _sessionCwd = URL(fileURLWithPath:
            project.map { ($0 as NSString).expandingTildeInPath }
                ?? FileManager.default.currentDirectoryPath)
        let _sessionProvider = provider ?? ConfigStore.load().defaultProvider
        let _sessionModel = claudeModel ?? model
        let _sessionId = await SessionLifecycleHook.fireStart(
            command: "ask",
            provider: _sessionProvider,
            model: _sessionModel,
            cwd: _sessionCwd
        )
        SessionLifecycleHook.installSignalHandlers(
            sessionId: _sessionId,
            provider: _sessionProvider,
            model: _sessionModel,
            cwd: _sessionCwd,
            turnCountProvider: { 0 }
        )

        // --fork-from: duplicate an existing session under a fresh id and exit.
        // Caller can then `lingcode ask --resume <new-id>` to continue from the
        // forked point. Tries both non-Claude session stores; Claude path's
        // bridge-managed sessions are a deferred follow-up.
        if let parentId = forkFrom, !parentId.isEmpty {
            try await runForkFrom(parentId: parentId)
            return
        }

        let resolvedPrompt = try buildPrompt()

        // App-IPC routing is macOS-only — the LingCode app's Unix socket only
        // exists on macOS. On Linux the CLI always runs headless, regardless
        // of the --headless flag.
        #if os(macOS)
        let client = IPCClient()
        if !headless && client.appIsLikelyRunning {
            // --via-daemon makes no difference here: the request is going to
            // the running app, not our bridge daemon. Tell the user instead of
            // silently doing nothing they asked for.
            if viaDaemon {
                FileHandle.standardError.write(Data(
                    "lingcode: --via-daemon is being ignored because LingCode.app is running and intercepts `ask` via IPC. Pass --headless to actually route through the bridge daemon.\n".utf8
                ))
            }
            try runIPCAsk(client: client, prompt: resolvedPrompt)
            return
        }
        #endif

        let cfg = ConfigStore.load()
        let resolvedProvider = provider ?? cfg.defaultProvider
        let resolvedPermMode = permissionMode ?? cfg.defaultPermissionMode

        var parsedAllowed    = allowedTools.map    { $0.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) } } ?? []
        let parsedDisallowed = disallowedTools.map { $0.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) } } ?? []
        if let err = KnownTools.validate(parsedAllowed + parsedDisallowed) {
            FileHandle.standardError.write(Data("lingcode: \(err)\n".utf8))
            throw ExitCode(2)
        }

        // --agent <name>: load agent definition and apply its body / tools / model
        // override before the headless path packs the bridge config.
        let agentCwd = URL(fileURLWithPath: project.map { ($0 as NSString).expandingTildeInPath } ?? FileManager.default.currentDirectoryPath)
        let loadedAgent: Subagent?
        if let name = agent, !name.isEmpty {
            guard let a = Subagent.load(name: name, cwd: agentCwd) else {
                let known = Subagent.list(cwd: agentCwd)
                let hint = known.isEmpty
                    ? "Place a Markdown file at .claude/agents/<name>.md (or ~/.claude/agents/) with YAML frontmatter."
                    : "Known: \(known.joined(separator: ", "))"
                FileHandle.standardError.write(Data("lingcode: unknown agent '\(name)'. \(hint)\n".utf8))
                throw ExitCode(2)
            }
            loadedAgent = a
            if !a.tools.isEmpty {
                parsedAllowed = parsedAllowed.isEmpty ? a.tools : parsedAllowed.filter { a.tools.contains($0) }
            }
        } else {
            loadedAgent = nil
        }
        let mergedAppendSystemPrompt: String? = {
            let base = appendSystemPrompt ?? ""
            let body = loadedAgent?.body ?? ""
            switch (base.isEmpty, body.isEmpty) {
            case (true, true):   return nil
            case (true, false):  return body
            case (false, true):  return base
            case (false, false): return base + "\n\n" + body
            }
        }()
        let agentClaudeModel = loadedAgent?.model ?? claudeModel

        switch resolvedProvider.lowercased() {
        case "openai", "groq", "together", "openrouter", "mistral", "xai",
             "fireworks", "deepseek", "deepseek-compat", "ollama", "gemini", "kimi", "qwen",
             "azure", "openai-compat":
            // `deepseek` and `deepseek-compat` both run on the unified OpenAI-compat
            // loop now — DeepSeek's native API is OpenAI-shaped, so the dedicated
            // DeepSeekAgentLoop is retired. `deepseek` is normalized to the
            // `deepseek-compat` preset below (same base URL / key / default model).
            // Resume support: --resume <id> looks up by id, --continue picks the
            // most recent for this cwd. Only the agent path actually uses the
            // history; HeadlessOpenAICompat warns and starts fresh otherwise.
            let cwdURL = FileManager.default.currentDirectoryPath
            let resumed: OpenAICompatSessionStore.Record? = {
                if let id = resume, !id.isEmpty {
                    return OpenAICompatSessionStore.load(id: id)
                }
                if `continue` {
                    return OpenAICompatSessionStore.loadLast(cwd: URL(fileURLWithPath: cwdURL))
                }
                return nil
            }()
            do {
                try await runHeadlessOpenAICompat(
                    prompt: resolvedPrompt,
                    project: project,
                    providerName: resolvedProvider.lowercased() == "deepseek" ? "deepseek-compat" : resolvedProvider,
                    model: claudeModel ?? (model == "deepseek-v4-flash" ? nil : model),
                    baseURLOverride: baseUrl,
                    apiKeyEnvOverride: apiKeyEnv,
                    includeClaudeMd: claudeMd,
                    includeSkills: skills,
                    imagePaths: image,
                    yolo: yolo,
                    permissionMode: permissionMode,
                    maxTurns: maxTurns,
                    verbose: verbose,
                    outputFile: output,
                    allowedTools: parsedAllowed,
                    disallowedTools: parsedDisallowed,
                    mcpEnabled: mcp,
                    mcpConfigPath: mcpConfig,
                    timeoutFlag: timeout,
                    priorMessages: resumed?.messages ?? [],
                    sessionId: resumed?.id
                )
            } catch {
                throw ExitCode(1)
            }
        case "claude", "lingmodel", "deepseek-claude":
            let attachments = file.compactMap { BridgeAttachment.inferring(path: $0) }
            // --output-format stream-json is a superset of --json; both surface structured output.
            let normalizedFormat = outputFormat.lowercased()
            let jsonFlag = json || normalizedFormat == "json" || normalizedFormat == "stream-json"
            let streamJson = normalizedFormat == "stream-json"
            let isLingModel = (resolvedProvider == "lingmodel")
            let isDeepSeekClaude = (resolvedProvider == "deepseek-claude")
            // LingModel and DeepSeek-Claude bypass the local Claude default model:
            // the bridge sends an explicit Messages-API model id (LingModel:
            // `lingmodel-standard` / `lingmodel-advanced`, with legacy aliases in bridge.mjs).
            let claudeModelForBridge = (isLingModel || isDeepSeekClaude)
                ? agentClaudeModel  // nil → runHeadlessClaude picks the right default per provider
                : (agentClaudeModel ?? cfg.defaultClaudeModel)

            try await runHeadlessClaude(
                prompt: resolvedPrompt,
                project: project,
                yolo: yolo,
                permissionMode: resolvedPermMode,
                modelOverride: claudeModelForBridge,
                includeClaudeMd: claudeMd,
                includeSkills: skills,
                resumeSessionId: resolveResumeSessionId(),
                attachments: attachments,
                maxTurns: maxTurns,
                jsonOutput: jsonFlag,
                outputFile: output,
                allowedTools: parsedAllowed,
                disallowedTools: parsedDisallowed,
                useMCP: mcp,
                systemPromptOverride: systemPrompt,
                appendSystemPrompt: mergedAppendSystemPrompt,
                verbose: verbose,
                streamJson: streamJson,
                additionalDirectories: addDir.map { ($0 as NSString).expandingTildeInPath },
                mcpConfigOverride: mcpConfig,
                thinking: thinking,
                agentDefinitions: (agentMode == .full && loadedAgent != nil) ? [loadedAgent!.name: loadedAgent!.toBridgeDefinition()] : [:],
                agentName: (agentMode == .full) ? loadedAgent?.name : nil,
                bridgeSocketPath: viaDaemon ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".lingcode/bridge/daemon.sock").path : nil,
                useLingModel: isLingModel,
                useDeepSeekDirect: isDeepSeekClaude
            )
        case "codex":
            do {
                let codexImages = image
                // Codex requires an explicit schema file for structured output —
                // it has no equivalent of `--output-format json` that emits a
                // generic envelope. If the user passes --json or
                // --output-format json|stream-json without a schema, warn but
                // continue with plain stdout.
                let normalizedFormat = outputFormat.lowercased()
                let jsonRequested = json || normalizedFormat == "json" || normalizedFormat == "stream-json"
                if jsonRequested && (outputSchemaPath == nil || outputSchemaPath?.isEmpty == true) {
                    FileHandle.standardError.write(Data(
                        "lingcode: --json / --output-format json with codex requires `--output-schema <path>`. Falling back to plain stdout.\n".utf8))
                }
                try await runHeadlessCodex(
                    prompt: resolvedPrompt,
                    project: project,
                    yolo: yolo,
                    permissionMode: permissionMode,
                    modelOverride: model,
                    includeAgentsMd: claudeMd,
                    includeSkills: skills,
                    outputFile: output,
                    verbose: verbose,
                    imagePaths: codexImages,
                    outputSchema: outputSchemaPath,
                    resumeSessionId: resume,
                    continueLast: `continue`
                )
            } catch {
                throw ExitCode(1)
            }
        default:
            FileHandle.standardError.write(Data("lingcode: unknown provider '\(resolvedProvider)'. Use deepseek, deepseek-claude, claude, codex, or lingmodel (also: openai, groq, together, openrouter, mistral, xai, fireworks, gemini, kimi, qwen, ollama, azure, openai-compat, deepseek-compat).\n".utf8))
            throw ExitCode(2)
        }

        // --interactive: spawn `lingcode repl --continue` so the user lands in a
        // real REPL with the same session active. We launch as a child and wait
        // — Process inherits stdin/stdout/stderr so it feels like one program.
        if interactive {
            guard isatty(fileno(stdin)) != 0 else {
                FileHandle.standardError.write(Data("lingcode: --interactive requires a TTY\n".utf8))
                return
            }
            let exe = ProcessInfo.processInfo.arguments.first ?? "lingcode"
            var args: [String] = ["repl", "--continue"]
            if let acc = account, !acc.isEmpty { args += ["--account", acc] }
            if let proj = project, !proj.isEmpty { args += ["--project", proj] }
            if yolo { args.append("--yolo") }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: exe)
            proc.arguments = args
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus != 0 { throw ExitCode(proc.terminationStatus) }
            } catch let e as ExitCode {
                throw e
            } catch {
                FileHandle.standardError.write(Data("lingcode: failed to launch repl: \(error)\n".utf8))
                throw ExitCode(1)
            }
        }

        // SessionEnd — clean completion path. Error / signal paths don't reach here;
        // SIGINT/SIGTERM fires SessionEnd via the handler installed at run() start.
        await SessionLifecycleHook.fireEnd(
            sessionId: _sessionId,
            provider: _sessionProvider,
            model: _sessionModel,
            cwd: _sessionCwd,
            turnCount: 0,
            terminatedBy: "completion"
        )
    }

    // MARK: - Session forking

    /// Duplicates an existing session under a fresh id and prints the new id, then
    /// returns. Caller continues the fork via `lingcode ask --resume <new-id>`.
    /// Tries OpenAI-compat then DeepSeek-native session stores in that order. The
    /// Claude bridge's session store is managed by the bridge subprocess; forking
    /// there is a deferred follow-up (the REPL ships `/fork` for that path today).
    private func runForkFrom(parentId: String) async throws {
        // Try OpenAI-compat store first (covers 13 providers).
        if let parent = OpenAICompatSessionStore.load(id: parentId) {
            let newId = OpenAICompatSessionStore.newSessionId()
            let now = Date()
            OpenAICompatSessionStore.save(.init(
                id: newId,
                cwd: parent.cwd,
                provider: parent.provider,
                model: parent.model,
                createdAt: now,
                updatedAt: now,
                messages: parent.messages
            ))
            Swift.print("Forked \(parentId) → \(newId) (openai-compat store, \(parent.messages.count) messages)")
            Swift.print("Continue with: lingcode ask --resume \(newId) \"...\"")
            return
        }
        // Fall back to DeepSeek-native store.
        if let parent = DeepSeekSessionStore.load(id: parentId) {
            let newId = DeepSeekSessionStore.newSessionId()
            let now = Date()
            DeepSeekSessionStore.save(.init(
                id: newId,
                cwd: parent.cwd,
                model: parent.model,
                systemPrompt: parent.systemPrompt,
                createdAt: now,
                updatedAt: now,
                messages: parent.messages
            ))
            Swift.print("Forked \(parentId) → \(newId) (deepseek-native store, \(parent.messages.count) messages)")
            Swift.print("Continue with: lingcode ask --provider deepseek --resume \(newId) \"...\"")
            return
        }
        FileHandle.standardError.write(Data((
            "lingcode ask: session '\(parentId)' not found in DeepSeek or OpenAI-compat session stores. "
          + "Check `lingcode history` for a list of known session ids. The Claude bridge's session "
          + "store is not forkable from `ask` yet — use `/fork` from `lingcode repl` instead.\n"
        ).utf8))
        throw ExitCode(2)
    }

    // MARK: - Prompt assembly

    private func buildPrompt() throws -> String {
        let stdinPiped = isatty(fileno(stdin)) == 0
        let arg = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Case 1: prompt is "-" → entire prompt comes from stdin.
        if arg == "-" {
            guard stdinPiped, let data = try? FileHandle.standardInput.readToEnd() else {
                FileHandle.standardError.write(Data("lingcode: `-` requires data on stdin.\n".utf8))
                throw ExitCode(2)
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                FileHandle.standardError.write(Data("lingcode: stdin was empty.\n".utf8))
                throw ExitCode(2)
            }
            return trimmed
        }

        // Case 2: no prompt argument and stdin is piped → use stdin entirely.
        if arg.isEmpty {
            if stdinPiped, let data = try? FileHandle.standardInput.readToEnd() {
                let text = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
            FileHandle.standardError.write(Data("lingcode: prompt is required (positional argument or piped stdin).\n".utf8))
            throw ExitCode(2)
        }

        // Case 3: prompt argument + piped stdin → append stdin as context.
        if stdinPiped, let data = try? FileHandle.standardInput.readToEnd() {
            let extra = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !extra.isEmpty {
                return "\(arg)\n\n--- piped input ---\n\(extra)"
            }
        }
        return arg
    }

    private func resolveResumeSessionId() -> String? {
        if let r = resume, !r.isEmpty { return r }
        if `continue` {
            let cwd = project.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            if let id = SessionStore.loadLast(forCwd: cwd) { return id }
            FileHandle.standardError.write(Data("lingcode: no previous session found for this directory; starting a new one.\n".utf8))
        }
        return nil
    }


    #if os(macOS)
    private func runIPCAsk(client: IPCClient, prompt: String) throws {
        let request = IPCRequest(
            method: IPCMethod.ask.rawValue,
            params: IPCParams(prompt: prompt)
        )
        var terminalError: String?
        do {
            try client.sendStreaming(request) { frame in
                if let chunk = frame.result?.chunk {
                    print(chunk, terminator: "")
                    fflush(stdout)
                }
                if frame.streaming != true {
                    print("")
                    if !frame.ok, let err = frame.error {
                        terminalError = err.message
                    }
                }
            }
        } catch {
            FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
            throw ExitCode(1)
        }
        if let message = terminalError {
            FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
            throw ExitCode(1)
        }
    }
    #endif
}
