import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import LingCodeAgentCore

/// Curated list of Claude models the picker shows. Add aliases as Anthropic
/// publishes them. The order is what users see in /model.
struct KnownClaudeModel {
    let name: String
    let tagline: String
}

let knownClaudeModels: [KnownClaudeModel] = [
    .init(name: "claude-opus-4-7",            tagline: "Opus 4.7 — most capable, slowest, priciest"),
    .init(name: "claude-opus-4-6",            tagline: "Opus 4.6 — fast-mode flagship"),
    .init(name: "claude-sonnet-4-6",          tagline: "Sonnet 4.6 — balanced default"),
    .init(name: "claude-sonnet-4-5",          tagline: "Sonnet 4.5 — prior balanced"),
    .init(name: "claude-haiku-4-5-20251001",  tagline: "Haiku 4.5 — fastest, cheapest"),
]

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Repl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repl",
        abstract: "Start an interactive multi-turn session.",
        discussion: """
        Interactive multi-turn chat in the terminal.

        Providers (--provider):
          claude (default)   Full agentic mode via Anthropic Agent SDK — tools, MCP, hooks, sessions.
          openai             OpenAI GPT-4o/o1/GPT-5 (OPENAI_API_KEY).
          gemini             Google Gemini 2.5 Flash/Pro (GEMINI_API_KEY).
          kimi               Moonshot Kimi K2 (MOONSHOT_API_KEY).
          qwen               Alibaba Qwen via DashScope intl (DASHSCOPE_API_KEY).
          groq               Groq (GROQ_API_KEY).
          together           Together AI (TOGETHER_API_KEY).
          openrouter         OpenRouter aggregator (OPENROUTER_API_KEY).
          mistral            Mistral (MISTRAL_API_KEY).
          xai                xAI / Grok (XAI_API_KEY).
          fireworks          Fireworks (FIREWORKS_API_KEY).
          ollama             Local Ollama (http://localhost:11434, no key).
          deepseek-compat    DeepSeek via OpenAI-compatible endpoint.
          deepseek-claude    DeepSeek via Anthropic-compatible endpoint — uses
                             the full Claude agent loop (tools, hooks, sessions)
                             with DeepSeek auth + DeepSeek models. MCP and
                             image input are not supported on this path.

        The Claude path has full MCP + hooks + session resumption. Other providers
        are text-only in the REPL today; for agentic tool use, use `lingcode ask --yolo`.

        Slash commands (all providers):
          /help              List commands
          /model <name>      Switch model mid-session
          /reset             Clear conversation (claude: also starts a fresh session)
          /clear             Clear the screen
          /cost              Show cumulative token usage
          /export [path]     Save transcript as markdown
          /quit or /exit     End the session

        Slash commands (claude only):
          /mode <mode>       Change permission mode
          /yolo              Bypass all permission prompts
          /fast [on|off]     Toggle fast mode (Opus 4.6); no arg toggles
          /compact           Summarise and compress conversation history
          /session           Show current session ID
          /tools             List available built-in tools
          /commands          List custom slash commands from .claude/commands/
          /skills            List loaded skills from .claude/skills/
          /doctor            Diagnose the LingCode environment
          /init              Generate CLAUDE.md for the current project

        Slash commands (openai-compatible only):
          /system <text>     Replace the system prompt

        Custom slash commands:
          /project:<name>    Prompt from .claude/commands/<name>.md (project-scoped)
          /user:<name>       Prompt from ~/.claude/commands/<name>.md (user-scoped)

        Input editor (when stdin is a TTY):
          ↑ / ↓             Recall previous / next input
          ← / → / Home / End Move cursor
          Tab               Complete slash commands
          Trailing `\\`      Continue the input on the next line
          Ctrl-C            Cancel running query; at an idle prompt press twice to exit
          Ctrl-D            Exit on empty line; otherwise delete char
        """
    )

    @Option(name: .long, help: "Project directory (defaults to cwd).")
    var project: String?

    @Option(name: .long, help: "Bridge permission mode: default, acceptEdits, plan, dontAsk.")
    var permissionMode: String?

    @Flag(name: .long, help: "Auto-allow every tool call. Dangerous — only with trusted prompts.")
    var yolo: Bool = false

    @Option(name: .long, help: "Override Claude model (e.g. claude-sonnet-4-6).")
    var claudeModel: String?

    @Flag(name: .long, help: "Start in fast mode (claude-opus-4-6). Equivalent to --claude-model claude-opus-4-6. Toggle mid-session with /fast.")
    var fast: Bool = false

    @Flag(name: .long, help: "Continue the most recent session for this directory.")
    var `continue`: Bool = false

    @Option(name: .long, help: "Resume a specific session by ID.")
    var resume: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Auto-load CLAUDE.md files from cwd up to $HOME.")
    var claudeMd: Bool = true

    @Flag(name: .long, inversion: .prefixedNo, help: "Auto-load .claude/skills/*/SKILL.md (project) and ~/.claude/skills/ (user) into the prompt.")
    var skills: Bool = true

    @Option(name: .long, help: "Named output style from .claude/output-styles/<name>.md (or ~/.claude/output-styles/). Defaults to 'engineer'.")
    var outputStyle: String?

    @Option(name: .long, help: "Maximum agent turns per query.")
    var maxTurns: Int?

    @Option(name: .long, help: "Allow only these tools (comma-separated, e.g. Read,Write).")
    var allowedTools: String?

    @Option(name: .long, help: "Disallow these tools (comma-separated).")
    var disallowedTools: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Load MCP servers from .mcp.json / ~/.claude.json.")
    var mcp: Bool = true

    @Option(name: .long, help: "Override the system prompt.")
    var systemPrompt: String?

    @Option(name: .long, help: "Append additional content to the system prompt.")
    var appendSystemPrompt: String?

    @Flag(name: .long, help: "Show full tool input/output without truncation.")
    var verbose: Bool = false

    @Option(name: .long, help: "Extra directory Claude can read/write (repeatable).")
    var addDir: [String] = []

    @Option(name: .long, help: "Path to an MCP config JSON (overrides .mcp.json / ~/.claude.json).")
    var mcpConfig: String?

    @Flag(name: .long, help: "Enable Claude's extended thinking mode.")
    var thinking: Bool = false

    @Option(name: .long, help: "Provider: lingmodel (hosted — sign in, no key) | claude (default) | deepseek-claude | openai | gemini | kimi | qwen | groq | together | openrouter | mistral | xai | fireworks | ollama | deepseek-compat.")
    var provider: String?

    @Option(name: .long, help: "Base URL override for OpenAI-compatible providers.")
    var baseUrl: String?

    @Option(name: .long, help: "Environment variable name for the API key.")
    var apiKeyEnv: String?

    @Option(name: .long, help: "Model override (provider-specific).")
    var model: String?

    @Option(name: .long, help: "Run as a subagent loaded from .claude/agents/<name>.md (project) or ~/.claude/agents/. Applies the agent's system prompt, tool allowlist, and model override.")
    var agent: String?

    @Option(name: .long, help: "Subagent dispatch mode: 'lite' (default — edit the prompt+tools client-side) or 'full' (register with the SDK for a real subagent context). Full is experimental.")
    var agentMode: SubagentMode = .lite

    @Option(name: .long, help: "Account label for multi-account setups (`lingcode auth login --account work`). Omit to use the active account from `lingcode auth use`, or the default slot.")
    var account: String?

    @Flag(name: .long, help: "Emit one JSON object per event on stdout (NDJSON) instead of styled text, for scripting. Implies --quiet --no-color.")
    var json: Bool = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI color output even on a TTY (also honored: NO_COLOR=1).")
    var noColor: Bool = false

    @Flag(name: .shortAndLong, help: "Suppress welcome banner, spinner, and post-turn token summary (also honored: LINGCODE_QUIET=1).")
    var quiet: Bool = false

    @Option(name: .long, help: "HTTP idle timeout in seconds for streaming OpenAI-compatible providers. Raise it for slow upstreams (z.ai, deepseek-reasoner) that drop on time-to-first-token. Default 120; also honored: LINGCODE_HTTP_TIMEOUT.")
    var timeout: Int?

    func run() async throws {
        // --json scripts the REPL — disable banner/spinner/color so stdout is
        // pure NDJSON. Users can still combine with --quiet/--no-color directly.
        CLIEnvironment.apply(noColor: noColor || json, quiet: quiet || json, account: account)
        let cwd: URL
        if let project = project, !project.isEmpty {
            cwd = URL(fileURLWithPath: (project as NSString).expandingTildeInPath)
        } else {
            cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }

        // Merge flags with stored config (flags win)
        var cfg = ConfigStore.load()

        // First-run onboarding: bare `lingcode` with no provider chosen and no
        // credential for the default provider drops into the interactive provider
        // picker (the same flow as `lingcode auth login`) instead of dead-ending
        // on "ANTHROPIC_API_KEY is not set". Gated on an interactive TTY and no
        // explicit --provider, so piped/headless/CI usage is unaffected.
        if provider == nil,
           isatty(STDIN_FILENO) != 0,
           firstRunCredentialMissing(defaultProvider: cfg.defaultProvider) {
            FileHandle.standardError.write(Data("No provider is set up yet — choose one to get started.\n\n".utf8))
            var login = try Auth.Login.parse([])
            // First run: make whatever they pick the default, so the next bare
            // `lingcode` just works (no "make default? [y/N]" to fumble).
            login.forceDefault = true
            try login.run()
            FileHandle.standardError.write(Data("\n".utf8))
            // Pick up the default-provider change the picker wrote.
            cfg = ConfigStore.load()
        }

        // Anonymous heartbeat. Fire-and-forget. No-op if user opted out via
        // `lingcode telemetry off` or if a heartbeat already went out today.
        Task.detached { await TelemetryClient.shared.sendHeartbeatIfDue(version: CLIVersion.current) }

        // Provider routing: non-claude providers use the OpenAI-compatible REPL
        // (text-only, no tools/MCP/hooks). Only `claude` goes through the Agent bridge.
        let selectedProvider = (provider ?? cfg.defaultProvider).lowercased()

        // SessionStart hook fires before provider dispatch. SessionEnd fires before
        // `await session.shutdown()` at the end of run(). codex hand-off (early
        // return below) doesn't fire SessionEnd — codex owns its own lifecycle.
        let _sessionModel = model ?? "default"
        let _sessionId = await SessionLifecycleHook.fireStart(
            command: "repl",
            provider: selectedProvider,
            model: _sessionModel,
            cwd: cwd
        )
        SessionLifecycleHook.installSignalHandlers(
            sessionId: _sessionId,
            provider: selectedProvider,
            model: _sessionModel,
            cwd: cwd,
            turnCountProvider: { 0 }
        )

        // `deepseek-claude` rides the Claude bridge — same Agent SDK, tool
        // loop, sessions, hooks — but pointed at DeepSeek's Anthropic-compat
        // endpoint with the user's DeepSeek key. Trade-off: MCP servers and
        // image attachments don't work (DeepSeek's compat layer ignores them).
        let isDeepSeekClaude = (selectedProvider == "deepseek-claude")
        // `lingmodel` also rides the Claude bridge, but pointed at our
        // hosted proxy. Auth via the user's LingCode CLI token; routing
        // (V4-Flash vs V4-Pro) decided server-side from the model id.
        let isLingModel = (selectedProvider == "lingmodel")

        if selectedProvider == "codex" {
            // Hand off to codex's own interactive REPL — it has full tool use,
            // approval prompts, and session state of its own. We just `exec`
            // into it so the user sees codex directly.
            try execCodexRepl(cwd: cwd, model: model, permissionMode: permissionMode, yolo: yolo)
            return
        }
        if selectedProvider != "claude" && !isDeepSeekClaude && !isLingModel {
            let repl = OpenAICompatREPL(
                providerName: selectedProvider,
                cwd: cwd,
                baseURLOverride: baseUrl,
                apiKeyEnvOverride: apiKeyEnv,
                modelOverride: model,
                systemPromptOverride: systemPrompt,
                appendSystemPrompt: appendSystemPrompt,
                claudeMd: claudeMd,
                skillsEnabled: skills,
                outputStyle: outputStyle,
                verbose: verbose,
                initialYolo: yolo,
                initialPermissionMode: permissionMode,
                continueLast: `continue`,
                resumeSessionId: resume,
                mcpEnabled: mcp,
                mcpConfigPath: mcpConfig,
                timeoutFlag: timeout
            )
            try await repl.run()
            return
        }
        let resolvedPermissionMode: String = {
            if yolo { return "bypassPermissions" }
            if let pm = permissionMode { return pm }
            return cfg.defaultPermissionMode
        }()
        let fastModeModel = "claude-opus-4-6"
        var currentModel: String? = claudeModel ?? (fast ? fastModeModel : cfg.defaultClaudeModel)
        if isDeepSeekClaude {
            // The Claude default models (claude-sonnet-4-6 etc) won't resolve
            // on DeepSeek's endpoint. Force a DeepSeek model unless the user
            // already passed one that looks like a deepseek-* alias. The
            // `[1m]` suffix selects DeepSeek's 1M-context variant — per their
            // integration docs, this is the recommended Pro setting.
            if currentModel == nil || currentModel?.hasPrefix("claude") == true {
                currentModel = "deepseek-v4-pro[1m]"
            }
        }
        if isLingModel {
            // bridge.mjs derives its `currentModel` from LINGCODE_CLAUDE_MODEL at
            // startup, or from a later set_model — NEVER from the per-query command
            // (it reads command.model only in the set_model handler). And only a
            // `lingmodel*` tag makes applyProviderEnv swap ANTHROPIC_AUTH_TOKEN to
            // the managed proxy's bearer.
            //
            // Leaving this unset is why every hosted request 401'd regardless of the
            // token: currentModel stayed null, that branch never ran, and the bridge
            // fell through to the restore branch with no proxy bearer. The Mac app
            // (ClaudeCodeAgentService) and LingCodeServer (AgentAskACPHandler) have
            // always pinned a tag here; the CLI was the one surface that didn't.
            if currentModel?.hasPrefix("lingmodel") != true {
                currentModel = LingModelAuth.defaultModelTag
            }
        }
        // --agent <name> resolves before model/tools so the agent can override them.
        let loadedAgent: Subagent?
        if let name = agent, !name.isEmpty {
            guard let a = Subagent.load(name: name, cwd: cwd) else {
                let known = Subagent.list(cwd: cwd)
                let hint = known.isEmpty
                    ? "Place a Markdown file at .claude/agents/<name>.md (or ~/.claude/agents/) with YAML frontmatter."
                    : "Known: \(known.joined(separator: ", "))"
                FileHandle.standardError.write(Data("lingcode: unknown agent '\(name)'. \(hint)\n".utf8))
                throw ExitCode(2)
            }
            loadedAgent = a
            if let m = a.model { currentModel = m }
        } else {
            loadedAgent = nil
        }
        let resolvedModel = currentModel
        let resolvedMaxTurns = maxTurns ?? cfg.defaultMaxTurns

        var parsedAllowedTools  = allowedTools.map  { $0.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) } } ?? []
        let parsedDisallowedTools = disallowedTools.map { $0.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) } } ?? []
        if let err = KnownTools.validate(parsedAllowedTools + parsedDisallowedTools) {
            FileHandle.standardError.write(Data("lingcode: \(err)\n".utf8))
            throw ExitCode(2)
        }
        // Intersect (or replace, if user passed nothing) the allowed-tools list
        // with the agent's. The agent restricts the surface; users still can't
        // grant tools the agent didn't list.
        if let a = loadedAgent, !a.tools.isEmpty {
            parsedAllowedTools = parsedAllowedTools.isEmpty
                ? a.tools
                : parsedAllowedTools.filter { a.tools.contains($0) }
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
            let msg = "lingcode: \(err.description)\n"
            FileHandle.standardError.write(Data(msg.utf8))
            throw ExitCode(1)
        }

        let anthropicKey: String? = {
            if isLingModel {
                if let env = ProcessInfo.processInfo.environment["LINGCODE_CLI_TOKEN"], !env.isEmpty { return env }
                let kAccount = keychainAccount(
                    base: "lingmodel-cli-token",
                    account: CLIEnvironment.resolvedAccount(forProvider: "lingmodel")
                )
                if let kc = try? SecretStore.get(service: keychainService, account: kAccount),
                   !kc.isEmpty { return kc }
                return nil
            }
            if isDeepSeekClaude {
                if let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !env.isEmpty { return env }
                let kAccount = keychainAccount(
                    base: "deepseek-api-key",
                    account: CLIEnvironment.resolvedAccount(forProvider: "deepseek")
                )
                if let kc = try? SecretStore.get(service: keychainService, account: kAccount),
                   !kc.isEmpty { return kc }
                return cfg.deepseekAPIKey
            }
            let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
            if let env = env, !env.isEmpty { return env }
            if let kc = try? SecretStore.get(service: keychainService, account: "anthropic-api-key"),
               !kc.isEmpty {
                return kc
            }
            return cfg.anthropicAPIKey
        }()
        guard let key = anthropicKey, !key.isEmpty else {
            let msg: String
            if isLingModel {
                msg = """
                    lingcode: no LingModel CLI token configured.

                    Sign in once at https://lingcode.dev/cli-token.html to mint one,
                    then run:
                      lingcode auth login --provider lingmodel

                    …and paste the token when prompted.

                    """
            } else if isDeepSeekClaude {
                msg = """
                    lingcode: DEEPSEEK_API_KEY is not set.

                    Set it via:
                      lingcode auth login --provider deepseek
                      export DEEPSEEK_API_KEY=sk-...

                    """
            } else {
                msg = """
                    lingcode: ANTHROPIC_API_KEY is not set.

                    Set it in your shell, keychain, or config:
                      export ANTHROPIC_API_KEY=sk-ant-...
                      lingcode auth set anthropic sk-ant-...
                      lingcode config set anthropic-api-key sk-ant-...

                    """
            }
            FileHandle.standardError.write(Data(msg.utf8))
            throw ExitCode(1)
        }

        // Preflight the hosted token. A LingModel credential is server-side state
        // that can be revoked out from under this machine (expiry, explicit revoke,
        // or the active-token cap retiring the oldest), so "we found one" is not
        // "it works". Without this the first prompt of the session is spent
        // discovering that, and the failure surfaces as a raw proxy 401 with no
        // recovery path. ~250ms against a route that costs no quota.
        //
        // Deliberately NOT fatal: /login can fix it from inside the session now,
        // and a network blip must not stop the REPL from starting.
        if isLingModel {
            switch LingModelAuth.probe(token: key) {
            case .rejected:
                let warning = """
                    ⚠ Your LingModel token was rejected by the server (expired, revoked, or \
                    retired by the active-token cap).
                      Every prompt will fail with a 401 until it's replaced. Type /login to fix it here, \
                    or mint a new token at \(LingModelAuth.mintURL).

                    """
                FileHandle.standardError.write(Data(
                    ANSI.styled(warning, ANSI.yellow, fd: STDERR_FILENO).utf8
                ))
            case .valid, .rateLimited, .unreachable:
                // .unreachable says nothing about the token — stay quiet rather
                // than crying wolf on an offline start.
                break
            }
        }

        let mcpServers = mcp
            ? mergingCloudMCP(MCPConfig.load(cwd: cwd, overridePath: mcpConfig), cwd: cwd)
            : [:]
        let hooks = HooksConfig.load(cwd: cwd)
        let expandedAddDirs = addDir.map { ($0 as NSString).expandingTildeInPath }

        var currentMode = BridgePermissionMode(rawValue: resolvedPermissionMode) ?? .default
        let baseDecider: any PermissionDecider = yolo
            ? AllowAllPermissionDecider()
            : TTYPermissionDecider()
        // Outermost layer: built-in security tripwires fire even under --yolo.
        let decider: any PermissionDecider = HardcodedDenyDecider(baseDecider)

        // Weave output-style body into the bridge's appendSystemPrompt so the
        // Claude path sees styles the same way the OpenAI-compat path does.
        let mergedAppendSystemPrompt: String? = {
            let styleSuffix: String
            if let style = OutputStyles.resolve(name: outputStyle, cwd: cwd) {
                styleSuffix = OutputStyles.systemPromptSuffix(for: style)
            } else {
                if let requested = outputStyle, !requested.isEmpty {
                    FileHandle.standardError.write(Data(
                        "lingcode: output style '\(requested)' not found — falling back to default.\n".utf8
                    ))
                }
                styleSuffix = ""
            }
            let agentSuffix = loadedAgent.map { "\n\n" + $0.body } ?? ""
            switch (appendSystemPrompt, styleSuffix.isEmpty) {
            case (nil, true):          return agentSuffix.isEmpty ? nil : agentSuffix
            case (nil, false):         return styleSuffix + agentSuffix
            case (let base?, true):    return base + agentSuffix
            case (let base?, false):   return base + styleSuffix + agentSuffix
            }
        }()

        var bridgeExtraEnv: [String: String] = [:]
        if isLingModel {
            // Hosted proxy at lingcode.dev — auth via the user's CLI token,
            // routing to hosted Standard / Advanced tiers from bridge model ids
            // (server may still downgrade by plan). The proxy accepts x-api-key (which the Anthropic
            // SDK sends from ANTHROPIC_API_KEY) and treats it as bearer
            // when it starts with the lcat_ prefix.
            bridgeExtraEnv["ANTHROPIC_BASE_URL"] = LingModelAuth.inferenceBaseURL
            // LINGCODE_PROXY_* is what arms the bridge's `applyProviderEnv` LingModel
            // branch. Without them `proxyBaseURL` is null, that branch is skipped, and
            // every set_model falls through to the restore branch that reinstates the
            // ORIGINAL spawn-time key — which makes a live `/login` silently no-op.
            // The Mac app has always set these (ClaudeCodeAgentService.swift); the CLI
            // not doing so was the only reason the two paths differed.
            bridgeExtraEnv["LINGCODE_PROXY_BASE_URL"] = LingModelAuth.inferenceBaseURL
            bridgeExtraEnv["LINGCODE_PROXY_AUTH_TOKEN"] = key
            // The tag pinned above. This is what actually arms the proxy branch —
            // the model in the query command is ignored by the bridge.
            bridgeExtraEnv["LINGCODE_CLAUDE_MODEL"] = resolvedModel ?? LingModelAuth.defaultModelTag
            // Default to LingModel Standard (`lingmodel-standard`; legacy `lingmodel-fast` still works) unless --model overrides.
            // The bridge maps tags to upstream ids (e.g. kimi-k2.5 / kimi-k2.6 for hosted tiers).
            bridgeExtraEnv["ANTHROPIC_DEFAULT_OPUS_MODEL"]   = "lingmodel-advanced"
            bridgeExtraEnv["ANTHROPIC_DEFAULT_SONNET_MODEL"] = "lingmodel-standard"
            bridgeExtraEnv["ANTHROPIC_DEFAULT_HAIKU_MODEL"]  = "lingmodel-standard"
            bridgeExtraEnv["CLAUDE_CODE_SUBAGENT_MODEL"]     = "lingmodel-standard"
        }
        if isDeepSeekClaude {
            // Mirrors DeepSeek's official integration guide for Claude Code.
            // ANTHROPIC_AUTH_TOKEN is what their compat layer expects (rather
            // than ANTHROPIC_API_KEY); the *_DEFAULT_*_MODEL vars catch
            // internal calls Claude Code makes that ask for "opus"/"sonnet"
            // /"haiku" and re-route them onto DeepSeek model names. Subagent
            // calls go to flash to keep cost down.
            bridgeExtraEnv["ANTHROPIC_BASE_URL"] = "https://api.deepseek.com/anthropic"
            bridgeExtraEnv["ANTHROPIC_AUTH_TOKEN"] = key
            bridgeExtraEnv["ANTHROPIC_MODEL"] = "deepseek-v4-pro[1m]"
            bridgeExtraEnv["ANTHROPIC_DEFAULT_OPUS_MODEL"] = "deepseek-v4-pro[1m]"
            bridgeExtraEnv["ANTHROPIC_DEFAULT_SONNET_MODEL"] = "deepseek-v4-pro[1m]"
            bridgeExtraEnv["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = "deepseek-v4-flash"
            bridgeExtraEnv["CLAUDE_CODE_SUBAGENT_MODEL"] = "deepseek-v4-flash"
            bridgeExtraEnv["CLAUDE_CODE_EFFORT_LEVEL"] = "max"
        }
        let bridgeConfig = AgentBridgeConfiguration(
            nodePath: nodePath,
            resources: resources,
            workingDirectory: cwd,
            permissionMode: currentMode,
            maxTurns: resolvedMaxTurns,
            modelOverride: resolvedModel,
            claudeBinaryPath: ClaudeBinaryResolver.resolve(),
            anthropicAPIKey: key,
            extraEnvironment: bridgeExtraEnv,
            mcpServers: mcpServers,
            systemPrompt: systemPrompt,
            appendSystemPrompt: mergedAppendSystemPrompt,
            additionalDirectories: expandedAddDirs,
            thinking: thinking
        )

        // Visible startup breadcrumb. The bridge spawns a Node subprocess and
        // can take a few seconds (cold Node, SDK init, network handshake);
        // without this line `lingcode` looks dead until .ready arrives.
        FileHandle.standardError.write(Data(
            ANSI.styled("Starting agent bridge…\n", ANSI.dim, fd: STDERR_FILENO).utf8
        ))

        let session = AgentBridgeSession(configuration: bridgeConfig, decider: decider)

        // Subscribe BEFORE start() — the bridge can emit `ready` within
        // milliseconds of spawn, and if the continuation isn't attached yet
        // the event is dropped and the iterator below hangs forever.
        let stream = await session.events()
        var iterator = stream.makeAsyncIterator()

        try await session.start()

        var currentSessionId: String? = resolveInitialSessionId(cwd: cwd)

        // SIGINT handler: cancel active query instead of killing process
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let queryActive = AtomicBool(false)
        // Deadline for the "press again" window, as a reference-date interval.
        // Idle Ctrl-C used to exit(130) on the FIRST press, so one stray keystroke
        // at the prompt ended the session and took the transcript with it. The
        // terminal is never in raw mode for the main prompt (only TTYIO's pickers
        // use termios), so every Ctrl-C reaches this handler — there is no line
        // editor upstream to absorb an accidental press.
        let exitArmedUntil = AtomicExitDeadline()
        // 5s, not 2s. The window has to cover a human reading "Press Ctrl-C again"
        // and then reaching for the key — 2s expired mid-reach, so the second press
        // re-armed instead of exiting and the REPL demanded a third. Automated
        // tests never caught it because they fire the presses microseconds apart.
        let ctrlCGraceSeconds: TimeInterval = 5
        signal(SIGINT, SIG_IGN)
        sigintSource.setEventHandler {
            if queryActive.value {
                Task { await session.cancel() }
                // Cancelling is not a step toward exiting: returning to the prompt
                // starts a fresh window, so cancel-then-stray-Ctrl-C can't quit.
                exitArmedUntil.clear()
            } else if exitArmedUntil.isArmed(at: Date().timeIntervalSinceReferenceDate) {
                Task {
                    await session.shutdown()
                    // ParsableCommand has its own static `exit`, so bare `exit`
                    // resolves to the wrong thing inside a command type. Use the
                    // platform libc namespace explicitly.
                    #if canImport(Darwin)
                    Darwin.exit(130)
                    #else
                    Glibc.exit(130)
                    #endif
                }
            } else {
                exitArmedUntil.arm(until: Date().timeIntervalSinceReferenceDate + ctrlCGraceSeconds)
                let notice = ANSI.styled(
                    "\nPress Ctrl-C again to exit (or /quit)\n", ANSI.yellow, fd: STDERR_FILENO
                )
                FileHandle.standardError.write(Data(notice.utf8))
            }
        }
        sigintSource.resume()

        // Drain until .ready
        readyLoop: while let event = try await iterator.next() {
            if case .ready = event { break readyLoop }
        }

        let bannerProviderLabel: String
        if isLingModel { bannerProviderLabel = "lingmodel" }
        else if isDeepSeekClaude { bannerProviderLabel = "claude→deepseek" }
        else { bannerProviderLabel = "claude" }
        printWelcomeBanner(model: resolvedModel, colorEnabled: colorOn, providerLabel: bannerProviderLabel)
        if !mcpServers.isEmpty {
            let names = mcpServers.keys.sorted().joined(separator: ", ")
            FileHandle.standardError.write(Data(
                ANSI.styled("MCP: \(names)\n", ANSI.dim, fd: STDERR_FILENO).utf8
            ))
        }

        var isFirstTurn = true
        var turnCount = 0
        let tty = TTYIO.open()
        let mdRenderer = MarkdownRenderer(enabled: colorOn)

        // Raw-mode line editor: arrow-key history, Home/End, Tab completion, bracket-paste.
        // Requires stdin to be a TTY; falls back to plain readLine() when piped.
        let stdinIsTTY = isatty(STDIN_FILENO) != 0
        let lineEditor: LineEditor? = stdinIsTTY
            ? LineEditor(inFd: STDIN_FILENO, outFd: STDOUT_FILENO) { buffer, _ in
                Repl.completions(forBuffer: buffer, cwd: cwd)
            }
            : nil

        // Shift+Tab cycles permission mode mid-session: default → acceptEdits → plan.
        // Skips dontAsk/bypassPermissions — those are explicit choices, not part of the rotation.
        lineEditor?.onShiftTab = { [session] in
            let next: BridgePermissionMode
            switch currentMode {
            case .default:     next = .acceptEdits
            case .acceptEdits: next = .plan
            case .plan:        next = .default
            default:           next = .default
            }
            currentMode = next
            Task { try? await session.setPermissionMode(next) }
            return "permission mode → \(next.rawValue)"
        }

        // Cumulative token tracking
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalCacheTokens = 0
        var totalCostUsd = 0.0

        // Optional user-configured status line (shell command in .claude/settings.json).
        let statusLineConfig = StatusLine.load(cwd: cwd)
        var statusLineCache: String? = nil

        // Full transcript for /export
        var transcript: [(role: String, text: String)] = []
        // Set by `/fork` — the next send branches the current session into a new
        // sessionId, leaving the original intact for later /resume. Reset after use.
        var forkPending = false

        defer {
            tty?.close()
            sigintSource.cancel()
        }

        // REPL loop
        while true {
            // Assemble possibly-multi-line input. Trailing `\` continues; LineEditor handles arrow keys.
            var assembled = ""
            var firstLine = true
            readOneInput: while true {
                if firstLine {
                    let dash = buildDashboardLine(
                        cwd: cwd,
                        mode: currentMode,
                        model: currentModel,
                        totalInputTokens: totalInputTokens,
                        totalOutputTokens: totalOutputTokens
                    )
                    if !dash.isEmpty {
                        FileHandle.standardOutput.write(Data("\(dash)\n".utf8))
                    }
                }
                let promptStr: String = firstLine
                    ? buildPrompt(sessionId: currentSessionId, turnCount: turnCount, totalCost: totalCostUsd, statusLineSuffix: statusLineCache)
                    : ANSI.styled("  … ", ANSI.dim, fd: STDOUT_FILENO)

                let chunk: String?
                if let editor = lineEditor {
                    // Caller prints the prompt; editor draws over it as the user types.
                    FileHandle.standardOutput.write(Data(promptStr.utf8))
                    switch editor.readLine(prompt: promptStr) {
                    case .line(let s):      chunk = s
                    case .eof:              chunk = nil
                    case .interrupted(let hadInput):
                        // The SIGINT handler installed above NEVER sees a Ctrl-C
                        // typed at this prompt: LineEditor puts the terminal in raw
                        // mode (ISIG cleared), so the keystroke arrives as byte 0x03
                        // and lands here instead. That handler only fires for piped
                        // stdin. Mirror its double-tap policy so a real terminal
                        // behaves the same — previously this branch just redrew the
                        // prompt, so Ctrl-C could never exit the REPL at all.
                        assembled = ""
                        firstLine = true
                        // Discarding typed text is a complete action on its own; it
                        // must not also count as a step toward quitting, or clearing
                        // a line twice would drop the user out of the session.
                        if hadInput {
                            exitArmedUntil.clear()
                            continue readOneInput
                        }
                        let now = Date().timeIntervalSinceReferenceDate
                        if exitArmedUntil.isArmed(at: now) {
                            await session.shutdown()
                            return
                        }
                        exitArmedUntil.arm(until: now + ctrlCGraceSeconds)
                        FileHandle.standardError.write(Data(ANSI.styled(
                            "Press Ctrl-C again to exit (or /quit)\n", ANSI.yellow, fd: STDERR_FILENO
                        ).utf8))
                        continue readOneInput
                    }
                } else if let tty = tty {
                    tty.write(promptStr)
                    chunk = tty.readLine()
                } else {
                    Swift.print(promptStr, terminator: "")
                    fflush(stdout)
                    chunk = Swift.readLine(strippingNewline: true)
                }

                guard let line = chunk else {
                    if assembled.isEmpty { await session.shutdown(); return }
                    break
                }
                if line.hasSuffix("\\") {
                    assembled += String(line.dropLast()) + "\n"
                    firstLine = false
                    continue
                }
                assembled += line
                break
            }

            let input = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
            let _dbg = ProcessInfo.processInfo.environment["LINGCODE_DEBUG_BRIDGE"] == "1"
            if _dbg { FileHandle.standardError.write(Data("[repl] input=\(input)\n".utf8)) }
            guard !input.isEmpty else { continue }
            // Submitting a line is unambiguous intent to keep working, so a stale
            // arm must not survive it and let a single later Ctrl-C quit outright.
            exitArmedUntil.clear()
            lineEditor?.addHistory(input)

            // /compact is special: it sends a query and must drain events like a normal turn.
            let isCompact = input.lowercased().hasPrefix("/compact")

            // Custom slash commands: /project:name, /user:name, or /<name>
            // Resolved to a markdown/txt prompt file under .claude/commands/.
            var customPromptBody: String? = nil
            if input.hasPrefix("/") && !isCompact {
                let token = String(input.dropFirst()).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                let rest  = input.dropFirst(1 + token.count).trimmingCharacters(in: .whitespacesAndNewlines)
                // Only attempt a custom-command lookup for `project:` / `user:` / unknown bare names.
                let looksCustom = token.contains(":")
                    || !builtinSlashCommands.contains(token.lowercased())
                if looksCustom,
                   let body = CustomSlashCommands.resolve(token, cwd: cwd) {
                    customPromptBody = rest.isEmpty ? body : body + "\n\n" + rest
                }
            }

            if input.hasPrefix("/") && !isCompact && customPromptBody == nil {
                let shouldContinue = await handleSlashCommand(
                    input,
                    session: session,
                    cwd: cwd,
                    currentSessionId: &currentSessionId,
                    currentModel: &currentModel,
                    currentMode: &currentMode,
                    forkPending: &forkPending,
                    totalInputTokens: totalInputTokens,
                    totalOutputTokens: totalOutputTokens,
                    totalCacheTokens: totalCacheTokens,
                    totalCostUsd: totalCostUsd,
                    transcript: transcript,
                    colorEnabled: colorOn,
                    tty: tty
                )
                if !shouldContinue { break }
                continue
            }

            let wrapped: String
            if isCompact {
                guard currentSessionId != nil else {
                    Swift.print("no active session to compact")
                    continue
                }
                Swift.print(ANSI.styled("compacting conversation…", ANSI.dim, fd: STDOUT_FILENO))
                wrapped = "Please summarise our conversation so far into a concise context summary, then continue from that summary. Keep all important decisions, file edits, and context. After summarising, acknowledge that you are ready to continue."
            } else if let custom = customPromptBody {
                wrapped = custom
                if isFirstTurn { isFirstTurn = false }
            } else if isFirstTurn && (claudeMd || skills) {
                let md = claudeMd ? ProjectContext.loadClaudeMd(startingAt: cwd) : nil
                let loadedSkills = skills ? SkillsContext.loadSkills(cwd: cwd) : []
                wrapped = SkillsContext.wrap(
                    prompt: ProjectContext.wrap(prompt: input, claudeMd: md),
                    skills: loadedSkills
                )
                isFirstTurn = false
            } else {
                wrapped = input
            }

            do {
                transcript.append((role: "user", text: input))
                if _dbg { FileHandle.standardError.write(Data("[repl] running hooks\n".utf8)) }
                for cmd in hooks.commands(for: .userPromptSubmit) {
                    await runHook(cmd, prompt: input, cwd: cwd)
                }
                if _dbg { FileHandle.standardError.write(Data("[repl] calling session.send wrapped=\(wrapped.count) chars\n".utf8)) }
                let agentDefs: [String: [String: String]] = (agentMode == .full && loadedAgent != nil)
                    ? [loadedAgent!.name: loadedAgent!.toBridgeDefinition()]
                    : [:]
                let agentNameForSend = (agentMode == .full) ? loadedAgent?.name : nil
                _ = try await session.send(
                    prompt: wrapped,
                    resumeSessionId: currentSessionId,
                    allowedTools: parsedAllowedTools,
                    disallowedTools: parsedDisallowedTools,
                    forkSession: forkPending,
                    agentDefinitions: agentDefs,
                    agentName: agentNameForSend
                )
                if forkPending {
                    forkPending = false
                    if !CLIEnvironment.quiet {
                        FileHandle.standardError.write(Data("(forked — new session ID will print after this turn)\n".utf8))
                    }
                }
                if _dbg { FileHandle.standardError.write(Data("[repl] session.send returned\n".utf8)) }
            } catch {
                printError("failed to send: \(error)", colorEnabled: colorOn)
                continue
            }

            queryActive.set(true)
            var lastWasNewline = true
            var turnInputTokens = 0
            var turnOutputTokens = 0
            var turnCacheTokens = 0
            var lastToolName = ""
            var lastToolInput = ""
            var turnRetryAttempt = 0
            let turnMaxRetries = 5

            // Spinner shown during any "waiting for the model / waiting for the
            // tool" gap. Restarted between events so users see motion the whole
            // time something off-screen is happening.
            //
            // Lifecycle in this loop:
            //   send → start (thinking…)
            //     .assistantText / .toolUse / .permissionRequested → stop
            //     .permissionResolved (allow) → start (running tool…)
            //     .toolResult → start (thinking…) — model now processes it
            //     .queryFinished → stop
            var spinnerTask: Task<Void, Never>? = nil
            func startSpinner(_ label: String) {
                guard !CLIEnvironment.quiet, colorOn else { return }
                spinnerTask?.cancel()
                spinnerTask = Task {
                    let frames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
                    var i = 0
                    while !Task.isCancelled {
                        // A /dev/tty permission prompt is on screen. Our \r would
                        // overwrite the question the user is being asked, so clear
                        // our line once and stay quiet until they've answered.
                        if TTYPromptState.isActive {
                            // Write NOTHING. The decider clears the line
                            // itself before drawing the prompt; a clear
                            // from here lands after it and erases the
                            // question the user is reading.
                            try? await Task.sleep(nanoseconds: 80_000_000)
                            continue
                        }
                        let line = "\r\(frames[i % frames.count]) \(label)"
                        FileHandle.standardError.write(Data(ANSI.styled(line, ANSI.dim, fd: STDERR_FILENO).utf8))
                        i += 1
                        try? await Task.sleep(nanoseconds: 80_000_000)
                    }
                    // Erase the last spinner frame when the task ends — unless a
                    // /dev/tty permission prompt is on screen, in which case this
                    // \r + clear would wipe the question the user is answering.
                    if !TTYPromptState.isActive {
                        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
                    }
                }
            }
            func stopSpinner() {
                spinnerTask?.cancel()
                spinnerTask = nil
            }
            startSpinner("thinking…")

            drainLoop: while let event = try await iterator.next() {
                if json { Self.emitReplJSON(event: event); }
                switch event {
                case .assistantText(let text):
                    if json { continue }
                    stopSpinner()
                    let rendered = mdRenderer.process(text)
                    FileHandle.standardOutput.write(Data(rendered.utf8))
                    lastWasNewline = text.hasSuffix("\n")
                    // Accumulate assistant text for /export; one entry per turn below.
                    if let last = transcript.last, last.role == "assistant" {
                        transcript[transcript.count - 1].text += text
                    } else {
                        transcript.append((role: "assistant", text: text))
                    }

                case .toolUse(let name, let inputJSON, _):
                    stopSpinner()
                    // Flush any buffered markdown before tool narration
                    let flushed = mdRenderer.flush()
                    if !flushed.isEmpty { FileHandle.standardOutput.write(Data(flushed.utf8)) }

                    lastToolName = name
                    lastToolInput = inputJSON

                    // Fire PreToolUse hooks
                    for cmd in hooks.commands(for: .preToolUse, toolName: name) {
                        await runHook(cmd, toolName: name, toolInput: inputJSON, cwd: cwd)
                    }

                    // Show diff for file edits
                    let diffLine = formatToolUseLine(name: name, inputJSON: inputJSON, verbose: verbose, colorEnabled: colorOn)
                    let prefix = lastWasNewline ? "" : "\n"
                    FileHandle.standardError.write(Data((prefix + diffLine + "\n").utf8))
                    lastWasNewline = true

                case .toolResult(let content, let isError, _):
                    // Fire PostToolUse hooks
                    for cmd in hooks.commands(for: .postToolUse, toolName: lastToolName) {
                        await runHook(cmd, toolName: lastToolName, toolInput: lastToolInput, toolResult: content, cwd: cwd)
                    }

                    let label = isError
                        ? ANSI.styled("✗", ANSI.red, fd: STDERR_FILENO)
                        : ANSI.styled("✓", ANSI.green, fd: STDERR_FILENO)
                    let shown: String
                    if verbose {
                        shown = content
                    } else {
                        let trimmed = content.count > 200 ? String(content.prefix(200)) + "…" : content
                        shown = trimmed.replacingOccurrences(of: "\n", with: " ")
                    }
                    let line = "\(label) \(shown)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                    lastWasNewline = true
                    // Tool finished — model now processes the result.
                    startSpinner("thinking…")

                case .tokenUsage(let input, let output, let cacheRead, let cacheCreation):
                    turnInputTokens  += input
                    turnOutputTokens += output
                    // Cache read + cache creation both occupy context window
                    // slots and need to be summed for accurate ctx% display.
                    turnCacheTokens  += cacheRead + cacheCreation

                case .permissionRequested:
                    stopSpinner()
                case .permissionResolved(_, let behavior):
                    // If approved, the bridge is about to invoke the tool; show motion.
                    if behavior == "allow" || behavior == "alwaysAllow" {
                        startSpinner("running tool…")
                    }

                case .queryFinished(let sid, _, _):
                    stopSpinner()
                    // Flush buffered markdown
                    let flushed = mdRenderer.flush()
                    if !flushed.isEmpty { FileHandle.standardOutput.write(Data(flushed.utf8)) }
                    if !lastWasNewline {
                        FileHandle.standardOutput.write(Data("\n".utf8))
                    }

                    // Telemetry: per-turn model event (anonymous, opt-out via
                    // `lingcode telemetry off`). Use session id as the
                    // conversation key so multi-turn sessions group together.
                    let providerLabel: String = isLingModel ? "lingmodel" : (isDeepSeekClaude ? "claude-via-deepseek" : "claude")
                    let convId = sid ?? currentSessionId ?? "unknown"
                    let snapshotModel = resolvedModel
                    let snapshotIn = turnInputTokens
                    let snapshotOut = turnOutputTokens
                    Task.detached {
                        await TelemetryClient.shared.sendModelEvent(
                            provider: providerLabel,
                            model: snapshotModel,
                            conversationId: convId,
                            promptTokens: snapshotIn,
                            completionTokens: snapshotOut,
                            latencyMs: nil
                        )
                    }

                    // Token / cost summary
                    totalInputTokens  += turnInputTokens
                    totalOutputTokens += turnOutputTokens
                    totalCacheTokens  += turnCacheTokens
                    let turnCostValue = rawCost(input: turnInputTokens, output: turnOutputTokens, cache: turnCacheTokens)
                    totalCostUsd += turnCostValue
                    turnCount += 1
                    if colorOn && (turnInputTokens + turnOutputTokens) > 0 {
                        let summary = ANSI.styled(
                            "↑ \(format(turnInputTokens)) ↓ \(format(turnOutputTokens)) tokens (~\(formatCost(turnCostValue)))\n",
                            ANSI.dim, fd: STDERR_FILENO
                        )
                        FileHandle.standardError.write(Data(summary.utf8))
                    }

                    if let sid = sid, !sid.isEmpty {
                        currentSessionId = sid
                        SessionStore.save(sessionId: sid, forCwd: cwd, promptPreview: String(input.prefix(80)))
                    }

                    // Stop hooks
                    for cmd in hooks.commands(for: .stop) {
                        await runHook(cmd, cwd: cwd)
                    }

                    // Refresh status line (user-configurable shell command).
                    if let cfg = statusLineConfig {
                        let payload = StatusLine.Payload(
                            sessionId: currentSessionId ?? "",
                            model: claudeModel ?? ConfigStore.load().defaultClaudeModel ?? "claude",
                            turn: turnCount,
                            inputTokens: totalInputTokens,
                            outputTokens: totalOutputTokens,
                            costUSD: totalCostUsd,
                            cwd: cwd.path
                        )
                        statusLineCache = await StatusLine.render(config: cfg, payload: payload, cwd: cwd)
                    }

                    queryActive.set(false)
                    break drainLoop

                case .queryFailed(let m):
                    // Rate-limit / overloaded → back off and retry transparently.
                    if isRateLimitError(m) && turnRetryAttempt < turnMaxRetries {
                        turnRetryAttempt += 1
                        let wait = Int(min(60.0, pow(2.0, Double(turnRetryAttempt))))
                        let notice = ANSI.styled(
                            "rate limited (attempt \(turnRetryAttempt)/\(turnMaxRetries)) — retrying in \(wait)s…\n",
                            ANSI.yellow, fd: STDERR_FILENO
                        )
                        FileHandle.standardError.write(Data(notice.utf8))
                        await rateLimitBackoffSleep(attempt: turnRetryAttempt)
                        do {
                            _ = try await session.send(
                                prompt: wrapped,
                                resumeSessionId: currentSessionId,
                                allowedTools: parsedAllowedTools,
                                disallowedTools: parsedDisallowedTools
                            )
                        } catch {
                            printError("retry failed: \(error)", colorEnabled: colorOn)
                            queryActive.set(false)
                            break drainLoop
                        }
                        continue drainLoop
                    }
                    let flushed = mdRenderer.flush()
                    if !flushed.isEmpty { FileHandle.standardOutput.write(Data(flushed.utf8)) }
                    printError("query failed: \(m)", colorEnabled: colorOn)
                    queryActive.set(false)
                    break drainLoop

                case .queryCancelled:
                    let flushed = mdRenderer.flush()
                    if !flushed.isEmpty { FileHandle.standardOutput.write(Data(flushed.utf8)) }
                    let msg = ANSI.styled("\n(cancelled — continue typing or /quit to exit)\n", ANSI.yellow, fd: STDERR_FILENO)
                    FileHandle.standardError.write(Data(msg.utf8))
                    queryActive.set(false)
                    break drainLoop

                case .bridgeError(let m, _):
                    printError("bridge error: \(m)\n\(retryHint(for: m))", colorEnabled: colorOn)

                case .bridgeExited(let code, let stderr):
                    queryActive.set(false)
                    if code != 0 {
                        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        let line = "bridge exited (\(code))\(detail.isEmpty ? "" : ": \(detail)")\n\(retryHint(for: detail))"
                        printError(line, colorEnabled: colorOn)
                    }
                    throw ExitCode(code != 0 ? 1 : 0)

                case .ready, .queryStarted, .awaitingFirstMessage:
                    break

                case .userInputRequested(let request):
                    // Render the option picker inline and read the choice from stdin.
                    //
                    // This used to decline unconditionally, which dead-ended any skill
                    // that asks a question — `ship-ios-app` stops on "API key or
                    // Apple ID?" and the whole turn was abandoned at that point. The
                    // bridge is parked in canUseTool waiting for us, so a plain
                    // readLine() here is safe: nothing else is consuming stdin.
                    //
                    // Non-interactive stdin (piped input, CI) still declines — there
                    // is nobody to ask, and blocking on a read that never returns
                    // would hang the run.
                    if isatty(fileno(stdin)) == 0 {
                        let q = request.questions.first?.question ?? "a multiple-choice question"
                        FileHandle.standardError.write(Data(
                            "(Claude asked: \(q) — stdin is not a terminal; declining)\n".utf8
                        ))
                        await session.respondToUserInput(requestId: request.id, answers: [:], cancelled: true)
                        break
                    }

                    var answers: [String: String] = [:]
                    var abandoned = false
                    for question in request.questions {
                        Swift.print("")
                        Swift.print(question.header.isEmpty ? "Claude asks:" : "\(question.header):")
                        Swift.print("  \(question.question)")
                        for (i, opt) in question.options.enumerated() {
                            Swift.print("    \(i + 1)) \(opt.label)")
                            if !opt.description.isEmpty {
                                Swift.print("       \(opt.description)")
                            }
                        }
                        let hint = question.multiSelect
                            ? "  Choose (comma-separated numbers), type your own, or Enter to skip: "
                            : "  Choose a number, type your own, or Enter to skip: "
                        FileHandle.standardOutput.write(Data(hint.utf8))
                        guard let raw = readLine(strippingNewline: true) else { abandoned = true; break }
                        let entry = raw.trimmingCharacters(in: .whitespaces)
                        if entry.isEmpty { abandoned = true; break }

                        // Numbers map to option labels; anything else is passed through
                        // verbatim, which is what the "Other" affordance amounts to.
                        let picked = entry
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .map { token -> String in
                                if let n = Int(token), n >= 1, n <= question.options.count {
                                    return question.options[n - 1].label
                                }
                                return token
                            }
                        answers[question.question] = picked.joined(separator: ", ")
                    }

                    if abandoned || answers.isEmpty {
                        FileHandle.standardError.write(Data("(skipped)\n".utf8))
                        await session.respondToUserInput(requestId: request.id, answers: [:], cancelled: true)
                    } else {
                        await session.respondToUserInput(requestId: request.id, answers: answers, cancelled: false)
                    }

                case .sdkMessage, .subagentStarted, .subagentFinished, .sessionRecovered,
                     .memoryWriteRequest, .skillWriteRequest, .sessionSearchRequest, .terminalReadRequest:
                    break
                }
            }
            // Backstop: every `break drainLoop` above clears this, but the loop can
            // also end by the event stream simply running dry — no queryCompleted,
            // queryFailed, queryCancelled or bridgeExited to trigger those. That
            // path left the flag TRUE while the user sat back at an idle prompt, and
            // a stuck-true flag routes Ctrl-C into the cancel branch forever: it
            // cancels a query that isn't running, prints nothing, and never exits,
            // so Ctrl-C stops quitting the REPL entirely. Reset unconditionally on
            // the way back to the prompt.
            queryActive.set(false)
        }

        await session.shutdown()

        await SessionLifecycleHook.fireEnd(
            sessionId: _sessionId,
            provider: selectedProvider,
            model: _sessionModel,
            cwd: cwd,
            turnCount: 0,
            terminatedBy: "completion"
        )
    }

    // MARK: - Slash commands

    /// Push a freshly-minted token into the ALREADY-RUNNING bridge.
    ///
    /// The bridge spawns with its credential in env, so a keychain write alone
    /// would not reach it — the session would keep 401ing until relaunch. Its
    /// `set_model` handler reassigns `proxyAuthToken` and re-runs
    /// `applyProviderEnv`, which is the whole mechanism; we just have to send it.
    ///
    /// The model must be sent too: the bridge assigns `currentModel` from
    /// `command.model` unconditionally, so omitting it would null out the model
    /// as a side effect of re-authing.
    /// Returns the model tag actually pushed, so the caller can keep its own
    /// `currentModel` in sync with what the bridge now holds. nil on failure.
    private func pushLiveToken(
        _ token: String,
        session: AgentBridgeSession,
        model: String?,
        colorEnabled: Bool
    ) async -> String? {
        // Must run even when the REPL has no explicit model. An earlier version
        // bailed in that case, assuming the next prompt would pick the new token up
        // from the keychain — it does not. The bridge subprocess is already running
        // with the OLD credential in its env and never re-reads the keychain, so
        // skipping the push left the session 401ing behind a "✓ saved". Fall back to
        // the tag the bridge resolves to anyway; `isLingModelTag` must accept it or
        // `applyProviderEnv` skips the branch that swaps the token.
        let target = (model?.isEmpty == false) ? model! : LingModelAuth.defaultModelTag
        do {
            try await session.setModel(target, proxyAuthToken: token)
            Swift.print(ANSI.styled("✓ session re-authed — keep going, no restart needed", ANSI.green, fd: STDOUT_FILENO))
            return target
        } catch {
            // Saved but not hot-swapped: say so precisely. Claiming success here
            // would send the user back into the same 401 loop they just escaped.
            printError("token saved, but this session could not be re-authed live (\(error)) — /quit and relaunch to pick it up", colorEnabled: colorEnabled)
            return nil
        }
    }

    private func handleSlashCommand(
        _ raw: String,
        session: AgentBridgeSession,
        cwd: URL,
        currentSessionId: inout String?,
        currentModel: inout String?,
        currentMode: inout BridgePermissionMode,
        forkPending: inout Bool,
        totalInputTokens: Int,
        totalOutputTokens: Int,
        totalCacheTokens: Int,
        totalCostUsd: Double,
        transcript: [(role: String, text: String)],
        colorEnabled: Bool,
        tty: TTYIO?
    ) async -> Bool {
        let parts = raw.dropFirst().split(separator: " ", maxSplits: 1)
        let cmd = parts.first.map(String.init) ?? ""
        let arg = parts.dropFirst().first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch cmd.lowercased() {
        case "quit", "exit", "q":
            return false

        case "help", "?":
            let help = """

              /model          Show current model + interactive picker (or /model <name|number>)
              /mode <mode>    Change permission mode (default|acceptEdits|plan|dontAsk|bypassPermissions)
              /fast [on|off]  Toggle fast mode (Opus 4.6 flagship); no arg toggles
              /yolo           Bypass all permission prompts
              /compact        Summarise and compress conversation history
              /session        Show current session ID
              /fork           Branch the current session — next message starts a new sessionId
              /resume [id|n]  Resume a past session (no arg → interactive picker)
              /cost           Show cumulative token usage and estimated cost
              /tools          List available built-in tools
              /commands       List available custom slash commands
              /skills         List loaded skills from .claude/skills/
              /agents         List subagents discovered in .claude/agents/
              /output-styles  List output styles (built-in + .claude/output-styles/)
              /doctor         Diagnose the LingCode environment
              /login [token]  Replace the LingModel token and re-auth this session live
              /logout         Remove the stored LingModel token
              /export [path]  Save transcript as markdown (default: ./lingcode-transcript-*.md)
              /init           Generate a CLAUDE.md for the current project
              /reset          Start a fresh conversation (clears session)
              /clear          Clear the screen
              /quit           Exit the session
              /help           Show this help

            Custom slash commands from .claude/commands/<name>.md are invoked as
              /project:<name>, /user:<name>, or bare /<name>.

            Input editor (when stdin is a TTY):
              ↑ / ↓             Recall previous / next input
              ← / → / Home / End Move cursor
              Tab               Complete slash commands
              Trailing `\\`      Continue the input on the next line
              Ctrl-C            Cancel running query; at an idle prompt press twice to exit
              Ctrl-D            Exit on empty line; otherwise delete char

            """
            Swift.print(help)

        case "clear":
            Swift.print("\u{1B}[2J\u{1B}[H", terminator: "")

        case "session":
            if let sid = currentSessionId {
                Swift.print(ANSI.styled("session: \(sid)", ANSI.cyan, fd: STDOUT_FILENO))
            } else {
                Swift.print("no active session")
            }

        case "fork":
            // Branch the current session: the next prompt creates a new sessionId
            // that inherits the resumed transcript. The original session is kept
            // intact for later /resume — useful when you want to try a different
            // direction without losing the path you were on.
            guard currentSessionId != nil else {
                Swift.print("no active session to fork — send a message first, then /fork")
                return true
            }
            forkPending = true
            Swift.print(ANSI.styled("fork primed — your next message will branch into a new sessionId", ANSI.yellow, fd: STDOUT_FILENO))

        case "resume":
            // Interactive picker over recent sessions for this cwd. Saves the user
            // from copy-pasting UUIDs out of `lingcode history`.
            let entries = SessionHistory.loadForCwd(cwd)
            guard !entries.isEmpty else {
                Swift.print("no session history for this directory yet")
                return true
            }
            // If the user passed an arg, treat it as direct session id / index.
            if let raw = arg, !raw.isEmpty {
                if let n = Int(raw), n > 0, n <= entries.count {
                    currentSessionId = entries[n - 1].sessionId
                } else {
                    currentSessionId = raw
                }
                Swift.print(ANSI.styled("resumed session \(currentSessionId ?? "?")", ANSI.cyan, fd: STDOUT_FILENO))
                return true
            }
            guard let tty = tty else {
                Swift.print("usage: /resume <session-id|index>  (no TTY for picker)")
                return true
            }
            let labels = entries.prefix(15).map { e -> String in
                let preview = e.promptPreview.isEmpty ? "(no prompt preview)" : e.promptPreview
                let when = ISO8601DateFormatter().string(from: e.startedAt)
                return "\(when)  \(String(e.sessionId.prefix(8)))  \(preview)"
            }
            guard let idx = tty.pick(prompt: "Resume which session? (↑↓ Enter):", items: labels) else {
                Swift.print("cancelled")
                return true
            }
            currentSessionId = entries[idx].sessionId
            Swift.print(ANSI.styled("resumed session \(currentSessionId!)", ANSI.cyan, fd: STDOUT_FILENO))

        case "cost":
            Swift.print(ANSI.styled(
                "Total: ↑ \(format(totalInputTokens)) ↓ \(format(totalOutputTokens)) tokens (~\(formatCost(totalCostUsd)))",
                ANSI.cyan, fd: STDOUT_FILENO
            ))

        case "reset":
            currentSessionId = nil
            try? await session.resetSession()
            Swift.print(ANSI.styled("session reset — next query starts fresh", ANSI.yellow, fd: STDOUT_FILENO))

        case "yolo":
            try? await session.setPermissionMode(.bypassPermissions)
            currentMode = .bypassPermissions
            Swift.print(ANSI.styled("⚠ permission mode set to bypassPermissions — all tool calls auto-approved", ANSI.yellow, fd: STDOUT_FILENO))

        case "mode":
            guard let newMode = arg, let pm = BridgePermissionMode(rawValue: newMode) else {
                Swift.print("usage: /mode <default|acceptEdits|plan|dontAsk|bypassPermissions>")
                return true
            }
            try? await session.setPermissionMode(pm)
            currentMode = pm
            Swift.print(ANSI.styled("permission mode → \(newMode)", ANSI.cyan, fd: STDOUT_FILENO))

        case "model":
            // No arg → show current + interactive picker.
            // Arg → switch directly (accepts canonical name or picker number).
            let current = currentModel ?? "default (claude-sonnet-4-6)"
            if let raw = arg, !raw.isEmpty {
                // Allow either "claude-opus-4-7" or "1" (index into knownClaudeModels).
                let resolved: String
                if let idx = Int(raw), idx >= 1, idx <= knownClaudeModels.count {
                    resolved = knownClaudeModels[idx - 1].name
                } else {
                    resolved = raw
                }
                try? await session.setModel(resolved)
                currentModel = resolved
                Swift.print(ANSI.styled("model → \(resolved)", ANSI.cyan, fd: STDOUT_FILENO))
            } else {
                Swift.print(ANSI.styled("Current model: \(current)", ANSI.bold, fd: STDOUT_FILENO))
                if let tty = tty {
                    let initialIdx = knownClaudeModels.firstIndex { $0.name == currentModel } ?? 0
                    let labels = knownClaudeModels.map { "\($0.name)  —  \($0.tagline)" }
                    if let chosen = tty.pick(
                        prompt: "Switch model (↑↓ Enter, Ctrl-C to keep):",
                        items: labels,
                        initial: initialIdx
                    ) {
                        let resolved = knownClaudeModels[chosen].name
                        try? await session.setModel(resolved)
                        currentModel = resolved
                        Swift.print(ANSI.styled("model → \(resolved)", ANSI.cyan, fd: STDOUT_FILENO))
                    } else {
                        Swift.print(ANSI.styled("kept \(current)", ANSI.dim, fd: STDOUT_FILENO))
                    }
                }
            }

        case "fast":
            // Toggle between Opus 4.6 (fast mode flagship) and the default
            // Sonnet line. Mirrors Claude Code's /fast UX. arg "on" / "off"
            // forces a direction; no arg toggles.
            let fastModel = "claude-opus-4-6"
            let defaultModel = "claude-sonnet-4-6"
            let want: String
            switch arg?.lowercased() {
            case "on":  want = fastModel
            case "off": want = defaultModel
            default:    want = (currentModel == fastModel) ? defaultModel : fastModel
            }
            try? await session.setModel(want)
            currentModel = want
            let label = (want == fastModel) ? "fast (\(want))" : "default (\(want))"
            Swift.print(ANSI.styled("model → \(label)", ANSI.cyan, fd: STDOUT_FILENO))

        case "tools":
            let tools = [
                "Bash", "Read", "Write", "Edit", "Glob", "Grep",
                "WebFetch", "WebSearch", "Task", "TodoWrite",
                "NotebookEdit",
            ]
            Swift.print(ANSI.styled("Built-in tools:", ANSI.bold, fd: STDOUT_FILENO))
            for t in tools { Swift.print("  \(t)") }
            Swift.print(ANSI.styled("Plus any tools exposed by configured MCP servers.", ANSI.dim, fd: STDOUT_FILENO))

        case "commands":
            let customs = CustomSlashCommands.all(cwd: cwd)
            if customs.isEmpty {
                Swift.print("No custom commands found in .claude/commands/ or ~/.claude/commands/")
            } else {
                Swift.print(ANSI.styled("Custom commands:", ANSI.bold, fd: STDOUT_FILENO))
                for c in customs {
                    let scope = c.source == .project ? "project" : "user"
                    Swift.print("  /\(scope):\(c.name)")
                }
            }

        case "skills":
            let loaded = SkillsContext.loadSkills(cwd: cwd)
            if loaded.isEmpty {
                Swift.print("No skills found in .claude/skills/ or ~/.claude/skills/")
                Swift.print(ANSI.styled("Create one at .claude/skills/<name>/SKILL.md with YAML frontmatter (name, description).", ANSI.dim, fd: STDOUT_FILENO))
            } else {
                Swift.print(ANSI.styled("Loaded skills (\(loaded.count)):", ANSI.bold, fd: STDOUT_FILENO))
                for s in loaded {
                    Swift.print("  \(ANSI.styled(s.name, ANSI.green, fd: STDOUT_FILENO))  — \(s.description)")
                    Swift.print(ANSI.styled("    \(s.source.path)", ANSI.dim, fd: STDOUT_FILENO))
                }
            }

        case "agents":
            let all = SubagentsContext.all(cwd: cwd)
            if all.isEmpty {
                Swift.print("No subagents found in .claude/agents/ or ~/.claude/agents/")
                Swift.print(ANSI.styled("Create one at .claude/agents/<name>.md with YAML frontmatter (name, description).", ANSI.dim, fd: STDOUT_FILENO))
            } else {
                Swift.print(ANSI.styled("Subagents (\(all.count)):", ANSI.bold, fd: STDOUT_FILENO))
                for a in all {
                    Swift.print("  \(ANSI.styled(a.name, ANSI.green, fd: STDOUT_FILENO)) — \(a.description)")
                    var meta: [String] = []
                    if let m = a.modelOverride { meta.append("model=\(m)") }
                    if let t = a.toolAllowlist { meta.append("tools=\(t.joined(separator: ","))") }
                    if !meta.isEmpty {
                        Swift.print(ANSI.styled("    \(meta.joined(separator: " · "))", ANSI.dim, fd: STDOUT_FILENO))
                    }
                    Swift.print(ANSI.styled("    \(a.source.path)", ANSI.dim, fd: STDOUT_FILENO))
                }
            }

        case "output-styles", "outputstyles":
            let all = OutputStyles.all(cwd: cwd)
            Swift.print(ANSI.styled("Output styles:", ANSI.bold, fd: STDOUT_FILENO))
            for s in all {
                let desc = s.description.map { " — \($0)" } ?? ""
                let src = s.source.map { " (\($0.path))" } ?? " (built-in)"
                Swift.print("  \(ANSI.styled(s.name, ANSI.green, fd: STDOUT_FILENO))\(desc)")
                Swift.print(ANSI.styled("    \(src)", ANSI.dim, fd: STDOUT_FILENO))
            }

        case "doctor":
            await runDoctor(cwd: cwd)

        case "login":
            // Re-auth the hosted provider without losing the session. Before this
            // existed, a revoked token meant every prompt 401'd and the only way
            // out was /quit → `lingcode auth login` → relaunch, discarding the
            // transcript. Accepts `/login <token>` for paste-in-one-go, but
            // prefers the /dev/tty prompt so the token stays out of scrollback
            // and out of the REPL's own history.
            let liActive = CLIEnvironment.resolvedAccount(forProvider: "lingmodel")
            let entered: String
            if let arg = arg, !arg.isEmpty {
                entered = arg
            } else if let tty = tty {
                Swift.print("Mint a token at \(LingModelAuth.mintURL), then paste it here.")
                tty.write("LingModel token: ")
                entered = tty.readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } else {
                printError("/login needs a TTY — pass the token directly: /login <token>", colorEnabled: colorOn)
                return true
            }
            guard !entered.isEmpty else {
                Swift.print(ANSI.styled("no token entered — nothing changed", ANSI.dim, fd: STDOUT_FILENO))
                return true
            }
            // Verify BEFORE persisting. Writing an unverified token would swap a
            // known-dead credential for a possibly-dead one and still report ✓.
            let acceptedNote: String
            switch LingModelAuth.probe(token: entered) {
            case .rejected:
                printError("that token was rejected by the server — nothing saved. Mint a fresh one at \(LingModelAuth.mintURL)", colorEnabled: colorOn)
                return true
            case .unreachable:
                printError("could not reach the server to verify that token — nothing saved. Check your connection and retry.", colorEnabled: colorOn)
                return true
            case .valid(let tier):
                acceptedNote = tier.map { " (tier=\($0))" } ?? ""
            case .rateLimited:
                acceptedNote = " (currently rate-limited)"
            }
            do {
                try LingModelAuth.save(token: entered, account: liActive)
            } catch {
                printError("token verified but could not be saved to the keychain: \(error)", colorEnabled: colorOn)
                return true
            }
            Swift.print(ANSI.styled("✓ token valid\(acceptedNote) and saved", ANSI.green, fd: STDOUT_FILENO))
            let modelForPush = currentModel
            if let pushed = await pushLiveToken(entered, session: session, model: modelForPush, colorEnabled: colorOn) {
                // Keep the REPL's view aligned with what the bridge now holds —
                // set_model assigns currentModel there unconditionally.
                currentModel = pushed
            }

        case "logout":
            // Clears the stored credential. Does NOT tear down the running bridge:
            // the already-spawned subprocess keeps its copy, so we say plainly that
            // this session stays authed rather than implying a revoke we can't do.
            let loActive = CLIEnvironment.resolvedAccount(forProvider: "lingmodel")
            do {
                try LingModelAuth.delete(account: loActive)
                Swift.print(ANSI.styled("✓ LingModel token removed from the keychain", ANSI.green, fd: STDOUT_FILENO))
                Swift.print(ANSI.styled("  this session keeps working until you quit; new sessions will need /login", ANSI.dim, fd: STDOUT_FILENO))
            } catch {
                printError("could not remove the stored token: \(error)", colorEnabled: colorOn)
            }

        case "export":
            // /export [path]  — write transcript markdown. Defaults to ./lingcode-transcript-<ts>.md
            let target: URL = {
                if let a = arg, !a.isEmpty {
                    return URL(fileURLWithPath: (a as NSString).expandingTildeInPath)
                }
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                return cwd.appendingPathComponent("lingcode-transcript-\(stamp).md")
            }()
            var md = "# LingCode transcript\n\nSession: \(currentSessionId ?? "—")\n\n"
            for entry in transcript {
                let header = entry.role == "user" ? "## You" : "## Assistant"
                md += "\(header)\n\n\(entry.text)\n\n"
            }
            do {
                try md.write(to: target, atomically: true, encoding: .utf8)
                Swift.print(ANSI.styled("✓ exported \(transcript.count) entries to \(target.path)", ANSI.green, fd: STDOUT_FILENO))
            } catch {
                printError("export failed: \(error)", colorEnabled: colorOn)
            }

        case "init":
            // Delegate to the `lingcode init` command (generate CLAUDE.md for cwd).
            // We spawn it as a subprocess so stdout/permissions stay intuitive even
            // inside the REPL and the user sees the same confirmation prompts.
            let exe = Bundle.main.executablePath
                ?? CommandLine.arguments.first
                ?? "lingcode"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["init", "--project", cwd.path]
            if arg == "--force" { p.arguments?.append("--force") }
            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                printError("init failed: \(error)", colorEnabled: colorOn)
            }

        default:
            Swift.print("unknown command /\(cmd) — type /help for a list")
        }

        return true
    }

    private func runDoctor(cwd: URL) async {
        // Shared with `lingcode doctor` so the two surfaces don't drift.
        DoctorReport.run(cwd: cwd, includeNetwork: true)
    }

    // MARK: - Helpers

    private var colorOn: Bool { ANSI.colorEnabled() }

    private func resolveInitialSessionId(cwd: URL) -> String? {
        if let r = resume, !r.isEmpty { return r }
        if `continue` {
            if let id = SessionStore.loadLast(forCwd: cwd) { return id }
            FileHandle.standardError.write(Data("lingcode: no previous session found; starting fresh.\n".utf8))
        }
        return nil
    }

    private func printWelcomeBanner(model: String?, colorEnabled: Bool, providerLabel: String = "claude") {
        guard !CLIEnvironment.quiet, isatty(STDOUT_FILENO) != 0 else { return }
        let modelStr = model.map { " · \($0)" } ?? ""
        let providerStr = "(\(providerLabel)\(modelStr))"
        let pad = String(repeating: " ", count: max(0, 28 - providerStr.count))
        let banner = """
        \(ANSI.styled("╭────────────────────────────────────────╮", ANSI.blue, fd: STDOUT_FILENO))
        \(ANSI.styled("│", ANSI.blue, fd: STDOUT_FILENO))  LingCode \(CLIVersion.display)  \(providerStr)\(pad)\(ANSI.styled("│", ANSI.blue, fd: STDOUT_FILENO))
        \(ANSI.styled("│", ANSI.blue, fd: STDOUT_FILENO))  /help for commands · Ctrl-D to exit   \(ANSI.styled("│", ANSI.blue, fd: STDOUT_FILENO))
        \(ANSI.styled("╰────────────────────────────────────────╯", ANSI.blue, fd: STDOUT_FILENO))
        """
        Swift.print(banner)
    }

    private func buildPrompt(sessionId: String?, turnCount: Int, totalCost: Double, statusLineSuffix: String? = nil) -> String {
        if let s = statusLineSuffix, !s.isEmpty {
            return ANSI.styled("\(s)> ", ANSI.bold, ANSI.blue, fd: STDOUT_FILENO)
        }
        var info: [String] = []
        if turnCount > 0 { info.append("\(turnCount)t") }
        if totalCost >= 0.001 { info.append(String(format: "$%.3f", totalCost)) }
        let infoStr = info.isEmpty ? "" : " [\(info.joined(separator: " "))]"
        return ANSI.styled("lingcode\(infoStr)> ", ANSI.bold, ANSI.blue, fd: STDOUT_FILENO)
    }

    /// One-line dashboard rendered above the prompt each turn.
    /// Mirrors Claude Code's status line: branch · mode · ctx% · model · subagents.
    /// Returns "" when stdout isn't a TTY (skips noise when piped).
    private func buildDashboardLine(
        cwd: URL,
        mode: BridgePermissionMode,
        model: String?,
        totalInputTokens: Int,
        totalOutputTokens: Int
    ) -> String {
        guard isatty(STDOUT_FILENO) != 0 else { return "" }

        var parts: [String] = []
        if let branch = GitBranchProbe.current(at: cwd) {
            let dirty = GitBranchProbe.isDirty(at: cwd) ? "*" : ""
            parts.append("⎇ \(branch)\(dirty)")
        }
        parts.append(mode.rawValue)
        // Per-model context window — divisor depends on the active model.
        // Claude is 200K, DeepSeek/Gemini/GPT-4.1 are 1M, GPT-4o is 128K.
        // Hardcoding 200K over-reports 5× on a 1M model.
        let totalTokens = totalInputTokens + totalOutputTokens
        if totalTokens > 0 {
            let window = Self.contextWindowSize(for: model ?? "")
            let pct = min(100, Int(Double(totalTokens) / Double(window) * 100.0))
            parts.append("ctx \(pct)%")
        }
        if let m = model, !m.isEmpty {
            parts.append(shortModelName(m))
        }
        let agents = Subagent.list(cwd: cwd)
        if !agents.isEmpty {
            parts.append("\(agents.count) agent\(agents.count == 1 ? "" : "s")")
        }
        let line = parts.joined(separator: " · ")
        return ANSI.styled(line, ANSI.dim, fd: STDOUT_FILENO)
    }

    /// "claude-sonnet-4-6" → "sonnet-4-6"; fallback to the input on miss.
    private func shortModelName(_ full: String) -> String {
        if full.hasPrefix("claude-") {
            return String(full.dropFirst("claude-".count))
        }
        return full
    }

    /// Per-model context window in tokens. Mirror of the Mac app's
    /// ClaudeCodeStatusBar.contextWindowSize — keep them in sync. Falls
    /// back to 200K (Claude lineage) for unknown labels.
    static func contextWindowSize(for modelLabel: String) -> Int {
        let m = modelLabel.lowercased()
        if m.contains("ling")       { return 1_000_000 }
        if m.contains("deepseek")   { return 1_000_000 }
        if m.contains("gemini-2.5") { return 2_000_000 }
        if m.contains("gemini-3") { return 2_000_000 }
        if m.contains("gemini") { return 1_000_000 }
        // GPT-5.6 family and GPT-6 Astra: 1.05M context, 128K max output.
        // MUST precede the gpt-4o / o1 lines — those are `contains` scans and
        // "gpt-5.6-sol" would not hit them, but keeping the newest first is the
        // convention that stopped this table going stale before.
        if m.contains("gpt-6")      { return 1_050_000 }
        if m.contains("gpt-5.6")    { return 1_050_000 }
        if m.contains("gpt-5")      { return 400_000 }
        if m.contains("gpt-4.1")    { return 1_000_000 }
        if m.contains("gpt-4o")     { return 128_000 }
        if m.contains("o1")         { return 200_000 }
        if m.contains("grok")       { return 131_072 }
        if m.contains("llama")      { return 131_072 }
        if m.contains("mistral")    { return 128_000 }
        if m.contains("claude")     { return 200_000 }
        if m.contains("opus")       { return 200_000 }
        if m.contains("sonnet")     { return 200_000 }
        if m.contains("haiku")      { return 200_000 }
        return 200_000
    }

    /// Emits one NDJSON line per bridge event on stdout. Used by `--json` mode
    /// so REPL output can be piped into `jq` or other line-oriented tools.
    /// Schema is a stable subset: type + event-specific fields, no envelope.
    static func emitReplJSON(event: BridgeEvent) {
        var obj: [String: Any] = [:]
        switch event {
        case .ready: obj["type"] = "ready"
        case .queryStarted(let id):
            obj["type"] = "query_started"
            obj["query_id"] = id
        case .awaitingFirstMessage(let id):
            obj["type"] = "query_awaiting_first_message"
            obj["query_id"] = id
        case .assistantText(let t):
            obj["type"] = "assistant_text"
            obj["text"] = t
        case .toolUse(let n, let i, let toolUseId):
            obj["type"] = "tool_use"
            obj["name"] = n
            obj["input"] = i
            obj["tool_use_id"] = toolUseId
        case .toolResult(let c, let isErr, let toolUseId):
            obj["type"] = "tool_result"
            obj["content"] = c
            obj["is_error"] = isErr
            obj["tool_use_id"] = toolUseId
        case .permissionRequested:
            obj["type"] = "permission_requested"
        case .permissionResolved(let id, let behavior):
            obj["type"] = "permission_resolved"
            obj["request_id"] = id
            obj["behavior"] = behavior
        case .queryFinished(let sid, let res, _):
            obj["type"] = "query_finished"
            if let s = sid { obj["session_id"] = s }
            if let r = res { obj["result_text"] = r }
        case .queryCancelled(let m):
            obj["type"] = "query_cancelled"
            obj["message"] = m
        case .queryFailed(let m):
            obj["type"] = "query_failed"
            obj["message"] = m
        case .bridgeError(let m, let code):
            obj["type"] = "bridge_error"
            obj["message"] = m
            if let c = code { obj["code"] = c }
        case .bridgeExited(let code, let stderr):
            obj["type"] = "bridge_exited"
            obj["code"] = Int(code)
            obj["stderr"] = stderr
        case .tokenUsage(let i, let o, let cacheRead, let cacheCreation):
            obj["type"] = "token_usage"
            obj["input_tokens"] = i
            obj["output_tokens"] = o
            obj["cache_read_tokens"] = cacheRead
            obj["cache_creation_tokens"] = cacheCreation
        case .sdkMessage(let data):
            obj["type"] = "sdk_message"
            obj["data"] = data
        case .subagentStarted(let data):
            obj["type"] = "subagent_started"
            obj["data"] = data
        case .subagentFinished(let data):
            obj["type"] = "subagent_finished"
            obj["data"] = data
        case .memoryWriteRequest(let data):
            obj["type"] = "memory_write_request"
            obj["data"] = data
        case .skillWriteRequest(let data):
            obj["type"] = "skill_write_request"
            obj["data"] = data
        case .sessionSearchRequest(let data):
            obj["type"] = "session_search_request"
            obj["data"] = data
        case .terminalReadRequest(let data):
            obj["type"] = "terminal_read_request"
            obj["data"] = data
        case .sessionRecovered(let reason, let message):
            obj["type"] = "session_recovered"
            obj["reason"] = reason
            obj["message"] = message
        case .userInputRequested(let request):
            obj["type"] = "user_input_request"
            obj["requestId"] = request.id
            obj["questions"] = request.questions.map { q in
                [
                    "question": q.question,
                    "header": q.header,
                    "multiSelect": q.multiSelect,
                    "options": q.options.map { ["label": $0.label, "description": $0.description] },
                ]
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
           let s = String(data: data, encoding: .utf8) {
            FileHandle.standardOutput.write(Data((s + "\n").utf8))
        }
    }

    /// Tab-completion suggestions for the REPL.
    /// Only proposes slash commands (builtin + custom) when the buffer starts with "/".
    static func completions(forBuffer buffer: String, cwd: URL) -> [String] {
        guard buffer.hasPrefix("/") else { return [] }
        let query = String(buffer.dropFirst()).lowercased()
        var all: [String] = builtinSlashCommands.map { "/\($0)" }
        for c in CustomSlashCommands.all(cwd: cwd) {
            let prefix = c.source == .project ? "project" : "user"
            all.append("/\(prefix):\(c.name)")
        }
        if query.isEmpty { return all.sorted() }
        return all.filter { $0.dropFirst().lowercased().hasPrefix(query) }.sorted()
    }

    private func printError(_ msg: String, colorEnabled: Bool) {
        let line = ANSI.styled("error: \(msg)\n", ANSI.red, fd: STDERR_FILENO)
        FileHandle.standardError.write(Data(line.utf8))
    }
}

// MARK: - Token cost

private let builtinSlashCommands: Set<String> = [
    "help", "?", "quit", "exit", "q", "clear", "session", "fork", "resume",
    "cost", "reset", "yolo", "mode", "model", "tools", "commands", "skills",
    "agents", "output-styles", "outputstyles", "doctor", "compact",
    "export", "init",
]

private func rawCost(input: Int, output: Int, cache: Int) -> Double {
    Double(input) / 1_000_000 * 3.0
        + Double(output) / 1_000_000 * 15.0
        + Double(cache) / 1_000_000 * 0.30
}

private func formatCost(_ cost: Double) -> String {
    if cost < 0.001 { return "<$0.001" }
    return String(format: "$%.3f", cost)
}

private func estimateCost(input: Int, output: Int, cache: Int) -> String {
    formatCost(rawCost(input: input, output: output, cache: cache))
}

private func format(_ n: Int) -> String {
    let nf = NumberFormatter()
    nf.numberStyle = .decimal
    return nf.string(from: NSNumber(value: n)) ?? "\(n)"
}

// MARK: - Tool use display

private func formatToolUseLine(name: String, inputJSON: String, verbose: Bool, colorEnabled: Bool) -> String {
    let nameStyled = ANSI.styled("» \(name)", ANSI.cyan, ANSI.bold, fd: STDERR_FILENO)

    // Try to show a diff for file-edit tools
    if let diff = extractDiff(name: name, inputJSON: inputJSON, colorEnabled: colorEnabled) {
        return nameStyled + "\n" + diff
    }

    let shown: String
    if verbose {
        shown = inputJSON
    } else {
        shown = inputJSON.count > 200 ? String(inputJSON.prefix(200)) + "…" : inputJSON
    }
    return nameStyled + " " + ANSI.styled(shown, ANSI.dim, fd: STDERR_FILENO)
}

private func extractDiff(name: String, inputJSON: String, colorEnabled: Bool) -> String? {
    let editTools: Set<String> = ["Edit", "str_replace_based_edit_tool", "edit_file"]
    let writeTools: Set<String> = ["Write", "write_file", "create_file"]

    guard let data = inputJSON.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

    let filePath = (obj["file_path"] as? String) ?? (obj["path"] as? String) ?? ""

    if writeTools.contains(name) {
        let content = obj["content"] as? String ?? ""
        let allLines = content.components(separatedBy: "\n")
        let lineCount = allLines.count
        var lines: [String] = []
        lines.append(ANSI.styled("  write \(filePath) (\(lineCount) lines)", ANSI.dim, fd: STDERR_FILENO))
        let previewMax = 8
        for line in allLines.prefix(previewMax) {
            lines.append(ANSI.styled("+ \(line)", ANSI.green, fd: STDERR_FILENO))
        }
        if lineCount > previewMax {
            lines.append(ANSI.styled("  … (\(lineCount - previewMax) more lines)", ANSI.dim, fd: STDERR_FILENO))
        }
        return lines.joined(separator: "\n")
    }

    if editTools.contains(name) {
        let oldStr = (obj["old_str"] as? String) ?? (obj["old_string"] as? String) ?? ""
        let newStr = (obj["new_str"] as? String) ?? (obj["new_string"] as? String) ?? ""
        guard !oldStr.isEmpty || !newStr.isEmpty else { return nil }
        let pathLabel = filePath.isEmpty ? "" : " \(filePath)"
        return renderDiff(old: oldStr, new: newStr, filePath: pathLabel, colorEnabled: colorEnabled)
    }

    return nil
}

private func renderDiff(old: String, new: String, filePath: String, colorEnabled: Bool) -> String {
    var lines: [String] = []
    if !filePath.isEmpty {
        lines.append(ANSI.styled("  diff\(filePath)", ANSI.dim, fd: STDERR_FILENO))
    }
    let maxLines = 12  // keep diffs compact
    let oldLines = old.components(separatedBy: "\n")
    let newLines = new.components(separatedBy: "\n")

    var shown = 0
    for line in oldLines.prefix(maxLines) {
        lines.append(ANSI.styled("- \(line)", ANSI.red, fd: STDERR_FILENO))
        shown += 1
    }
    if oldLines.count > maxLines {
        lines.append(ANSI.styled("  … (\(oldLines.count - maxLines) more removed)", ANSI.dim, fd: STDERR_FILENO))
    }
    for line in newLines.prefix(maxLines - shown) {
        lines.append(ANSI.styled("+ \(line)", ANSI.green, fd: STDERR_FILENO))
    }
    if newLines.count > maxLines - shown {
        lines.append(ANSI.styled("  … (\(newLines.count - (maxLines - shown)) more added)", ANSI.dim, fd: STDERR_FILENO))
    }
    return lines.joined(separator: "\n")
}

// `KeychainBridge` removed — was a no-op stub (always returned nil). The
// real cross-platform implementation lives in SecretStore.swift.
