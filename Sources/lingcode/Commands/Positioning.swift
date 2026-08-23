import ArgumentParser
import Foundation
import LingCodeAgentCore

// Thin Swift front end over `agent-bridge/lib/positioning`. The generator stays
// in Node because that is where its 61 tests live and where it already ships;
// this command exists so the agent can reach it by name on PATH rather than
// guessing at a path inside the app bundle.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Positioning: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "positioning",
        abstract: "Maintain PRODUCT.md — the product thesis and the evidence beside it.",
        discussion: """
        PRODUCT.md has two sections with different owners. '## Stated' is yours: \
        who the product is for, and what it is deliberately not doing. '## Observed' \
        is generated from git history and regenerated in place; it never rewrites \
        your thesis, and your thesis never rewrites it.

        Run `lingcode positioning observe` after a stretch of work to see what your \
        commits actually say the product is.
        """,
        subcommands: [Observe.self, Stated.self]
    )
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
extension Positioning {
    struct Observe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "observe",
            abstract: "Regenerate the '## Observed' section from git history."
        )

        @Option(name: .long, help: "Project directory (defaults to cwd).")
        var project: String?

        @Option(name: .long, help: "How many non-merge commits to read (default 20).")
        var limit: Int?

        func run() async throws {
            var args = ["observe"]
            if let limit = limit { args += ["--limit", String(limit)] }
            try runPositioning(args, project: project)
        }
    }

    struct Stated: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stated",
            abstract: "Write the '## Stated' section — your product thesis.",
            discussion: """
            All four answers are required. '--not-competing' must name something you \
            are deliberately not doing: without a real exclusion nothing can ever \
            contradict the thesis, so there is nothing for the agent to flag.
            """
        )

        @Option(name: .customLong("for"), help: "Who specifically has this problem.")
        var audience: String?

        @Option(name: .customLong("instead"), help: "What they do today instead.")
        var instead: String?

        @Option(name: .long, help: "What would make them switch.")
        var wedge: String?

        @Option(name: .customLong("not-competing"), help: "What you are deliberately NOT doing.")
        var notCompeting: String?

        @Option(name: .long, help: "Project directory (defaults to cwd).")
        var project: String?

        func run() async throws {
            var args = ["stated"]
            if let audience = audience { args += ["--for", audience] }
            if let instead = instead { args += ["--instead", instead] }
            if let wedge = wedge { args += ["--wedge", wedge] }
            if let notCompeting = notCompeting { args += ["--not-competing", notCompeting] }
            try runPositioning(args, project: project)
        }
    }
}

/// Locate node + the bundled script, run it in the project directory, and
/// forward its exit code so a rejected thesis fails the caller's command.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
private func runPositioning(_ args: [String], project: String?) throws {
    let cwd: URL
    if let project = project, !project.isEmpty {
        cwd = URL(fileURLWithPath: (project as NSString).expandingTildeInPath)
    } else {
        cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    let extraNodePaths = [CLIResources.bundledNodePath()].compactMap { $0 }
    guard let nodePath = NodeResolver.resolve(extraSearchPaths: extraNodePaths) else {
        FileHandle.standardError.write(Data(
            "lingcode: bundled node is missing and no system node was found — run `lingcode doctor` for details.\n".utf8))
        throw ExitCode(1)
    }

    guard let script = positioningScriptPath() else {
        FileHandle.standardError.write(Data(
            "lingcode: positioning resources missing — reinstall lingcode.\n".utf8))
        throw ExitCode(1)
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: nodePath)
    proc.arguments = [script] + args
    proc.currentDirectoryURL = cwd
    try proc.run()
    proc.waitUntilExit()

    if proc.terminationStatus != 0 {
        throw ExitCode(proc.terminationStatus)
    }
}

/// Resource bundle first, then the dev tree, so `swift run` works from a checkout.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
private func positioningScriptPath() -> String? {
    let relative = "agent-bridge/lib/positioning/positioning.js"

    if let bundle = try? CLIResources.bundleURL() {
        let path = bundle.appendingPathComponent(relative).path
        if FileManager.default.fileExists(atPath: path) { return path }
    }

    let devPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Commands
        .deletingLastPathComponent()   // lingcode
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // LingCodeCLI
        .appendingPathComponent("LingCode/agent-bridge/lib/positioning/positioning.js")
        .path
    return FileManager.default.fileExists(atPath: devPath) ? devPath : nil
}
