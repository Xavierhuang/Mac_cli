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

        Default location is ~/LingCodeProjects/<slug>/ where <slug> is derived from
        the brief plus a timestamp. Override with --out.

        Examples:
          lingcode build "ios todo app with reminders"
          lingcode build "rust cli for parsing nginx logs" --out ~/work/nginx-parser
          lingcode build "minimal vue dashboard" --no-open
        """
    )

    @Argument(help: "Brief: what to build, in plain English. Quote multi-word prompts.")
    var brief: [String] = []

    @Option(name: .shortAndLong, help: "Output directory (default: ~/LingCodeProjects/<slug>).")
    var out: String?

    @Flag(name: .long, help: "Skip launching LingCode (scaffold only).")
    var noOpen: Bool = false

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
