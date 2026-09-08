import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import LingCodeAgentCore

/// Interactive multi-turn REPL for any OpenAI-compatible provider.
/// Supports text and agentic modes; toggle at runtime with /yolo, /ask, /safe.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct OpenAICompatREPL {
    enum AgentMode {
        case text       // no tools
        case yolo       // tools, auto-approve
        case ask        // tools, prompt per call at the TTY

        var label: String {
            switch self {
            case .text: return "text-only"
            case .yolo: return "yolo (auto-approve)"
            case .ask:  return "ask (prompt per tool)"
            }
        }
    }

    let providerName: String
    let cwd: URL
    let baseURLOverride: String?
    let apiKeyEnvOverride: String?
    let modelOverride: String?
    let systemPromptOverride: String?
    let appendSystemPrompt: String?
    let claudeMd: Bool
    let skillsEnabled: Bool
    let outputStyle: String?
    let verbose: Bool
    let initialYolo: Bool
    let initialPermissionMode: String?
    let continueLast: Bool
    let resumeSessionId: String?
    let mcpEnabled: Bool
    let mcpConfigPath: String?
    let timeoutFlag: Int?

    func run() async throws {
        let preset = OpenAICompatProvider(rawValue: providerName.lowercased())
        let baseURL: URL = {
            if let o = baseURLOverride, let u = URL(string: o) { return u }
            return preset?.baseURL ?? URL(string: "https://invalid.local")!
        }()
        if baseURL.host == "invalid.local" {
            FileHandle.standardError.write(Data("lingcode: provider '\(providerName)' is not a known preset. Pass --base-url.\n".utf8))
            throw ExitCode(1)
        }

        let envVar = apiKeyEnvOverride ?? preset?.envVar ?? "OPENAI_API_KEY"
        let apiKey: String = {
            if let env = ProcessInfo.processInfo.environment[envVar]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
                return env
            }
            // Keychain fallback. Mirrors HeadlessOpenAICompat.swift so the
            // interactive `lingcode` REPL and `lingcode ask` headless mode
            // resolve keys identically — paste once via `auth login`, both
            // pick it up. Account names match Auth.swift's knownProviders.
            let keychainBase: String? = {
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
            if let base = keychainBase {
                let lookupName = (preset == .deepseekCompat) ? "deepseek" : providerName
                let kAccount = keychainAccount(
                    base: base,
                    account: CLIEnvironment.resolvedAccount(forProvider: lookupName)
                )
                if let kc = try? SecretStore.get(service: keychainService, account: kAccount),
                   !kc.isEmpty {
                    return kc
                }
            }
            return ""
        }()
        if apiKey.isEmpty && preset != .ollama {
            FileHandle.standardError.write(Data("""
                lingcode: \(envVar) is not set.

                Set it in your shell:
                  export \(envVar)=<your-key>

                """.utf8))
            throw ExitCode(1)
        }

        let timeoutSeconds = OpenAICompatClient.resolveTimeoutSeconds(flag: timeoutFlag)
        let urlSession = OpenAICompatClient.makeURLSession(timeoutSeconds: timeoutSeconds)
        let client = OpenAICompatClient(apiKey: apiKey, baseURL: baseURL, urlSession: urlSession)
        if verbose {
            FileHandle.standardError.write(Data(
                "lingcode: http idle timeout = \(Int(timeoutSeconds))s\n".utf8
            ))
        }
        var currentModel = modelOverride ?? preset?.defaultModel ?? "gpt-5.6-sol"
        // Cached result of the most recent `/model` (no arg) listing, so a
        // follow-up `/model 3` resolves to the third entry without re-fetching.
        var modelChoices: [String] = []
        var mode: AgentMode = Self.initialMode(yolo: initialYolo, permissionMode: initialPermissionMode)

        // Bring up any MCP stdio servers from .mcp.json / ~/.claude.json and merge their
        // tools alongside built-ins so DeepSeek/OpenAI-compat see them as regular function-calls.
        var mcpManager: MCPManager? = nil
        var mcpStatuses: [MCPServerStatus] = []
        var toolRegistry = BuiltinTools.defaultRegistry()
        if mcpEnabled {
            let (mgr, result) = await MCPManager.bootstrap(cwd: cwd, overridePath: mcpConfigPath,
                                                           extraServers: cloudMCPServers(for: cwd))
            mcpManager = mgr
            mcpStatuses = result.statuses
            if !result.executors.isEmpty {
                let builtins = Array(toolRegistry.executors.values)
                toolRegistry = ToolRegistry(builtins + result.executors)
            }
        }
        defer {
            if let mgr = mcpManager {
                Task { await mgr.shutdownAll() }
            }
        }

        // Build initial system prompt. CLAUDE.md is concatenated the same way other providers do.
        var systemPrompt = systemPromptOverride ?? "You are a coding assistant running in a terminal. Answer concisely. You cannot edit files in this mode — describe changes the user should apply manually."
        var hasClaudeMd = false
        if claudeMd, let md = ProjectContext.loadClaudeMd(startingAt: cwd), !md.isEmpty {
            systemPrompt += "\n\n--- Project CLAUDE.md ---\n\(md)"
            hasClaudeMd = true
        }
        let loadedSkills = skillsEnabled ? SkillsContext.loadSkills(cwd: cwd) : []
        if let skillsBlock = SkillsContext.formatPreamble(loadedSkills) {
            systemPrompt += "\n\n--- Skills ---\n\(skillsBlock)"
        }
        if let style = OutputStyles.resolve(name: outputStyle, cwd: cwd) {
            systemPrompt += OutputStyles.systemPromptSuffix(for: style)
        } else if let requested = outputStyle, !requested.isEmpty {
            FileHandle.standardError.write(Data(
                "lingcode: output style '\(requested)' not found — falling back to default.\n".utf8
            ))
        }
        if let asp = appendSystemPrompt, !asp.isEmpty {
            systemPrompt += "\n\n\(asp)"
        }

        // Load hooks from settings.json (.claude/settings.json or ~/.claude/settings.json).
        // Same source of truth as the Claude REPL — keeps a PreToolUse rule you wrote
        // for Claude firing on every provider without duplicate config.
        let hooks = HooksConfig.load(cwd: cwd)

        var history: [OpenAICompatClient.Message] = [
            .init(role: "system", content: systemPrompt)
        ]
        var transcript: [(role: String, text: String)] = []
        var turnCount = 0
        var totalInput = 0
        var totalOutput = 0
        // Per-tool invocation counters surfaced in the dashboard.
        // Incremented in the .toolResult event handler so failed and
        // succeeded calls both count (model reasoning sees both).
        var toolCounts: [String: Int] = [:]
        let sessionStart = Date()

        // Session resume: load history from --resume <id> or --continue (last for cwd).
        var sessionId: String = OpenAICompatSessionStore.newSessionId()
        if let rid = resumeSessionId, !rid.isEmpty,
           let record = OpenAICompatSessionStore.load(id: rid) {
            history = record.messages
            sessionId = record.id
            turnCount = history.filter { $0.role == "user" }.count
            Swift.print(ANSI.styled("resumed session \(record.id) (\(turnCount) turns)", ANSI.cyan, fd: STDOUT_FILENO))
        } else if let rid = resumeSessionId, !rid.isEmpty {
            FileHandle.standardError.write(Data("lingcode: no session found with id '\(rid)'\n".utf8))
        } else if continueLast,
                  let record = OpenAICompatSessionStore.loadLast(cwd: cwd) {
            history = record.messages
            sessionId = record.id
            turnCount = history.filter { $0.role == "user" }.count
            Swift.print(ANSI.styled("continuing session \(record.id) (\(turnCount) turns)", ANSI.cyan, fd: STDOUT_FILENO))
        }

        let colorOn = ANSI.colorEnabled()
        printBanner(provider: providerName, model: currentModel, mode: mode, colorOn: colorOn)

        // SIGINT: cancel the active turn on first press; exit on second press with no turn active.
        // Mirrors Claude REPL behaviour at Repl.swift:251-265.
        let queryActive = AtomicBool(false)
        let activeTurn = TurnTaskBox()
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sigintSource.setEventHandler {
            if queryActive.value {
                FileHandle.standardError.write(Data("\n^C (cancelling turn)\n".utf8))
                activeTurn.cancel()
            } else {
                FileHandle.standardError.write(Data("\n^C\n".utf8))
                #if canImport(Darwin)
                Darwin.exit(130)
                #else
                Glibc.exit(130)
                #endif
            }
        }
        sigintSource.resume()
        defer { sigintSource.cancel() }

        let tty = TTYIO.open()
        defer { tty?.close() }

        let stdinIsTTY = isatty(STDIN_FILENO) != 0
        let editorCwd = cwd
        let lineEditor: LineEditor? = stdinIsTTY
            ? LineEditor(inFd: STDIN_FILENO, outFd: STDOUT_FILENO) { buffer, _ in
                Self.completions(forBuffer: buffer, cwd: editorCwd)
            }
            : nil

        let statusLineConfig = StatusLine.load(cwd: cwd)
        var statusLineCache: String? = nil

        // Images staged via /image and flushed into the next user turn.
        var pendingImages: [String] = []

        // Deadline for the "press Ctrl-C again to exit" window. Declared outside the
        // turn loop so it survives the prompt being redrawn between presses.
        var ctrlCArmedUntil: TimeInterval?

        while true {
            // Multi-line dashboard above the prompt. TTY-gated inside.
            let dashboard = await renderDashboard(
                cwd: cwd,
                mode: mode,
                model: currentModel,
                totalInput: totalInput,
                totalOutput: totalOutput,
                turnCount: turnCount,
                mcpCount: mcpStatuses.count,
                hooks: hooks,
                hasClaudeMd: hasClaudeMd,
                toolCounts: toolCounts,
                sessionStart: sessionStart
            )
            if !dashboard.isEmpty {
                FileHandle.standardOutput.write(Data((dashboard + "\n").utf8))
            }
            let prompt = buildPrompt(turnCount: turnCount, colorOn: colorOn, statusLineSuffix: statusLineCache)

            var assembled = ""
            readOneInput: while true {
                let chunk: String?
                if let editor = lineEditor {
                    FileHandle.standardOutput.write(Data(prompt.utf8))
                    switch editor.readLine(prompt: prompt) {
                    case .line(let s):      chunk = s
                    case .eof:              chunk = nil
                    case .interrupted(let hadInput):
                        // Same trap as the Claude REPL: raw mode means Ctrl-C never
                        // raises SIGINT here, so without this the key could only
                        // ever clear the line and never exit.
                        assembled = ""
                        if hadInput {
                            ctrlCArmedUntil = nil
                            continue readOneInput
                        }
                        let now = Date().timeIntervalSinceReferenceDate
                        if let armed = ctrlCArmedUntil, now <= armed { return }
                        ctrlCArmedUntil = now + 5  // see Repl.swift: 2s expired mid-keypress
                        FileHandle.standardError.write(Data(
                            "Press Ctrl-C again to exit (or /quit)\n".utf8
                        ))
                        continue readOneInput
                    }
                } else if let tty = tty {
                    tty.write(prompt); chunk = tty.readLine()
                } else {
                    Swift.print(prompt, terminator: "")
                    fflush(stdout)
                    chunk = Swift.readLine(strippingNewline: true)
                }
                guard let line = chunk else { return }
                if line.hasSuffix("\\") {
                    assembled += String(line.dropLast()) + "\n"
                    continue
                }
                assembled += line
                break
            }

            let input = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty else { continue }
            lineEditor?.addHistory(input)

            // Custom slash commands: /project:name, /user:name, or /<name>
            // Resolved to a markdown/txt prompt file under .claude/commands/.
            // Mirrors Claude REPL behaviour at Repl.swift:359-372.
            var customPromptBody: String? = nil
            if input.hasPrefix("/") {
                let token = String(input.dropFirst())
                    .split(separator: " ", maxSplits: 1)
                    .first.map(String.init) ?? ""
                let rest = input.dropFirst(1 + token.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let looksCustom = token.contains(":")
                    || !Self.builtinSlashCommandNames.contains(token.lowercased())
                if looksCustom,
                   let body = CustomSlashCommands.resolve(token, cwd: cwd) {
                    customPromptBody = rest.isEmpty ? body : body + "\n\n" + rest
                }
            }

            // Slash commands (subset of Claude REPL — only the ones that make sense here).
            if input.hasPrefix("/") && customPromptBody == nil {
                let parts = input.dropFirst().split(separator: " ", maxSplits: 1)
                let cmd = parts.first.map(String.init)?.lowercased() ?? ""
                let arg = parts.dropFirst().first.map(String.init)?.trimmingCharacters(in: .whitespaces)

                switch cmd {
                case "quit", "exit", "q":
                    return

                case "help", "?":
                    Swift.print("""

                      /model <name>     Switch model (e.g. gpt-5.6-sol, gpt-6-astra, llama-3.3-70b-versatile)
                      /reset            Clear conversation history
                      /system <text>    Replace the system prompt (applies from next turn)
                      /cost             Show token usage totals
                      /export [path]    Save transcript as markdown
                      /tools            List available tools (agentic modes)
                      /mcp              Show MCP server status and exposed tools
                      /commands         List custom slash commands from .claude/commands/
                      /fork             Branch the current session into a new sessionId
                      /yolo             Agentic mode, auto-approve every tool call
                      /ask              Agentic mode, prompt per tool call at the TTY
                      /safe             Text-only (no tools). Default.
                      /mode             Show the current agent mode
                      /clear            Clear the screen
                      /quit             Exit
                      /help             Show this help

                    Custom prompts from .claude/commands/<name>.md are available as
                    /project:<name>, /user:<name>, or bare /<name>.

                    """)

                case "yolo":
                    mode = .yolo
                    Swift.print(ANSI.styled("mode → yolo (auto-approve every tool call)", ANSI.yellow, fd: STDOUT_FILENO))
                case "ask":
                    mode = .ask
                    Swift.print(ANSI.styled("mode → ask (prompt per tool call at the TTY)", ANSI.cyan, fd: STDOUT_FILENO))
                case "safe", "text":
                    mode = .text
                    Swift.print(ANSI.styled("mode → text-only (no tools)", ANSI.green, fd: STDOUT_FILENO))
                case "mode":
                    Swift.print(ANSI.styled("current mode: \(mode.label)", ANSI.cyan, fd: STDOUT_FILENO))
                case "tools":
                    let names = toolRegistry.specs.map { $0.name }.sorted().joined(separator: ", ")
                    Swift.print(ANSI.styled("tools: \(names)", ANSI.cyan, fd: STDOUT_FILENO))

                case "mcp":
                    if mcpStatuses.isEmpty {
                        Swift.print("no MCP servers configured (checked .mcp.json and ~/.claude.json)")
                    } else {
                        for status in mcpStatuses {
                            switch status.state {
                            case .connected(let tools):
                                let header = ANSI.styled("✓ \(status.name)", ANSI.green, fd: STDOUT_FILENO)
                                Swift.print("\(header) — \(tools.count) tool\(tools.count == 1 ? "" : "s")")
                                for t in tools.sorted() {
                                    Swift.print("    \(t)")
                                }
                            case .failed(let reason):
                                let header = ANSI.styled("✗ \(status.name)", ANSI.red, fd: STDOUT_FILENO)
                                Swift.print("\(header) — failed: \(reason)")
                            case .terminated(let reason):
                                let header = ANSI.styled("✗ \(status.name)", ANSI.red, fd: STDOUT_FILENO)
                                Swift.print("\(header) — terminated: \(reason)")
                            case .skipped(let reason):
                                let header = ANSI.styled("⊘ \(status.name)", ANSI.dim, fd: STDOUT_FILENO)
                                Swift.print("\(header) — \(reason)")
                            }
                        }
                    }
                case "session":
                    let turns = history.filter { $0.role == "user" }.count
                    Swift.print(ANSI.styled("session: \(sessionId) (\(turns) turns). Resume with: lingcode repl --resume \(sessionId)", ANSI.cyan, fd: STDOUT_FILENO))

                case "fork":
                    // Branch the current session: snapshot messages into a fresh sessionId
                    // so the next message continues from the same context but under a new ID.
                    // Matches the Claude REPL's /fork semantics (Repl.swift:1091).
                    if history.isEmpty {
                        Swift.print(ANSI.styled("no active session to fork — send a message first, then /fork", ANSI.dim, fd: STDOUT_FILENO))
                    } else {
                        let parentId = sessionId
                        let newId = OpenAICompatSessionStore.newSessionId()
                        let now = Date()
                        OpenAICompatSessionStore.save(.init(
                            id: newId,
                            cwd: cwd.standardizedFileURL.path,
                            provider: providerName,
                            model: currentModel,
                            createdAt: now,
                            updatedAt: now,
                            messages: history
                        ))
                        sessionId = newId
                        Swift.print(ANSI.styled("forked from \(parentId) → \(newId). Subsequent turns append to the new session; parent is unchanged.", ANSI.cyan, fd: STDOUT_FILENO))
                    }

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

                case "image":
                    guard let p = arg, !p.isEmpty else {
                        Swift.print("usage: /image <path.{png,jpg,jpeg,gif,webp}>")
                        continue
                    }
                    do {
                        let url = try ImageAttachment.dataURL(forPath: p, cwd: cwd)
                        pendingImages.append(url)
                        Swift.print(ANSI.styled("attached image (\(pendingImages.count) pending)", ANSI.cyan, fd: STDOUT_FILENO))
                    } catch {
                        Swift.print(ANSI.styled("attach failed: \(error)", ANSI.red, fd: STDOUT_FILENO))
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

                case "model":
                    if let m = arg, !m.isEmpty {
                        // Index into the most recent listing if the arg is a
                        // pure-digit token in range — `/model 3` after a bare
                        // `/model` shouldn't require copy-pasting the name.
                        let trimmed = m.trimmingCharacters(in: .whitespaces)
                        if !modelChoices.isEmpty,
                           let idx = Int(trimmed),
                           idx >= 1, idx <= modelChoices.count {
                            currentModel = modelChoices[idx - 1]
                        } else {
                            currentModel = trimmed
                        }
                        Swift.print(ANSI.styled("model → \(currentModel)", ANSI.cyan, fd: STDOUT_FILENO))
                    } else {
                        // Bare `/model` — list available models from the
                        // provider's `GET /models` endpoint and let the user
                        // pick by number on the next `/model` call.
                        Swift.print("Current: " + ANSI.styled(currentModel, ANSI.cyan, fd: STDOUT_FILENO))
                        do {
                            let models = try await client.listModels()
                            if models.isEmpty {
                                Swift.print(ANSI.styled("(provider returned no models — switch with /model <name>)", ANSI.dim, fd: STDOUT_FILENO))
                            } else {
                                modelChoices = models
                                Swift.print("Available:")
                                let pad = String(models.count).count
                                for (i, name) in models.enumerated() {
                                    let n = String(repeating: " ", count: pad - String(i + 1).count) + String(i + 1)
                                    let marker = (name == currentModel)
                                        ? ANSI.styled(" ← current", ANSI.dim, fd: STDOUT_FILENO)
                                        : ""
                                    Swift.print("  \(n). \(name)\(marker)")
                                }
                                Swift.print(ANSI.styled("Switch with /model <number-or-name>", ANSI.dim, fd: STDOUT_FILENO))
                            }
                        } catch {
                            Swift.print(ANSI.styled("(could not list models: \(error.localizedDescription)) — switch with /model <name>", ANSI.dim, fd: STDOUT_FILENO))
                        }
                    }

                case "reset":
                    history = [.init(role: "system", content: systemPrompt)]
                    transcript.removeAll()
                    turnCount = 0
                    totalInput = 0; totalOutput = 0
                    Swift.print(ANSI.styled("conversation reset", ANSI.yellow, fd: STDOUT_FILENO))

                case "system":
                    guard let a = arg, !a.isEmpty else {
                        Swift.print("usage: /system <new system prompt>")
                        continue
                    }
                    systemPrompt = a
                    // Replace the existing system message (it's always index 0).
                    if !history.isEmpty, history[0].role == "system" {
                        history[0] = .init(role: "system", content: a)
                    } else {
                        history.insert(.init(role: "system", content: a), at: 0)
                    }
                    Swift.print(ANSI.styled("system prompt updated", ANSI.cyan, fd: STDOUT_FILENO))

                case "cost":
                    let nf = NumberFormatter(); nf.numberStyle = .decimal
                    let i = nf.string(from: NSNumber(value: totalInput))  ?? "\(totalInput)"
                    let o = nf.string(from: NSNumber(value: totalOutput)) ?? "\(totalOutput)"
                    if let rate = Pricing.rate(for: currentModel) {
                        let usd = Pricing.estimate(inputTokens: totalInput, outputTokens: totalOutput, rate: rate)
                        Swift.print(ANSI.styled("Total: ↑ \(i) ↓ \(o) tokens  ≈ \(Pricing.formatUSD(usd))  (\(currentModel))", ANSI.cyan, fd: STDOUT_FILENO))
                    } else {
                        Swift.print(ANSI.styled("Total: ↑ \(i) ↓ \(o) tokens  (no pricing table entry for '\(currentModel)')", ANSI.cyan, fd: STDOUT_FILENO))
                    }

                case "clear":
                    Swift.print("\u{1B}[2J\u{1B}[H", terminator: "")

                case "export":
                    let target: URL = {
                        if let a = arg, !a.isEmpty {
                            return URL(fileURLWithPath: (a as NSString).expandingTildeInPath)
                        }
                        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                        return cwd.appendingPathComponent("lingcode-transcript-\(stamp).md")
                    }()
                    var md = "# LingCode transcript (\(providerName))\n\nModel: \(currentModel)\n\n"
                    for entry in transcript {
                        let hdr = entry.role == "user" ? "## You" : "## Assistant"
                        md += "\(hdr)\n\n\(entry.text)\n\n"
                    }
                    do {
                        try md.write(to: target, atomically: true, encoding: .utf8)
                        Swift.print(ANSI.styled("✓ exported \(transcript.count) entries to \(target.path)", ANSI.green, fd: STDOUT_FILENO))
                    } catch {
                        FileHandle.standardError.write(Data("export failed: \(error)\n".utf8))
                    }

                default:
                    Swift.print("unknown command /\(cmd) — type /help for a list")
                }
                continue
            }

            // Normal turn: append user, send request, stream assistant, append assistant.
            // When a custom slash command resolved, its markdown body is what we send
            // to the model; the raw `/name` input is hidden from history so the model
            // sees the prompt rather than a command name it doesn't understand.
            let promptText = customPromptBody ?? input
            let imagesForTurn = pendingImages
            pendingImages.removeAll()
            history.append(.init(
                role: "user",
                content: promptText,
                images: imagesForTurn.isEmpty ? nil : imagesForTurn
            ))
            transcript.append((role: "user", text: promptText))

            // UserPromptSubmit hook fires once per user turn, before the model sees
            // the prompt. Rules can short-circuit work (lint prompt, log to audit)
            // but cannot modify the prompt — that would require reading stdout back,
            // which we don't support today.
            for cmd in hooks.commands(for: .userPromptSubmit) {
                await runHook(cmd, prompt: promptText, cwd: cwd)
            }

            // Per-turn work runs inside a Task so SIGINT can cancel just the turn
            // (via activeTurn.cancel()) instead of killing the process.
            let modeForTurn = mode
            let historyForTurn = history
            let currentModelForTurn = currentModel
            let verboseForTurn = verbose
            let cwdForTurn = cwd
            let colorOnForTurn = colorOn
            let toolRegistryForTurn = toolRegistry
            let clientForTurn = client
            let hooksForTurn = hooks

            queryActive.set(true)
            let turnTask = Task<TurnOutcome, Error> {
                var out = TurnOutcome()
                let mdRenderer = MarkdownRenderer(enabled: colorOnForTurn)
                switch modeForTurn {
                case .text:
                    let request = OpenAICompatClient.Request(model: currentModelForTurn, messages: historyForTurn)
                    for try await piece in clientForTurn.stream(request) {
                        try Task.checkCancellation()
                        switch piece {
                        case .content(let text):
                            out.assistantText += text
                            let rendered = mdRenderer.process(text)
                            FileHandle.standardOutput.write(Data(rendered.utf8))
                            out.lastNewline = text.hasSuffix("\n")
                        case .reasoning:
                            // Text mode doesn't render CoT; capture-only.
                            continue
                        case .toolCall:
                            continue
                        case .usage(let p, let c, _, _):
                            out.turnInput = p; out.turnOutput = c
                        case .done:
                            let flushed = mdRenderer.flush()
                            if !flushed.isEmpty { FileHandle.standardOutput.write(Data(flushed.utf8)) }
                            if !out.lastNewline { FileHandle.standardOutput.write(Data("\n".utf8)) }
                            for cmd in hooksForTurn.commands(for: .stop) {
                                await runHook(cmd, cwd: cwdForTurn)
                            }
                        }
                    }

                case .yolo, .ask:
                    let baseDecider: any PermissionDecider = (modeForTurn == .yolo)
                        ? AllowAllPermissionDecider()
                        : TTYPermissionDecider()
                    let settingsPatterns = SettingsPermissions.load(cwd: cwdForTurn)
                    let patternedDecider: any PermissionDecider = settingsPatterns.isEmpty
                        ? baseDecider
                        : PatternPermissionDecider(patterns: settingsPatterns, inner: baseDecider)
                    // Outermost layer: built-in security tripwires fire even under --yolo
                    // and even with permissive `allow` patterns in settings.json.
                    let decider: any PermissionDecider = HardcodedDenyDecider(patternedDecider)

                    // Add Task tool so the model can dispatch to user-defined
                    // subagents from .claude/agents/. Constructed per-turn so
                    // the parent's current model + decider flow through.
                    let taskTool = TaskTool(
                        client: clientForTurn,
                        defaultModel: currentModelForTurn,
                        decider: decider,
                        parentToolRegistry: toolRegistryForTurn
                    )
                    let augmentedRegistry = ToolRegistry(
                        Array(toolRegistryForTurn.executors.values) + [taskTool]
                    )
                    let agent = OpenAICompatAgent(client: clientForTurn)
                    let agentOptions = OpenAICompatAgentOptions(
                        cwd: cwdForTurn,
                        model: currentModelForTurn,
                        systemPrompt: OpenAICompatAgentPrompt.systemPrompt(
                            cwd: cwdForTurn,
                            toolNames: augmentedRegistry.specs.map { $0.name }
                        ),
                        tools: augmentedRegistry,
                        decider: decider
                    )
                    // Pass the REPL's own history in so tool-call / tool-result exchanges
                    // survive into future turns. The agent yields .conversationSnapshot at the end,
                    // and we replace `history` with it via the returned outcome.
                    // We track lastToolName/lastToolInput across events so PostToolUse hooks
                    // can reference the tool that just produced the result.
                    var lastToolName = ""
                    var lastToolInput = ""

                    // Spinner shown during model-thinking / tool-execution gaps
                    // so users see motion while waiting on a long pip install
                    // or a slow first token. Same lifecycle as the Claude REPL:
                    // start on entry, stop when visible output arrives, restart
                    // after tool result while the model thinks again.
                    var spinnerTask: Task<Void, Never>? = nil
                    func startSpinner(_ label: String) {
                        guard !CLIEnvironment.quiet, colorOnForTurn else { return }
                        spinnerTask?.cancel()
                        spinnerTask = Task {
                            let frames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
                            var i = 0
                                    while !Task.isCancelled {
                                // A /dev/tty permission prompt is on screen. Our
                                // \r would overwrite the question the user is
                                // being asked, so clear our line once and stay
                                // quiet until they've answered.
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
                            // Erase the last spinner frame when the task ends —
                            // UNLESS a /dev/tty permission prompt is on screen,
                            // in which case this \r + clear would wipe the very
                            // question the user is answering. (The decider draws
                            // its own line; leave it alone.)
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
                    defer { stopSpinner() }

                    for try await event in agent.runConversation(initial: historyForTurn, options: agentOptions) {
                        try Task.checkCancellation()
                        switch event {
                        case .thinking:
                            continue
                        case .assistantText(let t):
                            stopSpinner()
                            out.assistantText += t
                            let rendered = mdRenderer.process(t)
                            FileHandle.standardOutput.write(Data(rendered.utf8))
                            out.lastNewline = t.hasSuffix("\n")
                        case .toolCallRequested(let name, let args, _):
                            stopSpinner()
                            lastToolName = name
                            lastToolInput = args
                            if verboseForTurn {
                                FileHandle.standardError.write(Data("\n[tool: \(name) \(args)]\n".utf8))
                            } else {
                                FileHandle.standardError.write(Data("\n[\(name)]".utf8))
                            }
                            for cmd in hooksForTurn.commands(for: .preToolUse, toolName: name) {
                                await runHook(cmd, toolName: name, toolInput: args, cwd: cwdForTurn)
                            }
                            // Tool is about to run — or to sit on a permission
                            // prompt. This loop has no permissionRequested event
                            // to key off (unlike the Claude loop, which starts
                            // its spinner on permissionResolved), so the spinner
                            // starts here and yields via TTYPromptState if a
                            // prompt appears. Without that it repaints over the
                            // prompt every 80ms and mangles it.
                            startSpinner("running \(name)…")
                        case .permissionDenied(let name, let reason, _):
                            stopSpinner()
                            FileHandle.standardError.write(Data("\n[denied \(name): \(reason)]\n".utf8))
                        case .toolResult(let content, _, let isError, _):
                            stopSpinner()
                            let marker = isError ? "✗ " : "✓ "
                            FileHandle.standardError.write(Data(marker.utf8))
                            // Counter for the dashboard's `Read×9 · Edit×4` row.
                            // Both successful and errored calls count — they all
                            // consumed model attention and time.
                            if !lastToolName.isEmpty {
                                out.toolCounts[lastToolName, default: 0] += 1
                            }
                            for cmd in hooksForTurn.commands(for: .postToolUse, toolName: lastToolName) {
                                await runHook(
                                    cmd,
                                    toolName: lastToolName,
                                    toolInput: lastToolInput,
                                    toolResult: content,
                                    cwd: cwdForTurn
                                )
                            }
                            // Result is in; model now reasons about it.
                            startSpinner("thinking…")
                        case .turnComplete(let p, let c, _, _):
                            if let p = p { out.turnInput += p }
                            if let c = c { out.turnOutput += c }
                        case .conversationSnapshot(let finalMessages):
                            out.snapshotHistory = finalMessages
                        case .deepseekConversationSnapshot:
                            // REPL is OpenAI-compat-only; this case can't fire here.
                            continue
                        case .done:
                            stopSpinner()
                            let flushed = mdRenderer.flush()
                            if !flushed.isEmpty { FileHandle.standardOutput.write(Data(flushed.utf8)) }
                            if !out.lastNewline { FileHandle.standardOutput.write(Data("\n".utf8)) }
                            for cmd in hooksForTurn.commands(for: .stop) {
                                await runHook(cmd, cwd: cwdForTurn)
                            }
                        }
                    }
                }
                return out
            }
            activeTurn.set(turnTask)

            let outcome: TurnOutcome
            do {
                outcome = try await turnTask.value
            } catch is CancellationError {
                queryActive.set(false); activeTurn.set(nil)
                FileHandle.standardError.write(Data(ANSI.styled("\n(turn cancelled)\n", ANSI.yellow, fd: STDERR_FILENO).utf8))
                if history.last?.role == "user" { history.removeLast() }
                if transcript.last?.role == "user" { transcript.removeLast() }
                continue
            } catch {
                queryActive.set(false); activeTurn.set(nil)
                FileHandle.standardError.write(Data(ANSI.styled("error: \(error.localizedDescription)\n", ANSI.red, fd: STDERR_FILENO).utf8))
                if history.last?.role == "user" { history.removeLast() }
                if transcript.last?.role == "user" { transcript.removeLast() }
                continue
            }
            queryActive.set(false); activeTurn.set(nil)

            let assistantText = outcome.assistantText
            let turnInput = outcome.turnInput
            let turnOutput = outcome.turnOutput
            if let snapshot = outcome.snapshotHistory { history = snapshot }
            // Fold this turn's per-tool counts into the session totals.
            for (name, n) in outcome.toolCounts {
                toolCounts[name, default: 0] += n
            }

            if !assistantText.isEmpty {
                // In agentic modes the conversation snapshot already placed the final
                // assistant message (plus tool_call / tool_result entries) into `history`.
                // Only append manually on the text-only path.
                if mode == .text {
                    history.append(.init(role: "assistant", content: assistantText))
                }
                transcript.append((role: "assistant", text: assistantText))
            }

            // Persist after every turn so --continue / --resume can pick up where we left off.
            let now = Date()
            OpenAICompatSessionStore.save(.init(
                id: sessionId,
                cwd: cwd.standardizedFileURL.path,
                provider: providerName,
                model: currentModel,
                createdAt: now,
                updatedAt: now,
                messages: history
            ))
            turnCount += 1
            totalInput += turnInput
            totalOutput += turnOutput

            if let cfg = statusLineConfig {
                let usd: Double = {
                    guard let r = Pricing.rate(for: currentModel) else { return 0 }
                    return Pricing.estimate(inputTokens: totalInput, outputTokens: totalOutput, rate: r)
                }()
                let payload = StatusLine.Payload(
                    sessionId: sessionId, model: currentModel, turn: turnCount,
                    inputTokens: totalInput, outputTokens: totalOutput,
                    costUSD: usd, cwd: cwd.path
                )
                statusLineCache = await StatusLine.render(config: cfg, payload: payload, cwd: cwd)
            }

            if colorOn, (turnInput + turnOutput) > 0 {
                let nf = NumberFormatter(); nf.numberStyle = .decimal
                let i = nf.string(from: NSNumber(value: turnInput))  ?? "\(turnInput)"
                let o = nf.string(from: NSNumber(value: turnOutput)) ?? "\(turnOutput)"
                FileHandle.standardError.write(Data(
                    ANSI.styled("↑ \(i) ↓ \(o) tokens\n", ANSI.dim, fd: STDERR_FILENO).utf8
                ))
            }
        }
    }

    // MARK: - Helpers

    /// Multi-line dashboard rendered above the prompt each turn. Each row
    /// is conditional — empty inputs (no git, no tools yet, no todos) are
    /// dropped so an empty session still renders cleanly. TTY-gated so
    /// piped output stays free of ANSI sequences.
    ///
    /// Layout:
    ///   ⎇ branch* · 📁 project · ⏱ 1h2m · ask · model
    ///   Ctx [▰▰▰░░░░░░░] 31% · 1 CLAUDE.md · 4 hooks · 1 MCP · 2 agents · 5t · $0.012
    ///   ✓ Read×9 · Edit×4 · Write×2 · Bash×3
    ///   ✓ Todos 4/6 (1 in progress)
    private func renderDashboard(
        cwd: URL,
        mode: AgentMode,
        model: String,
        totalInput: Int,
        totalOutput: Int,
        turnCount: Int,
        mcpCount: Int,
        hooks: HooksConfig,
        hasClaudeMd: Bool,
        toolCounts: [String: Int],
        sessionStart: Date
    ) async -> String {
        guard isatty(STDOUT_FILENO) != 0 else { return "" }
        var lines: [String] = []

        // Row 1: branch · project · session time · mode · model
        var row1: [String] = []
        if let branch = GitBranchProbe.current(at: cwd) {
            let dirty = GitBranchProbe.isDirty(at: cwd) ? "*" : ""
            row1.append("⎇ \(branch)\(dirty)")
        }
        let project = cwd.lastPathComponent
        if !project.isEmpty { row1.append("📁 \(project)") }
        row1.append("⏱ \(Self.formatDuration(Date().timeIntervalSince(sessionStart)))")
        switch mode {
        case .text: row1.append("text")
        case .yolo: row1.append("yolo")
        case .ask:  row1.append("ask")
        }
        if !model.isEmpty { row1.append(Self.shortModelName(model)) }
        lines.append(row1.joined(separator: " · "))

        // Row 2: context bar + resource counts + turn + cost
        var row2: [String] = []
        let total = totalInput + totalOutput
        if total > 0 {
            let window = Self.contextWindowSize(for: model)
            let pct = min(100, Int(Double(total) / Double(window) * 100.0))
            row2.append("Ctx \(Self.progressBar(percent: pct, width: 10)) \(pct)%")
        }
        if hasClaudeMd { row2.append("1 CLAUDE.md") }
        let hookCount = hooks.rules.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.hooks.count } }
        if hookCount > 0 { row2.append("\(hookCount) hook\(hookCount == 1 ? "" : "s")") }
        if mcpCount > 0 { row2.append("\(mcpCount) MCP\(mcpCount == 1 ? "" : "s")") }
        let agents = Subagent.list(cwd: cwd)
        if !agents.isEmpty { row2.append("\(agents.count) agent\(agents.count == 1 ? "" : "s")") }
        if turnCount > 0 { row2.append("\(turnCount)t") }
        if let rate = Pricing.rate(for: model) {
            let usd = (Double(totalInput) * rate.inputPer1M + Double(totalOutput) * rate.outputPer1M) / 1_000_000.0
            if usd >= 0.001 { row2.append(Pricing.formatUSD(usd)) }
        }
        if !row2.isEmpty { lines.append(row2.joined(separator: " · ")) }

        // Row 3: per-tool invocation counts (sorted desc by count for readability).
        if !toolCounts.isEmpty {
            let parts = toolCounts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                .map { "\($0.key)×\($0.value)" }
            lines.append("✓ " + parts.joined(separator: " · "))
        }

        // Row 4: TodoWrite progress (only when the model has actually used it).
        let todos = await TodoStore.shared.snapshot()
        if !todos.isEmpty {
            let done = todos.filter { $0.status == "completed" }.count
            let inProg = todos.filter { $0.status == "in_progress" }.count
            var s = "✓ Todos \(done)/\(todos.count)"
            if inProg > 0 { s += " (\(inProg) in progress)" }
            lines.append(s)
        }

        return ANSI.styled(lines.joined(separator: "\n"), ANSI.dim, fd: STDOUT_FILENO)
    }

    /// "1h2m" / "12m34s" / "45s" — compact, never zero-padded, drops the
    /// most-significant zero for readability. Matches Claude Code's "3h 5m"
    /// look (without the space — terminals don't need it).
    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return "\(h)h\(m)m" }
        if m > 0 { return "\(m)m\(sec)s" }
        return "\(sec)s"
    }

    /// Unicode block-element progress bar. `pct` clamped to 0...100.
    /// Uses ▰ for filled and ░ for empty so it renders identically across
    /// monospace fonts (no half-step glyphs that some fonts skip).
    private static func progressBar(percent: Int, width: Int) -> String {
        let filled = max(0, min(width, percent * width / 100))
        let empty = width - filled
        return "[" + String(repeating: "▰", count: filled) + String(repeating: "░", count: empty) + "]"
    }

    /// Best-effort context window per model family. Used by the dashboard's
    /// `ctx N%` indicator. Most modern OpenAI-compat models are 128k; only
    /// the long-context families need a bigger denominator.
    private static func contextWindowSize(for model: String) -> Int {
        let m = model.lowercased()
        if m.contains("gemini-2.5") { return 2_000_000 }
        if m.contains("gemini-3") { return 2_000_000 }
        if m.contains("gemini") { return 1_000_000 }
        if m.contains("llama-4") || m.contains("llama4") { return 1_000_000 }
        if m.contains("o1") || m.contains("o3") { return 200_000 }
        if m.contains("claude") { return 200_000 }
        return 128_000
    }

    /// Strip provider prefixes from `provider/model-name` so the dashboard
    /// stays readable: `anthropic/claude-sonnet-4` → `claude-sonnet-4`.
    private static func shortModelName(_ full: String) -> String {
        if let slash = full.lastIndex(of: "/") {
            return String(full[full.index(after: slash)...])
        }
        return full
    }

    private func buildPrompt(turnCount: Int, colorOn: Bool, statusLineSuffix: String? = nil) -> String {
        if let s = statusLineSuffix, !s.isEmpty {
            return ANSI.styled("\(s)> ", ANSI.bold, ANSI.blue, fd: STDOUT_FILENO)
        }
        let info = turnCount > 0 ? " [\(turnCount)t]" : ""
        return ANSI.styled("lingcode(\(providerName))\(info)> ", ANSI.bold, ANSI.blue, fd: STDOUT_FILENO)
    }

    private func printBanner(provider: String, model: String, mode: AgentMode, colorOn: Bool) {
        guard colorOn else { return }
        let modeLine = "\(mode.label) · /help · Ctrl-C to exit"
        let banner = """
        \(ANSI.styled("╭────────────────────────────────────────╮", ANSI.blue, fd: STDOUT_FILENO))
        \(ANSI.styled("│", ANSI.blue, fd: STDOUT_FILENO))  LingCode (\(provider)) · \(model.padding(toLength: 22, withPad: " ", startingAt: 0))\(ANSI.styled("│", ANSI.blue, fd: STDOUT_FILENO))
        \(ANSI.styled("│", ANSI.blue, fd: STDOUT_FILENO))  \(modeLine.padding(toLength: 38, withPad: " ", startingAt: 0))\(ANSI.styled("│", ANSI.blue, fd: STDOUT_FILENO))
        \(ANSI.styled("╰────────────────────────────────────────╯", ANSI.blue, fd: STDOUT_FILENO))
        """
        Swift.print(banner)
    }

    /// Names (without leading `/`) of the REPL's built-in slash commands.
    /// Used to decide whether an unrecognised token should be dispatched as a
    /// user-defined command from `.claude/commands/`.
    static let builtinSlashCommandNames: Set<String> = [
        "quit", "exit", "q",
        "help", "?",
        "clear",
        "model", "reset", "system",
        "cost", "export",
        "tools", "mcp", "commands", "skills", "agents", "image", "output-styles", "outputstyles",
        "yolo", "ask", "safe", "text",
        "mode", "session",
    ]

    private static func completions(forBuffer buffer: String, cwd: URL) -> [String] {
        guard buffer.hasPrefix("/") else { return [] }
        let query = String(buffer.dropFirst()).lowercased()
        var all = ["/quit", "/exit", "/help", "/clear", "/model", "/reset", "/system",
                   "/cost", "/export", "/yolo", "/ask", "/safe", "/mode", "/tools",
                   "/mcp", "/session", "/commands"]
        for c in CustomSlashCommands.all(cwd: cwd) {
            let scope = c.source == .project ? "project" : "user"
            all.append("/\(scope):\(c.name)")
        }
        if query.isEmpty { return all.sorted() }
        return all.filter { $0.dropFirst().lowercased().hasPrefix(query) }.sorted()
    }

    static func initialMode(yolo: Bool, permissionMode: String?) -> AgentMode {
        if yolo { return .yolo }
        switch (permissionMode ?? "").lowercased() {
        case "bypasspermissions", "acceptedits":  return .yolo
        case "text", "safe", "chat":              return .text
        // The OpenAI-compat REPL used to default to text-only chat, which
        // surprised users coming from the Claude path: typing "build me a
        // site" only produced instructions, never a Write call. Match the
        // Claude default — tools are on, gated by per-call TTY prompts —
        // so the experience feels the same regardless of provider.
        default:                                  return .ask
        }
    }
}

/// Aggregate mutations a single REPL turn produces. Returned from the per-turn
/// `Task` so the outer loop can apply them (Task closures are `@Sendable` and
/// cannot capture `var`s by reference, so we marshal updates through a value).
struct TurnOutcome: Sendable {
    var assistantText: String = ""
    var lastNewline: Bool = true
    var turnInput: Int = 0
    var turnOutput: Int = 0
    var snapshotHistory: [OpenAICompatClient.Message]? = nil
    /// Per-tool invocation counts emitted during this turn. Merged into the
    /// REPL's session-wide totals so the dashboard can show `Read×9 · Edit×4`.
    var toolCounts: [String: Int] = [:]
}

/// Lock-guarded handle to the currently running turn `Task`, so the SIGINT
/// handler can cancel it without racing with the REPL loop that assigns it.
final class TurnTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<TurnOutcome, Error>?

    func set(_ task: Task<TurnOutcome, Error>?) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let t = task
        lock.unlock()
        t?.cancel()
    }
}
