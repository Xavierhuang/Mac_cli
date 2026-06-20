import ArgumentParser
import Foundation

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Convert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Convert a Flutter app to native iOS, Android, and macOS.",
        discussion: """
        Scaffolds an output directory next to the Flutter source and signals the
        LingCode Claude Code tab to invoke the `flutter-to-native` skill in
        autonomous-build mode. The Flutter repo is treated as a design spec —
        the agent reads it and writes fresh idiomatic native code; no Dart in
        the output, no Flutter embed.

        Default output is <flutter-path>-native/ as a sibling of the source.
        Override with --out. Targets default to all three platforms.

        Use --scan-only to produce <out>/CONVERSION_PLAN.md without scaffolding
        or porting; review the plan, then re-run without the flag to execute.

        Examples:
          lingcode convert ~/dev/my-flutter-app
          lingcode convert ./todo-app --targets ios,android
          lingcode convert ./todo-app --scan-only
          lingcode convert ./todo-app --out ~/native --no-open
        """
    )

    @Argument(help: "Path to the existing Flutter repository (must contain pubspec.yaml).")
    var flutterPath: String

    @Option(name: .shortAndLong, help: "Output directory (default: <flutter-path>-native/).")
    var out: String?

    @Option(name: .long, help: "Comma-separated subset of ios,android,macos (default: all three).")
    var targets: String?

    @Flag(name: .long, help: "Produce CONVERSION_PLAN.md only; do not scaffold or port.")
    var scanOnly: Bool = false

    @Flag(name: .long, help: "Skip launching LingCode (scaffold only).")
    var noOpen: Bool = false

    func run() async throws {
        let fm = FileManager.default

        // ---- Resolve and validate source ----
        let sourceURL = URL(fileURLWithPath: (flutterPath as NSString).expandingTildeInPath)
            .standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir), isDir.boolValue else {
            try fail("source path not found or not a directory: \(sourceURL.path)")
        }
        let pubspec = sourceURL.appendingPathComponent("pubspec.yaml")
        guard fm.fileExists(atPath: pubspec.path) else {
            try fail("\(sourceURL.path) is not a Flutter repo (no pubspec.yaml at root).")
        }

        // ---- Resolve output ----
        let outURL = resolveOutDir(sourceURL: sourceURL).standardizedFileURL
        if outURL.path == sourceURL.path {
            try fail("--out must differ from the Flutter source path.")
        }

        // ---- Validate output dir is fresh or only contains prior convert artifacts ----
        try validateOutDir(outURL: outURL, fm: fm)

        // ---- Parse and validate targets ----
        let resolvedTargets = try parseTargets()

        // ---- Scaffold ----
        try fm.createDirectory(at: outURL, withIntermediateDirectories: true)
        let lingcodeDir = outURL.appendingPathComponent(".lingcode")
        try fm.createDirectory(at: lingcodeDir, withIntermediateDirectories: true)

        try writeGitignore(in: outURL)
        try writePendingConvertMarker(
            source: sourceURL,
            out: outURL,
            targets: resolvedTargets,
            scanOnly: scanOnly,
            in: lingcodeDir
        )
        gitInitAndCommit(in: outURL)

        Swift.print("✓ Scaffolded \(outURL.path)")
        Swift.print("  Source:  \(sourceURL.path)")
        Swift.print("  Targets: \(resolvedTargets.joined(separator: ", "))")
        if scanOnly {
            Swift.print("  Mode:    scan-only (CONVERSION_PLAN.md only, no port)")
        }

        if noOpen {
            Swift.print("(--no-open) Skipped launching LingCode.")
            return
        }

        try openInLingCode(
            source: sourceURL,
            out: outURL,
            targets: resolvedTargets,
            scanOnly: scanOnly
        )
        Swift.print("✓ Opening in LingCode...")
    }

    // MARK: - Resolution

    private func resolveOutDir(sourceURL: URL) -> URL {
        if let out = out, !out.isEmpty {
            return URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        }
        // Sibling of the source named "<source-leaf>-native"
        let parent = sourceURL.deletingLastPathComponent()
        let leaf = sourceURL.lastPathComponent
        return parent.appendingPathComponent("\(leaf)-native")
    }

    /// Output dir must be: nonexistent, empty, or contain only prior convert artifacts.
    /// Never clobber a user's WIP — that's why we whitelist instead of blanket-overwriting.
    private func validateOutDir(outURL: URL, fm: FileManager) throws {
        guard fm.fileExists(atPath: outURL.path) else { return }
        let knownArtifacts: Set<String> = [
            ".lingcode", ".gitignore", ".git",
            "ios", "android", "macos",
            "CONVERT.md", "CONVERSION_PLAN.md",
            ".DS_Store",
        ]
        let entries = (try? fm.contentsOfDirectory(atPath: outURL.path)) ?? []
        for name in entries where !knownArtifacts.contains(name) {
            try fail(
                "--out \(outURL.path) is not empty (contains \(name)). " +
                "Pick a different --out or remove the unexpected entries first."
            )
        }
    }

    private func parseTargets() throws -> [String] {
        let raw = (targets ?? "ios,android,macos")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !raw.isEmpty else {
            try fail("--targets cannot be empty.")
        }
        let allowed: Set<String> = ["ios", "android", "macos"]
        for t in raw where !allowed.contains(t) {
            try fail("unknown target '\(t)'. Allowed: ios, android, macos.")
        }
        // Preserve order, dedup.
        var seen = Set<String>()
        return raw.filter { seen.insert($0).inserted }
    }

    // MARK: - Writes

    private func writeGitignore(in dir: URL) throws {
        let gitignore = """
        # macOS
        .DS_Store

        # Build outputs
        DerivedData/
        build/
        .build/
        node_modules/

        # Generated Xcode user state
        *.xcuserstate
        xcuserdata/

        # Gradle
        .gradle/
        local.properties

        # LingCode convert kickoff markers (one-shot; safe to keep ignored)
        .lingcode/pending-*.json
        """
        try gitignore.write(
            to: dir.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writePendingConvertMarker(
        source: URL,
        out: URL,
        targets: [String],
        scanOnly: Bool,
        in lingcodeDir: URL
    ) throws {
        let marker = PendingConvertMarker(
            version: 1,
            source: source.path,
            out: out.path,
            targets: targets,
            scanOnly: scanOnly,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(marker)
        try data.write(to: lingcodeDir.appendingPathComponent("pending-convert.json"))
    }

    private func gitInitAndCommit(in dir: URL) {
        // Best-effort: scaffold is still useful even if git is missing or commit fails.
        _ = runProcess("/usr/bin/env", args: ["git", "init", "-q"], in: dir)
        _ = runProcess("/usr/bin/env", args: ["git", "add", "-A"], in: dir)
        _ = runProcess("/usr/bin/env",
                       args: ["git", "commit", "-q", "-m", "Initial scaffold from lingcode convert"],
                       in: dir)
    }

    private func openInLingCode(
        source: URL,
        out: URL,
        targets: [String],
        scanOnly: Bool
    ) throws {
        var comps = URLComponents()
        comps.scheme = "lingcode"
        comps.host = "convert"
        comps.queryItems = [
            URLQueryItem(name: "source", value: source.path),
            URLQueryItem(name: "out", value: out.path),
            URLQueryItem(name: "targets", value: targets.joined(separator: ",")),
            URLQueryItem(name: "scanOnly", value: scanOnly ? "true" : "false"),
        ]
        guard let url = comps.url else {
            try fail("failed to construct lingcode:// URL.")
        }
        let exit = runProcess("/usr/bin/open", args: [url.absoluteString], in: nil)
        if exit != 0 {
            try fail("`open` exited with status \(exit). Is LingCode installed?")
        }
    }

    // MARK: - Helpers

    /// Write a usage-style error to stderr and exit. Marked `Never` so the call site
    /// can `try fail(...)` without needing an unreachable `return` after it.
    private func fail(_ message: String) throws -> Never {
        FileHandle.standardError.write(Data("lingcode convert: \(message)\n".utf8))
        throw ExitCode(1)
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

private struct PendingConvertMarker: Codable {
    let version: Int
    let source: String
    let out: String
    let targets: [String]
    let scanOnly: Bool
    let createdAt: String
}
