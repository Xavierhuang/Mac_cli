#if os(macOS)
import ArgumentParser
import Foundation

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Symlink this lingcode binary into your PATH.",
        discussion: """
        Creates a symlink from the current `lingcode` binary (usually shipped inside
        LingCode.app/Contents/Resources) to a directory in your PATH so you can run
        `lingcode ask ...` from anywhere. Tries /usr/local/bin first, then ~/.local/bin.
        """
    )

    @Option(name: .long, help: "Target directory (overrides the default search).")
    var destination: String?

    @Flag(name: .long, help: "Remove the symlink instead of creating it.")
    var uninstall: Bool = false

    @Flag(name: .long, help: "Print what would happen without touching the filesystem.")
    var dryRun: Bool = false

    func run() throws {
        let sourcePath = resolveBinaryPath()
        guard FileManager.default.isExecutableFile(atPath: sourcePath) else {
            FileHandle.standardError.write(Data("lingcode: cannot find the running binary at \(sourcePath)\n".utf8))
            throw ExitCode(1)
        }

        let targetDir: String
        if let dest = destination, !dest.isEmpty {
            targetDir = (dest as NSString).expandingTildeInPath
        } else if let picked = pickWritableDirectory() {
            targetDir = picked
        } else {
            printUnprivilegedHint(source: sourcePath)
            throw ExitCode(1)
        }

        let targetPath = (targetDir as NSString).appendingPathComponent("lingcode")

        if uninstall {
            try remove(at: targetPath, dryRun: dryRun)
        } else {
            try createSymlink(from: sourcePath, to: targetPath, dryRun: dryRun)
        }
    }

    // MARK: - Helpers

    private func resolveBinaryPath() -> String {
        // Bundle.main.executableURL uses _NSGetExecutablePath under the hood, so it
        // returns the real binary path even when invoked as a bare name through PATH
        // (where argv[0] is just "lingcode" and resolves against cwd).
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            return exe.path
        }
        let raw = CommandLine.arguments.first ?? "lingcode"
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }

    private func pickWritableDirectory() -> String? {
        let candidates = [
            "/usr/local/bin",
            "\(NSHomeDirectory())/.local/bin"
        ]
        for dir in candidates {
            if FileManager.default.isWritableFile(atPath: dir) {
                return dir
            }
            if dir.hasPrefix(NSHomeDirectory()) {
                // Create ~/.local/bin if it's not there yet.
                try? FileManager.default.createDirectory(
                    atPath: dir,
                    withIntermediateDirectories: true
                )
                if FileManager.default.isWritableFile(atPath: dir) {
                    return dir
                }
            }
        }
        return nil
    }

    private func createSymlink(from source: String, to target: String, dryRun: Bool) throws {
        print("source: \(source)")
        print("target: \(target)")
        let fm = FileManager.default
        if fm.fileExists(atPath: target) || fileExistsAsSymlink(target) {
            if dryRun {
                print("(dry-run) would remove existing \(target) before linking")
                return
            }
            try fm.removeItem(atPath: target)
        }
        if dryRun {
            print("(dry-run) would create symlink")
            return
        }
        try fm.createSymbolicLink(atPath: target, withDestinationPath: source)
        print("✓ installed: \(target) → \(source)")
        if !isOnPath(target) {
            print("")
            print("Heads up: \(targetDirectory(target)) is not on your PATH.")
            print("Add this to your shell rc:")
            print("  export PATH=\"\(targetDirectory(target)):$PATH\"")
        }
    }

    private func remove(at target: String, dryRun: Bool) throws {
        if !fileExistsAsSymlink(target) && !FileManager.default.fileExists(atPath: target) {
            print("nothing to remove at \(target)")
            return
        }
        if dryRun {
            print("(dry-run) would remove \(target)")
            return
        }
        try FileManager.default.removeItem(atPath: target)
        print("✓ removed: \(target)")
    }

    private func fileExistsAsSymlink(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if exists { return true }
        // `fileExists` does not follow broken symlinks; use lstat.
        var st = stat()
        return lstat(path, &st) == 0
    }

    private func isOnPath(_ absolutePath: String) -> Bool {
        let dir = targetDirectory(absolutePath)
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return false }
        return pathEnv.split(separator: ":").contains { $0 == Substring(dir) }
    }

    private func targetDirectory(_ absolutePath: String) -> String {
        (absolutePath as NSString).deletingLastPathComponent
    }

    private func printUnprivilegedHint(source: String) {
        let msg = """
            lingcode: no writable directory found in the default search list.

            Either re-run with sudo:
              sudo lingcode install

            Or pick your own target:
              lingcode install --destination ~/bin

            Source binary: \(source)

            """
        FileHandle.standardError.write(Data(msg.utf8))
    }
}

#endif
