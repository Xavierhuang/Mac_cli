import ArgumentParser
import Foundation
import LingCodeAgentCore

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Generate a CLAUDE.md project documentation file.",
        discussion: """
        Analyzes the current project structure and generates a CLAUDE.md file that
        helps Claude understand your codebase, conventions, and build commands.
        Requires ANTHROPIC_API_KEY.
        """
    )

    @Option(name: .long, help: "Project directory (defaults to cwd).")
    var project: String?

    @Flag(name: .long, help: "Print generated content to stdout instead of writing to disk.")
    var print: Bool = false

    @Flag(name: .long, help: "Overwrite existing CLAUDE.md without prompting.")
    var force: Bool = false

    func run() async throws {
        let cwd: URL
        if let project = project, !project.isEmpty {
            cwd = URL(fileURLWithPath: (project as NSString).expandingTildeInPath)
        } else {
            cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }

        let claudeMdPath = cwd.appendingPathComponent("CLAUDE.md")

        if !print && !force && FileManager.default.fileExists(atPath: claudeMdPath.path) {
            guard let tty = TTYIO.open() else {
                FileHandle.standardError.write(Data("lingcode: CLAUDE.md already exists. Use --force to overwrite.\n".utf8))
                throw ExitCode(1)
            }
            tty.write("CLAUDE.md already exists. Overwrite? [y/N]: ")
            let answer = tty.readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            tty.close()
            guard answer == "y" || answer == "yes" else {
                Swift.print("Aborted.")
                throw ExitCode(0)
            }
        }

        let summary = buildProjectSummary(cwd: cwd)
        let initPrompt = buildInitPrompt(cwd: cwd, summary: summary)

        FileHandle.standardError.write(Data("Analyzing project… (this may take a moment)\n".utf8))

        let capturedText = try await runHeadlessClaude(
            prompt: initPrompt,
            project: cwd.path,
            yolo: false,
            permissionMode: "dontAsk",
            modelOverride: nil,
            includeClaudeMd: false,
            resumeSessionId: nil,
            attachments: [],
            maxTurns: 5,
            jsonOutput: false,
            outputFile: nil,
            suppressOutput: !self.print  // stream to stdout only when --print is requested
        )

        let cleaned = stripCodeFences(capturedText)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            FileHandle.standardError.write(Data("lingcode: init received no output from Claude.\n".utf8))
            throw ExitCode(1)
        }

        if print {
            Swift.print(cleaned)
            return
        }

        try cleaned.write(to: claudeMdPath, atomically: true, encoding: .utf8)
        Swift.print("✓ CLAUDE.md written to \(claudeMdPath.path)")
    }

    private func buildInitPrompt(cwd: URL, summary: String) -> String {
        return """
        Analyze this project and generate a CLAUDE.md file.

        CLAUDE.md is read by Claude Code at session start to understand the project.
        It should contain:
        - Project overview (2-3 sentences)
        - Build, test, and lint commands
        - Key architectural conventions
        - Important files or directories
        - Any gotchas or non-obvious setup steps

        Project at \(cwd.path):

        \(summary)

        Write CLAUDE.md now. Use markdown. Be concise (100-250 lines).
        Output ONLY the raw CLAUDE.md content — no preamble or explanation.
        """
    }

    private func buildProjectSummary(cwd: URL) -> String {
        var parts: [String] = []

        // Directory listing — reuse HeadlessRunner's implementation (shows dirs with trailing /)
        if let listing = HeadlessRunner.topLevelListing(at: cwd, limit: 60) {
            parts.append("## Directory listing:\n\(listing)")
        }

        // Detect project type markers
        let markers: [(String, String)] = [
            ("Package.swift",    "Swift Package Manager"),
            ("package.json",     "Node.js"),
            ("Cargo.toml",       "Rust"),
            ("pyproject.toml",   "Python (pyproject)"),
            ("setup.py",         "Python (setup.py)"),
            ("go.mod",           "Go module"),
            ("build.gradle",     "Gradle"),
            ("build.gradle.kts", "Gradle (Kotlin DSL)"),
            ("Makefile",         "Make"),
            ("CMakeLists.txt",   "CMake"),
        ]
        let fm = FileManager.default
        var detected: [String] = []
        for (file, label) in markers where fm.fileExists(atPath: cwd.appendingPathComponent(file).path) {
            detected.append(label)
        }
        // Glob for *.xcodeproj
        if let items = try? fm.contentsOfDirectory(atPath: cwd.path),
           items.contains(where: { $0.hasSuffix(".xcodeproj") }) {
            detected.append("Xcode project")
        }
        if !detected.isEmpty {
            parts.append("## Detected project types:\n" + detected.map { "- \($0)" }.joined(separator: "\n"))
        }

        // Include README if short enough
        let readmePath = cwd.appendingPathComponent("README.md")
        if let data = try? Data(contentsOf: readmePath),
           let text = String(data: data, encoding: .utf8),
           text.count < 8_000 {
            parts.append("## README.md:\n\(text)")
        }

        return parts.joined(separator: "\n\n")
    }

    private func stripCodeFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip ```markdown ... ``` or ``` ... ``` wrapper if present
        let fencePatterns = ["```markdown\n", "```md\n", "```\n"]
        for fence in fencePatterns {
            if result.hasPrefix(fence) {
                result = String(result.dropFirst(fence.count))
                if result.hasSuffix("\n```") {
                    result = String(result.dropLast(4))
                } else if result.hasSuffix("```") {
                    result = String(result.dropLast(3))
                }
                break
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
