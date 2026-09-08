import ArgumentParser
import Foundation
import LingCodeAgentCore

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Scaffold a project and kick off an autonomous Claude build.",
        discussion: """
        Creates a fresh project directory, writes BRIEF.md with your prompt, then
        launches LingCode focused on the new project. The Claude Code tab auto-fires
        the brief in fully-autonomous mode (destructive operations still blocked).

        With --headless the agent runs here instead of in LingCode.app: no GUI, no 2FA.
        With --ship it goes further — after the build verifies it archives and uploads to
        TestFlight. Verification is objective: each round is judged by whether xcodebuild
        exits 0, and failures are fed back to the agent, bounded by --verify-rounds.

        With --listing it goes all the way: upload, wait out Apple's 5–30 minutes of
        processing, read the finished source to write the App Store description,
        keywords, promotional text and release notes, and submit them. One command from
        a sentence to a filled-in App Store listing.

        A brand-new app still needs its App Store Connect record created once, in Xcode
        (Distribute App → TestFlight Internal Only) or on the website. Nothing in this CLI
        can create it. --ship stops with that instruction rather than a bare altool error.

        --listing writes metadata only. It never submits for App Review: that additionally
        needs screenshots, App Privacy and an Age Rating, none of which have an API, and
        it is not a decision a build command should make for you.

        Default location is ~/LingCodeProjects/<slug>/ where <slug> is derived from
        the brief plus a timestamp. Override with --out.

        Examples:
          lingcode build "ios todo app with reminders"
          lingcode build "rust cli for parsing nginx logs" --out ~/work/nginx-parser
          lingcode build "minimal vue dashboard" --no-open
          lingcode build "ios habit tracker" --listing --yolo    # idea → App Store listing
        """
    )

    @Argument(help: "Brief: what to build, in plain English. Quote multi-word prompts.")
    var brief: [String] = []

    @Option(name: .shortAndLong, help: "Output directory (default: ~/LingCodeProjects/<slug>).")
    var out: String?

    @Flag(name: .long, help: "Skip launching LingCode (scaffold only).")
    var noOpen: Bool = false

    @Flag(name: .long, help: "Run the agent here instead of handing off to LingCode.app. No GUI, no 2FA, suitable for CI.")
    var headless: Bool = false

    @Flag(name: .long, help: "After the build verifies, archive and upload to TestFlight. Implies --headless.")
    var ship: Bool = false

    @Flag(name: .long, help: "After the upload, wait for Apple to process it, write the App Store listing copy from the source, and submit it. Implies --ship. Metadata only — never submits for App Review.")
    var listing: Bool = false

    @Option(name: .long, help: "How many times to feed build failures back to the agent before giving up. 0 disables verification.")
    var verifyRounds: Int = 3

    @Option(name: .long, help: "Maximum agent turns per round.")
    var maxTurns: Int = 50

    @Flag(name: .long, help: "Auto-allow every tool call during the autonomous run. Required for a genuinely unattended session.")
    var yolo: Bool = false

    @Option(name: .long, help: "Provider for the autonomous run: claude (default, your Anthropic key) or lingmodel (LingCode's hosted routing).")
    var provider: String = "claude"

    @Option(name: .long, help: "Override the model, e.g. claude-sonnet-4-6.")
    var model: String?

    func run() async throws {
        let briefText = brief.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !briefText.isEmpty else {
            FileHandle.standardError.write(Data(
                "lingcode build: brief is required. Example: lingcode build \"ios todo app\"\n".utf8
            ))
            throw ExitCode(2)
        }

        let targetDir = resolveTargetDir(briefText: briefText)
        let fm = FileManager.default
        if fm.fileExists(atPath: targetDir.path) {
            FileHandle.standardError.write(Data(
                "lingcode build: \(targetDir.path) already exists. Pick a different --out or remove it first.\n".utf8
            ))
            throw ExitCode(1)
        }

        // Session lifecycle for the build session. Fires before scaffolding starts;
        // SessionEnd fires on clean completion only. Early `return` on --no-open
        // and the `throw ExitCode` guards above do NOT fire SessionEnd — same
        // limitation as the Ask/Repl wiring.
        let _sessionId = await SessionLifecycleHook.fireStart(
            command: "build",
            provider: "n/a",
            model: "n/a",
            cwd: targetDir
        )
        SessionLifecycleHook.installSignalHandlers(
            sessionId: _sessionId,
            provider: "n/a",
            model: "n/a",
            cwd: targetDir,
            turnCountProvider: { 0 }
        )

        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let lingcodeDir = targetDir.appendingPathComponent(".lingcode")
        try fm.createDirectory(at: lingcodeDir, withIntermediateDirectories: true)

        try writeBriefDoc(briefText: briefText, in: targetDir)
        try writeGitignore(in: targetDir)
        try writePendingBuildMarker(briefText: briefText, in: lingcodeDir)
        gitInitAndCommit(in: targetDir)

        Swift.print("✓ Scaffolded \(targetDir.path)")

        // Autonomous path: run the agent in this process, verify what it produced
        // against xcodebuild rather than its own say-so, then optionally ship.
        if headless || ship || listing {
            let ok = await runAutonomously(briefText: briefText, targetDir: targetDir)
            await SessionLifecycleHook.fireEnd(
                sessionId: _sessionId, provider: "claude", model: "n/a",
                cwd: targetDir, turnCount: 0, terminatedBy: ok ? "completion" : "error"
            )
            if !ok { throw ExitCode(1) }
            return
        }

        if noOpen {
            Swift.print("(--no-open) Skipped launching LingCode.")
            await SessionLifecycleHook.fireEnd(
                sessionId: _sessionId, provider: "n/a", model: "n/a",
                cwd: targetDir, turnCount: 0, terminatedBy: "completion"
            )
            return
        }

        try openInLingCode(targetDir: targetDir)
        Swift.print("✓ Opening in LingCode...")

        await SessionLifecycleHook.fireEnd(
            sessionId: _sessionId, provider: "n/a", model: "n/a",
            cwd: targetDir, turnCount: 0, terminatedBy: "completion"
        )
    }

    // MARK: - Steps

    private func resolveTargetDir(briefText: String) -> URL {
        if let out = out, !out.isEmpty {
            return URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("LingCodeProjects")
            .appendingPathComponent(makeSlug(from: briefText))
    }

    private func writeBriefDoc(briefText: String, in dir: URL) throws {
        let doc = """
        # Brief

        \(briefText)

        ---

        ## How to approach this

        1. **Plan first.** Use the TodoWrite tool to break this brief into a concrete,
           ordered list of tasks before writing any code. Cover scaffold, dependencies,
           core implementation, build/run verification, and a sanity check at the end.
        2. **Execute one task at a time.** Mark each todo `in_progress` when you start
           it, `completed` only when it's actually done. Keep exactly one in-progress.
        3. **Verify as you go.** After implementation tasks, run the relevant build/test
           command (e.g. `cargo build`, `swift build`, `npm run build`) before marking
           the task complete. Don't claim something works without checking.
        4. **Update this BRIEF.md** if the scope evolves, so the doc stays the source
           of truth for what was built.

        > Generated by `lingcode build`. This file is the starting prompt for the
        > Claude Code agent in Autonomous Build mode.
        """
        try doc.write(to: dir.appendingPathComponent("BRIEF.md"), atomically: true, encoding: .utf8)
    }

    private func writeGitignore(in dir: URL) throws {
        let gitignore = """
        # macOS
        .DS_Store

        # Build outputs
        DerivedData/
        build/
        .build/
        node_modules/

        # LingCode build kickoff markers (one-shot; safe to keep ignored)
        .lingcode/pending-*.json
        """
        try gitignore.write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    }

    private func writePendingBuildMarker(briefText: String, in lingcodeDir: URL) throws {
        let marker = PendingBuildMarker(
            version: 1,
            brief: briefText,
            autonomy: "auto",
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(marker)
        try data.write(to: lingcodeDir.appendingPathComponent("pending-build.json"))
    }

    private func gitInitAndCommit(in dir: URL) {
        // Best-effort: scaffold is still useful even if git is missing or commit fails.
        _ = runProcess("/usr/bin/env", args: ["git", "init", "-q"], in: dir)
        _ = runProcess("/usr/bin/env", args: ["git", "add", "-A"], in: dir)
        _ = runProcess("/usr/bin/env",
                       args: ["git", "commit", "-q", "-m", "Initial scaffold from lingcode build"],
                       in: dir)
    }

    // MARK: - Autonomous run

    /// Scaffold → agent → verify → (optionally) ship, without a GUI.
    ///
    /// The verification loop is the point. An agent reporting "done" is not
    /// evidence, so each round is judged by whether `xcodebuild` exits 0; failures
    /// are fed back verbatim as the next prompt. Bounded by `--verify-rounds` so a
    /// stuck agent can't loop forever.
    private func runAutonomously(briefText: String, targetDir: URL) async -> Bool {
        let permissionMode = yolo ? "bypassPermissions" : "acceptEdits"

        let normalizedProvider = provider.lowercased()
        guard ["claude", "lingmodel", "deepseek-claude"].contains(normalizedProvider) else {
            FileHandle.standardError.write(Data(
                "lingcode build: --provider must be claude, lingmodel, or deepseek-claude (got '\(provider)').\n".utf8
            ))
            return false
        }
        let useLingModel = normalizedProvider == "lingmodel"
        let useDeepSeekDirect = normalizedProvider == "deepseek-claude"

        var prompt = """
        Build the project described in BRIEF.md, which is in this directory.

        \(briefText)

        Requirements:
        - Produce a project that actually compiles. If it's an Apple app, there must be a
          buildable .xcodeproj at the root — use `lingcode generate-xcodeproj` if you have
          only loose Swift files.
        - Don't ask questions; make reasonable choices and record them in BRIEF.md.
        - Stop when the project builds, not when you think the code looks right.
        """

        var round = 0
        while true {
            round += 1
            Swift.print("\n▶ Agent round \(round)…")
            do {
                _ = try await runHeadlessClaude(
                    prompt: prompt,
                    project: targetDir.path,
                    yolo: yolo,
                    permissionMode: permissionMode,
                    modelOverride: model,
                    includeClaudeMd: true,
                    resumeSessionId: nil,
                    maxTurns: maxTurns,
                    suppressOutput: false,
                    useLingModel: useLingModel,
                    useDeepSeekDirect: useDeepSeekDirect
                )
            } catch {
                FileHandle.standardError.write(Data("lingcode build: agent run failed: \(error)\n".utf8))
                return false
            }

            guard verifyRounds > 0 else {
                Swift.print("(--verify-rounds 0) Skipping verification.")
                break
            }

            switch await verify(targetDir: targetDir) {
            case .noProject:
                // Nothing to compile — a non-Apple project, or the agent never made one.
                // Not a failure on its own, but nothing downstream can use it either.
                Swift.print("⚠ No .xcodeproj found — skipping build verification.")
                if ship || listing {
                    FileHandle.standardError.write(Data(
                        "lingcode build: --ship needs a buildable Apple project and none was produced.\n".utf8
                    ))
                    return false
                }
                return true
            case .success:
                Swift.print("✓ Build verified.")
                break
            case .failure(let log):
                if round >= verifyRounds {
                    FileHandle.standardError.write(Data(
                        "lingcode build: still failing to build after \(round) round(s). Last errors:\n\(log)\n".utf8
                    ))
                    return false
                }
                Swift.print("✗ Build failed — feeding errors back (round \(round + 1) of \(verifyRounds)).")
                prompt = """
                The project does not compile. Fix these errors, then verify by building again.
                Do not change scope or add features — only make it build.

                \(log)
                """
                continue
            }
            break
        }

        guard ship || listing else { return true }

        guard #available(macOS 13, *) else {
            FileHandle.standardError.write(Data("lingcode build: --ship requires macOS 13 or later.\n".utf8))
            return false
        }
        guard await shipIt(targetDir: targetDir) else { return false }
        guard listing else { return true }
        return await writeListing(targetDir: targetDir)
    }

    /// The last leg: upload → wait out Apple's processing → write the listing.
    ///
    /// Runs `submit` as a child rather than calling into it, so there is exactly
    /// one implementation of metadata submission and one place where the
    /// placeholder-URL and character-limit rules live.
    ///
    /// Deliberately does NOT pass --review. A first submission still needs
    /// screenshots, App Privacy, and an Age Rating, none of which have an API;
    /// putting an app in front of App Review is also not something a build
    /// command should do without being asked.
    @available(macOS 13, *)
    private func writeListing(targetDir: URL) async -> Bool {
        Swift.print("▶ Waiting for processing, then writing the App Store listing…")
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        var args = ["submit", targetDir.path, "--generate", "--wait", "30", "--provider", provider]
        if let model { args += ["--model", model] }
        let code = runProcess(exe, args: args, in: targetDir)
        if code == 0 {
            Swift.print("✓ App Store listing written.")
            return true
        }
        FileHandle.standardError.write(Data("""
        lingcode build: the upload succeeded but the listing did not go through (exit \(code)).
        The build is on TestFlight regardless. Re-run just the last step with:
          lingcode submit "\(targetDir.path)" --generate --wait 30

        """.utf8))
        return false
    }

    private enum VerifyOutcome {
        case success
        case failure(String)
        case noProject
    }

    /// Compiles the project. Deliberately the objective gate: the agent's own
    /// account of its work is not consulted.
    /// The destination to verify against, chosen from what the project actually
    /// supports rather than assumed.
    ///
    /// This used to be hardcoded to `generic/platform=iOS`. Anything that isn't an
    /// iOS app — a macOS app, a Swift package — then failed verification with
    /// "Unable to find a destination matching the provided destination specifier"
    /// on code that compiled perfectly well, burned every `--verify-rounds`
    /// retry feeding that non-error back to the agent, and exited non-zero.
    /// Measured: a scaffolded macOS SwiftUI app lost 173 seconds and reported
    /// "still failing to build after 3 round(s)" while `xcodebuild` succeeded the
    /// moment the right destination was passed (benchmarks/xcode, brief 001).
    ///
    /// iOS stays the preferred answer when a project supports both, since that is
    /// what `lingcode build` mostly scaffolds; macOS is the fallback.
    private func verifyDestination(project: URL, scheme: String, in cwd: URL) async -> String {
        let probe = await runShell(
            "xcodebuild -project \"\(project.path)\" -scheme \"\(scheme)\" -showdestinations 2>&1",
            in: cwd
        )
        let out = probe.output
        // Simulator, not `generic/platform=iOS`: a device destination also needs
        // installed device support for the target OS, and without it xcodebuild
        // fails with "iOS <ver> is not installed" on a project that compiles
        // perfectly well. Verification asks whether the code builds, not whether
        // this Mac can sign for an attached phone.
        if out.contains("platform:iOS") { return "generic/platform=iOS Simulator" }
        if out.contains("platform:macOS") { return "platform=macOS" }
        if out.contains("platform:watchOS") { return "generic/platform=watchOS" }
        if out.contains("platform:tvOS") { return "generic/platform=tvOS" }
        if out.contains("platform:visionOS") { return "generic/platform=visionOS" }
        // Probe failed (bad scheme, project that won't even list). Fall back to the
        // historical default so behaviour is no worse than before.
        return "generic/platform=iOS"
    }

    private func verify(targetDir: URL) async -> VerifyOutcome {
        guard let xcodeproj = findXcodeProject(in: targetDir) else { return .noProject }
        Swift.print("▶ Verifying with xcodebuild…")
        let scheme = xcodeproj.deletingPathExtension().lastPathComponent
        let destination = await verifyDestination(project: xcodeproj, scheme: scheme, in: targetDir)
        let result = await runShell(
            "xcodebuild build -project \"\(xcodeproj.path)\" -scheme \"\(scheme)\" -destination '\(destination)' -quiet CODE_SIGNING_ALLOWED=NO",
            in: targetDir
        )
        if result.exitCode == 0 { return .success }
        // Only the error lines — feeding a full xcodebuild log back wastes the
        // agent's context on noise it can't act on.
        let errors = result.output
            .split(separator: "\n")
            .filter { $0.contains("error:") || $0.contains("warning: no rule") }
            .prefix(40)
            .joined(separator: "\n")
        return .failure(errors.isEmpty ? String(result.output.suffix(3000)) : errors)
    }

    @available(macOS 13, *)
    private func shipIt(targetDir: URL) async -> Bool {
        guard let credentials = Ship.resolveCredentials(), !credentials.teamID.isEmpty else {
            FileHandle.standardError.write(Data("""
            lingcode build: --ship needs App Store Connect credentials. See `lingcode ship --help`.
            """.utf8))
            return false
        }
        let uploader = ASCUploader()
        if let blocker = await uploader.preflight(teamID: credentials.teamID) {
            FileHandle.standardError.write(Data("lingcode build: \(blocker)\n".utf8))
            return false
        }
        Swift.print("▶ Shipping to TestFlight…")
        let result = await uploader.deploy(
            projectURL: targetDir,
            credentials: credentials,
            autoBumpBuild: true,
            onEvent: { event in
                if let line = event.log {
                    FileHandle.standardError.write(Data((line.hasSuffix("\n") ? line : line + "\n").utf8))
                }
            }
        )
        if result.succeeded {
            Swift.print("✓ Uploaded to App Store Connect.")
            return true
        }
        let message = result.errorMessage ?? "Upload failed."
        FileHandle.standardError.write(Data("lingcode build: \(message)\n".utf8))
        // The one step nothing here can automate — say so precisely rather than
        // leaving a bare altool failure. Xcode can create the record; this cannot.
        if message.contains("application record") || message.contains("Apple ID for Bundle ID") {
            FileHandle.standardError.write(Data("""

            The app has no App Store Connect record yet. Fastest fix: open the archive in
            Xcode → Distribute App → TestFlight Internal Only, which offers to create it.
            Then re-run with --ship. (Neither this CLI nor altool can create the record —
            the App Store Connect API rejects CREATE on `apps`.)

            """.utf8))
        }
        return false
    }

    private func findXcodeProject(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return items.first(where: { $0.pathExtension == "xcodeproj" })
    }

    private func runShell(_ command: String, in cwd: URL) async -> (exitCode: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                let pipe = Pipe()
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                // System paths first — same rsync trap as ASCUploader.runCommand.
                proc.arguments = ["-l", "-c", "export PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH; " + command]
                proc.currentDirectoryURL = cwd
                proc.standardOutput = pipe
                proc.standardError = pipe
                do { try proc.run() } catch {
                    continuation.resume(returning: (-1, "launch failed: \(error.localizedDescription)"))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                continuation.resume(returning: (proc.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }

    private func openInLingCode(targetDir: URL) throws {
        var comps = URLComponents()
        comps.scheme = "lingcode"
        comps.host = "build"
        comps.queryItems = [URLQueryItem(name: "path", value: targetDir.path)]
        guard let url = comps.url else {
            FileHandle.standardError.write(Data(
                "lingcode build: failed to construct lingcode:// URL.\n".utf8
            ))
            throw ExitCode(1)
        }
        let exit = runProcess("/usr/bin/open", args: [url.absoluteString], in: nil)
        if exit != 0 {
            FileHandle.standardError.write(Data(
                "lingcode build: `open` exited with status \(exit). Is LingCode installed?\n".utf8
            ))
            throw ExitCode(1)
        }
    }

    // MARK: - Helpers

    /// Slugify the brief: keep first ~4 content words, hyphenate, append timestamp.
    /// Stopwords are dropped so "build me an ios todo app" → "ios-todo-app-<ts>".
    private func makeSlug(from text: String) -> String {
        let stopwords: Set<String> = [
            "a", "an", "the", "for", "with", "to", "in", "of", "and", "or",
            "build", "me", "make", "create", "new", "my",
        ]
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopwords.contains($0) }
            .prefix(4)
        let stem = words.isEmpty ? "project" : words.joined(separator: "-")

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        fmt.timeZone = TimeZone.current
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return "\(stem)-\(fmt.string(from: Date()))"
    }

    @discardableResult
    private func runProcess(_ launchPath: String, args: [String], in cwd: URL?) -> Int32 {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = args
        if let cwd = cwd {
            task.currentDirectoryURL = cwd
        }
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            return -1
        }
    }
}

private struct PendingBuildMarker: Codable {
    let version: Int
    let brief: String
    let autonomy: String
    let createdAt: String
}
