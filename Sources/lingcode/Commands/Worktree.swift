import ArgumentParser
import Foundation

/// `lingcode worktree create <branch>` — create a git worktree for parallel agent runs.
/// `lingcode worktree list` — show all worktrees of the current repo.
/// `lingcode worktree remove <branch>` — remove a worktree.
///
/// Designed for the common "spin up a parallel agent on a feature branch without
/// disturbing my main checkout" workflow. Thin wrapper around `git worktree` — no
/// LingCode-specific state lives in worktrees beyond what git already tracks.
///
/// Worktrees default to `.worktrees/<branch>/` next to the repo root. Add `.worktrees/`
/// to `.gitignore` once if you don't want the path showing up as untracked.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Worktree: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "worktree",
        abstract: "Manage git worktrees for parallel agent runs.",
        discussion: """
        Worktrees let you have multiple checkouts of the same repo at different
        branches simultaneously. Useful for running agents in parallel without
        them stepping on each other's files.

        Examples:
          lingcode worktree create feat/auth          # creates .worktrees/feat/auth/
          lingcode worktree create feat/auth --from main
          lingcode worktree list
          lingcode worktree remove feat/auth
        """,
        subcommands: [Create.self, List.self, Remove.self]
    )

    // MARK: - Subcommands

    struct Create: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a git worktree for a branch."
        )

        @Argument(help: "Branch name. Created if it doesn't exist (from --from, or HEAD).")
        var branch: String

        @Option(name: .long, help: "Base branch/commit to create the new branch from. Defaults to HEAD.")
        var from: String?

        @Option(name: .long, help: "Explicit worktree path. Defaults to .worktrees/<branch>/ next to the repo root.")
        var path: String?

        @Flag(name: .long, help: "Print the worktree path on success (machine-readable, no other output).")
        var printPath: Bool = false

        func run() async throws {
            let repoRoot = try WorktreeHelpers.repoRoot()
            let resolvedPath = path.map { ($0 as NSString).expandingTildeInPath }
                ?? repoRoot.appendingPathComponent(".worktrees").appendingPathComponent(branch).path

            // git worktree add will create the branch if it doesn't exist when -b is passed.
            // Detect whether branch already exists locally to choose the right invocation.
            let branchExists = try WorktreeHelpers.branchExists(branch, in: repoRoot)
            var args: [String] = ["worktree", "add"]
            if branchExists {
                args += [resolvedPath, branch]
            } else {
                args += ["-b", branch, resolvedPath, from ?? "HEAD"]
            }
            let result = try WorktreeHelpers.runGit(args, in: repoRoot)
            if result.exitCode != 0 {
                FileHandle.standardError.write(Data(result.stderr.utf8))
                throw ExitCode(Int32(result.exitCode))
            }

            if printPath {
                print(resolvedPath)
            } else {
                print("Created worktree: \(resolvedPath)")
                print("  Branch: \(branch)")
                if !branchExists, let f = from { print("  From:   \(f)") }
                print("")
                print("To start an agent in it:")
                print("  cd \(resolvedPath) && lingcode ask \"your prompt\"")
            }
        }
    }

    struct List: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "list",
            abstract: "Show all worktrees of the current repo."
        )

        @Flag(name: .long, help: "Output in machine-readable porcelain format (one record per worktree, blank-line separated — `git worktree list --porcelain` format).")
        var porcelain: Bool = false

        func run() async throws {
            let repoRoot = try WorktreeHelpers.repoRoot()
            let args: [String] = porcelain ? ["worktree", "list", "--porcelain"] : ["worktree", "list"]
            let result = try WorktreeHelpers.runGit(args, in: repoRoot)
            if result.exitCode != 0 {
                FileHandle.standardError.write(Data(result.stderr.utf8))
                throw ExitCode(Int32(result.exitCode))
            }
            print(result.stdout, terminator: "")
        }
    }

    struct Remove: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove a worktree (the branch is preserved)."
        )

        @Argument(help: "Worktree path or branch name.")
        var target: String

        @Flag(name: .long, help: "Force removal even with uncommitted changes. Use with care — uncommitted work is lost.")
        var force: Bool = false

        func run() async throws {
            let repoRoot = try WorktreeHelpers.repoRoot()
            // git worktree remove accepts a path. If the user passed a branch name,
            // try to resolve it to the matching worktree path first.
            let resolvedTarget: String
            if FileManager.default.fileExists(atPath: target)
                || target.hasPrefix("/")
                || target.hasPrefix(".") {
                resolvedTarget = target
            } else if let p = try WorktreeHelpers.pathForBranch(target, in: repoRoot) {
                resolvedTarget = p
            } else {
                resolvedTarget = target
            }

            var args: [String] = ["worktree", "remove"]
            if force { args.append("--force") }
            args.append(resolvedTarget)
            let result = try WorktreeHelpers.runGit(args, in: repoRoot)
            if result.exitCode != 0 {
                FileHandle.standardError.write(Data(result.stderr.utf8))
                throw ExitCode(Int32(result.exitCode))
            }
            print("Removed worktree: \(resolvedTarget)")
        }
    }
}

// MARK: - Shared git helpers

private enum WorktreeHelpers {
    struct Result { let exitCode: Int32; let stdout: String; let stderr: String }

    /// Returns the absolute path to the current repo's top level.
    static func repoRoot() throws -> URL {
        let result = try runGit(["rev-parse", "--show-toplevel"],
                                in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        if result.exitCode != 0 {
            FileHandle.standardError.write(Data(
                "lingcode: not inside a git repository (run `git init` first or cd to a repo)\n".utf8
            ))
            throw ExitCode(1)
        }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path)
    }

    static func branchExists(_ name: String, in repo: URL) throws -> Bool {
        let result = try runGit(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: repo)
        return result.exitCode == 0
    }

    /// Walks `git worktree list --porcelain` and returns the worktree path for
    /// a given branch name (`refs/heads/<branch>`), or nil if not found.
    static func pathForBranch(_ branch: String, in repo: URL) throws -> String? {
        let result = try runGit(["worktree", "list", "--porcelain"], in: repo)
        if result.exitCode != 0 { return nil }
        var currentPath: String?
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("worktree ") {
                currentPath = String(s.dropFirst("worktree ".count))
            } else if s.hasPrefix("branch refs/heads/"), let p = currentPath {
                let b = String(s.dropFirst("branch refs/heads/".count))
                if b == branch { return p }
            } else if s.isEmpty {
                currentPath = nil
            }
        }
        return nil
    }

    static func runGit(_ args: [String], in cwd: URL) throws -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git"] + args
        proc.currentDirectoryURL = cwd
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        try proc.run()
        proc.waitUntilExit()
        let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        return Result(
            exitCode: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
