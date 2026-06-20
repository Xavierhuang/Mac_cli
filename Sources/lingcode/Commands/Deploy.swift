import ArgumentParser
import Foundation

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Deploy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deploy",
        abstract: "Ship the iOS app at <project-path> to TestFlight or the App Store.",
        discussion: """
        Scaffolds a deploy-intent marker and signals the LingCode Claude Code tab to
        invoke the `ship-ios-app` skill in autonomous-build mode. The agent reads the
        project, detects your Apple Developer state, and walks through enrollment,
        archive, IPA export, and notarytool upload. Hard-stops at 2FA — credentials
        and Apple's trusted-device prompts are not automatable.

        The project at <project-path> must be a buildable iOS project (Xcode project
        or workspace at root, OR a project.yml that declares `platform: iOS`).

        Examples:
          lingcode deploy                       # uses cwd
          lingcode deploy ~/dev/my-ios-app
          lingcode deploy --no-open             # write marker, skip app launch
        """
    )

    @Argument(help: "Path to the iOS project root (default: current directory).")
    var projectPath: String?

    @Flag(name: .long, help: "Skip launching LingCode (write marker only).")
    var noOpen: Bool = false

    func run() async throws {
        let fm = FileManager.default

        // ---- Resolve project path ----
        let rawPath = (projectPath ?? fm.currentDirectoryPath as String)
        let projectURL = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
            .standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projectURL.path, isDirectory: &isDir), isDir.boolValue else {
            try fail("project path not found or not a directory: \(projectURL.path)")
        }

        // ---- Validate it's an iOS project ----
        guard isIOSProject(at: projectURL, fm: fm) else {
            try fail(
                "\(projectURL.path) does not look like an iOS project " +
                "(no .xcodeproj/.xcworkspace at root, and no project.yml with `platform: iOS`)."
            )
        }

        // ---- Scaffold .lingcode/pending-deploy.json ----
        let lingcodeDir = projectURL.appendingPathComponent(".lingcode")
        try fm.createDirectory(at: lingcodeDir, withIntermediateDirectories: true)
        try writePendingDeployMarker(project: projectURL, in: lingcodeDir)

        Swift.print("✓ Deploy intent recorded at \(lingcodeDir.path)/pending-deploy.json")
        Swift.print("  Project: \(projectURL.path)")

        if noOpen {
            Swift.print("(--no-open) Skipped launching LingCode.")
            return
        }

        try openInLingCode(project: projectURL)
        Swift.print("✓ Opening in LingCode...")
    }

    // MARK: - Project detection

    /// Match SkillsService.shouldMirrorToProject + AppleDeveloperStatusService.projectKind
    /// for the iOS branch. Keep in sync if either grows new markers.
    private func isIOSProject(at url: URL, fm: FileManager) -> Bool {
        let entries = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        if entries.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            return true
        }
        if let yml = try? String(
            contentsOf: url.appendingPathComponent("project.yml"),
            encoding: .utf8
        ), yml.contains("platform: iOS") {
            return true
        }
        return false
    }

    // MARK: - Writes

    private func writePendingDeployMarker(project: URL, in lingcodeDir: URL) throws {
        let marker = PendingDeployMarker(
            version: 1,
            project: project.path,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(marker)
        try data.write(to: lingcodeDir.appendingPathComponent("pending-deploy.json"))
    }

    private func openInLingCode(project: URL) throws {
        var comps = URLComponents()
        comps.scheme = "lingcode"
        comps.host = "deploy"
        comps.queryItems = [URLQueryItem(name: "path", value: project.path)]
        guard let url = comps.url else {
            try fail("failed to construct lingcode:// URL.")
        }
        let exit = runProcess("/usr/bin/open", args: [url.absoluteString], in: nil)
        if exit != 0 {
            try fail("`open` exited with status \(exit). Is LingCode installed?")
        }
    }

    // MARK: - Helpers

    private func fail(_ message: String) throws -> Never {
        FileHandle.standardError.write(Data("lingcode deploy: \(message)\n".utf8))
        throw ExitCode(1)
    }

    @discardableResult
    private func runProcess(_ launchPath: String, args: [String], in cwd: URL?) -> Int32 {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = args
        if let cwd = cwd { task.currentDirectoryURL = cwd }
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

private struct PendingDeployMarker: Codable {
    let version: Int
    let project: String
    let createdAt: String
}
