import ArgumentParser
import Foundation
import LingCodeAgentCore

/// `lingcode export` — convenience wrapper that resumes a session and asks the
/// model to dump the conversation as markdown. With no arguments, opens an
/// interactive picker over recent sessions for the current cwd. Mirrors the
/// REPL's `/export` slash command but works from the shell, so users can pipe
/// to a file or commit a transcript without launching the REPL.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a saved session's transcript as markdown.",
        discussion: """
        Examples:
          lingcode export                              # interactive picker, prints to stdout
          lingcode export --last                       # most-recent session for this cwd
          lingcode export 7bb9f57f --output chat.md    # specific session, write to file
        """
    )

    @Argument(help: "Session ID (full or 8-char prefix). Omit to pick interactively.")
    var session: String?

    @Flag(name: .long, help: "Use the most recent session for this directory (skip the picker).")
    var last: Bool = false

    @Option(name: .shortAndLong, help: "Write to this file instead of stdout.")
    var output: String?

    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resolvedId: String
        if let s = session, !s.isEmpty {
            resolvedId = try resolveSessionId(prefix: s, cwd: cwd)
        } else if last {
            guard let id = SessionStore.loadLast(forCwd: cwd) else {
                FileHandle.standardError.write(Data("lingcode: no recent session for this directory.\n".utf8))
                throw ExitCode(1)
            }
            resolvedId = id
        } else {
            resolvedId = try pickSessionInteractively(cwd: cwd)
        }

        // Spawn a child `lingcode ask --resume <id>` with a prompt that asks
        // the model to output the full transcript as markdown. Cheaper than
        // re-implementing the bridge from scratch for this one-off.
        let exe = ProcessInfo.processInfo.arguments.first ?? "lingcode"
        var args: [String] = [
            "ask", "--resume", resolvedId, "--quiet"
        ]
        if let out = output {
            args += ["--output", out]
        }
        args += [
            "Output our entire conversation so far as a single Markdown document. " +
            "Use # for the title, then chronological turns under ## headings (User / Assistant). " +
            "Include code blocks for any code shared. Don't add commentary — just the transcript."
        ]
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 { throw ExitCode(proc.terminationStatus) }
    }

    private func resolveSessionId(prefix: String, cwd: URL) throws -> String {
        // Accept both full UUIDs and 8-char prefixes against history.
        if prefix.count >= 32 { return prefix }
        let entries = SessionHistory.loadForCwd(cwd) + SessionHistory.loadAll()
        let lower = prefix.lowercased()
        if let match = entries.first(where: { $0.sessionId.lowercased().hasPrefix(lower) }) {
            return match.sessionId
        }
        FileHandle.standardError.write(Data("lingcode: no session matches prefix '\(prefix)'.\n".utf8))
        throw ExitCode(1)
    }

    private func pickSessionInteractively(cwd: URL) throws -> String {
        let entries = SessionHistory.loadForCwd(cwd)
        guard !entries.isEmpty else {
            FileHandle.standardError.write(Data("lingcode: no session history for this directory. Pass a session id or run `lingcode --continue` to start one.\n".utf8))
            throw ExitCode(1)
        }
        guard let tty = TTYIO.open() else {
            FileHandle.standardError.write(Data("lingcode: cannot open /dev/tty for picker. Pass a session id explicitly.\n".utf8))
            throw ExitCode(1)
        }
        defer { tty.close() }
        let labels = entries.prefix(15).map { e -> String in
            let preview = e.promptPreview.isEmpty ? "(no preview)" : e.promptPreview
            return "\(String(e.sessionId.prefix(8)))  \(preview)"
        }
        guard let idx = tty.pick(prompt: "Export which session? (↑↓ Enter):", items: labels) else {
            throw ExitCode(130)
        }
        return entries[idx].sessionId
    }
}
