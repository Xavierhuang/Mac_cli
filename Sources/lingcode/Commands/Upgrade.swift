import ArgumentParser
import Foundation

struct Upgrade: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upgrade",
        abstract: "Upgrade lingcode by re-running the official installer.",
        discussion: """
        Fetches https://lingcode.dev/install-cli.sh and runs it, which downloads
        the latest darwin-arm64 or darwin-x86_64 tarball and installs it to the
        same location the previous installer picked (~/.lingcode/cli/, with a
        symlink at ~/.local/bin/lingcode).

        Use `--dry-run` to print the command that would run without touching
        the filesystem.
        """
    )

    @Flag(name: .long, help: "Print the command that would run; do not execute it.")
    var dryRun: Bool = false

    @Option(name: .long, help: "Installer URL (for testing or staging).")
    var installerURL: String = "https://lingcode.dev/install-cli.sh"

    func run() async throws {
        let currentVersion = LingCode.configuration.version
        let shellCommand = "curl -fsSL \(installerURL) | sh"

        if dryRun {
            print("(dry-run) would run: \(shellCommand)")
            print("(dry-run) current version: \(currentVersion.isEmpty ? "unknown" : currentVersion)")
            return
        }

        print("Upgrading lingcode (current: \(currentVersion.isEmpty ? "unknown" : currentVersion))…")
        let status = Self.runShell(shellCommand)
        if status != 0 {
            FileHandle.standardError.write(Data("upgrade failed (exit \(status))\n".utf8))
            throw ExitCode(Int32(status))
        }
    }

    private static func runShell(_ command: String) -> Int32 {
        let process = Process()
        process.launchPath = "/bin/sh"
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("failed to launch sh: \(error)\n".utf8))
            return 127
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
