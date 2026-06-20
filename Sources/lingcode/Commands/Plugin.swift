import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `lingcode plugin` — manage plugin bundles. A plugin is a directory at
/// `~/.claude/plugins/<name>/` (user-global) or `./.claude/plugins/<name>/`
/// (project-local) with a `manifest.json` describing what it contributes:
///
///   {
///     "name": "review-bot",
///     "version": "1.0.0",
///     "description": "Pre-canned code review prompts and tools.",
///     "commands": ["commands/review.md"],
///     "agents": ["agents/reviewer.md"],
///     "outputStyles": ["output-styles/critical.md"],
///     "hooks": "hooks.json"
///   }
///
/// At runtime, the REPL already auto-discovers commands/agents/output-styles
/// from `.claude/<kind>/`, so a plugin "installs" by being symlinked or copied
/// into that namespace. This subcommand handles the bookkeeping (list / link /
/// unlink) without yet requiring a remote plugin marketplace.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Plugin: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "List, install, or remove plugin bundles under .claude/plugins/.",
        discussion: """
        A plugin is a directory containing a manifest.json plus subdirs for the
        contributions it ships (commands/, agents/, output-styles/, hooks.json).
        On `install`, lingcode symlinks each contribution into the corresponding
        slot under `.claude/<kind>/` so the existing loaders pick them up.

        Examples:
          lingcode plugin list
          lingcode plugin install ./plugins/review-bot     # link a local plugin
          lingcode plugin remove review-bot
        """,
        subcommands: [PluginList.self, PluginInstall.self, PluginRemove.self]
    )

    struct PluginList: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List discovered plugins (project then user)."
        )

        func run() throws {
            let dirs = pluginDirs()
            var any = false
            for dir in dirs {
                guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
                for entry in entries.sorted() {
                    let manifest = dir.appendingPathComponent(entry).appendingPathComponent("manifest.json")
                    guard let m = readManifest(at: manifest) else { continue }
                    any = true
                    let v = m["version"] as? String ?? "?"
                    let desc = m["description"] as? String ?? ""
                    Swift.print("  \(entry.padding(toLength: 18, withPad: " ", startingAt: 0))  v\(v)  \(desc)")
                }
            }
            if !any {
                Swift.print("No plugins. Drop a directory with manifest.json into .claude/plugins/ or ~/.claude/plugins/.")
            }
        }
    }

    struct PluginInstall: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Install a plugin from a local path, URL (.tar.gz / .zip), or git repo."
        )

        @Argument(help: "Local path, https URL to a tarball/zip, or git URL.")
        var source: String

        @Flag(name: .long, help: "Install user-globally (~/.claude/<kind>/) instead of project-locally.")
        var user: Bool = false

        func run() throws {
            // Materialize `source` into a local directory `src`. Local paths are
            // used in place; URLs download to a temp dir; git URLs clone there.
            let src = try materializeSource(source).standardizedFileURL
            let manifest = src.appendingPathComponent("manifest.json")
            guard let m = readManifest(at: manifest) else {
                FileHandle.standardError.write(Data("lingcode: \(manifest.path) not found or invalid JSON.\n".utf8))
                throw ExitCode(1)
            }
            if let err = validatePluginManifest(m) {
                FileHandle.standardError.write(Data("lingcode: invalid manifest — \(err)\n".utf8))
                throw ExitCode(1)
            }
            // Safe after validation.
            let name = m["name"] as! String
            let target = (user
                ? URL(fileURLWithPath: NSHomeDirectory())
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                .appendingPathComponent(".claude")
            let kinds: [(String, String)] = [
                ("commands",     "commands"),
                ("agents",       "agents"),
                ("output-styles", "output-styles")
            ]
            for (manifestKey, slotDir) in kinds {
                guard let entries = m[manifestKey] as? [String] else { continue }
                let slotURL = target.appendingPathComponent(slotDir)
                try? FileManager.default.createDirectory(at: slotURL, withIntermediateDirectories: true)
                for rel in entries {
                    let from = src.appendingPathComponent(rel)
                    let to = slotURL.appendingPathComponent(from.lastPathComponent)
                    try? FileManager.default.removeItem(at: to)
                    do {
                        try FileManager.default.createSymbolicLink(at: to, withDestinationURL: from)
                        Swift.print("  ↳ \(slotDir)/\(from.lastPathComponent)")
                    } catch {
                        FileHandle.standardError.write(Data("lingcode: failed to link \(rel): \(error.localizedDescription)\n".utf8))
                    }
                }
            }
            // Track the install in plugins/<name>/ so `list` and `remove` can find it.
            let pluginHome = target.appendingPathComponent("plugins").appendingPathComponent(name)
            try? FileManager.default.removeItem(at: pluginHome)
            try? FileManager.default.createDirectory(at: pluginHome.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(at: pluginHome, withDestinationURL: src)
            Swift.print("✓ installed \(name)")
        }
    }

    struct PluginRemove: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Unlink a plugin and its contributions."
        )

        @Argument(help: "Plugin name to remove.")
        var name: String

        @Flag(name: .long, help: "Operate on ~/.claude/ instead of project-local .claude/.")
        var user: Bool = false

        func run() throws {
            let root = (user
                ? URL(fileURLWithPath: NSHomeDirectory())
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                .appendingPathComponent(".claude")
            let pluginHome = root.appendingPathComponent("plugins").appendingPathComponent(name)
            guard let m = readManifest(at: pluginHome.appendingPathComponent("manifest.json")) else {
                FileHandle.standardError.write(Data("lingcode: plugin '\(name)' is not installed.\n".utf8))
                throw ExitCode(1)
            }
            let kinds: [(String, String)] = [
                ("commands",     "commands"),
                ("agents",       "agents"),
                ("output-styles", "output-styles")
            ]
            for (manifestKey, slotDir) in kinds {
                guard let entries = m[manifestKey] as? [String] else { continue }
                for rel in entries {
                    let baseName = (rel as NSString).lastPathComponent
                    let to = root.appendingPathComponent(slotDir).appendingPathComponent(baseName)
                    try? FileManager.default.removeItem(at: to)
                }
            }
            try? FileManager.default.removeItem(at: pluginHome)
            Swift.print("✓ removed \(name)")
        }
    }
}

private func pluginDirs() -> [URL] {
    [
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/plugins"),
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/plugins")
    ]
}

/// Resolves a `source` argument to a local directory containing manifest.json.
/// Supports:
///   - https://… ending in .tar.gz or .zip → download + extract to a temp dir
///   - https://github.com/user/repo or git@…:user/repo.git → `git clone` to temp
///   - any other path                                       → treat as local
/// Throws ExitCode(1) with a stderr message on download/clone failure.
@available(macOS 10.15, *)
private func materializeSource(_ source: String) throws -> URL {
    let trimmed = source.trimmingCharacters(in: .whitespaces)
    let lower = trimmed.lowercased()
    let isHTTP = lower.hasPrefix("http://") || lower.hasPrefix("https://")
    let looksGit = lower.hasSuffix(".git") || lower.hasPrefix("git@") || (isHTTP && (lower.contains("github.com") || lower.contains("gitlab.com")) && !lower.hasSuffix(".tar.gz") && !lower.hasSuffix(".zip") && !lower.hasSuffix(".tgz"))
    let looksTar = lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz")
    let looksZip = lower.hasSuffix(".zip")

    if !isHTTP && !lower.hasPrefix("git@") {
        // Local path — expand ~ and return.
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    }

    let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lingcode-plugin-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)

    if looksGit {
        FileHandle.standardError.write(Data("→ git clone \(trimmed)\n".utf8))
        try shellOut("/usr/bin/git", ["clone", "--depth", "1", trimmed, tmpRoot.path], errorPrefix: "git clone failed")
        return findManifestRoot(tmpRoot)
    }

    if looksTar || looksZip {
        let archive = tmpRoot.appendingPathComponent(looksZip ? "plugin.zip" : "plugin.tar.gz")
        FileHandle.standardError.write(Data("→ download \(trimmed)\n".utf8))
        try downloadFile(from: trimmed, to: archive)
        let extractedDir = tmpRoot.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extractedDir, withIntermediateDirectories: true)
        if looksZip {
            try shellOut("/usr/bin/unzip", ["-q", archive.path, "-d", extractedDir.path], errorPrefix: "unzip failed")
        } else {
            try shellOut("/usr/bin/tar", ["-xzf", archive.path, "-C", extractedDir.path], errorPrefix: "tar extract failed")
        }
        return findManifestRoot(extractedDir)
    }

    FileHandle.standardError.write(Data("lingcode: don't know how to install from '\(trimmed)' — expected .tar.gz, .zip, .git, or a local path.\n".utf8))
    throw ExitCode(2)
}

/// Some tarballs/zips wrap the plugin in a top-level directory (`my-plugin-1.0/…`).
/// If `root/manifest.json` doesn't exist but exactly one subdirectory does, use that.
private func findManifestRoot(_ root: URL) -> URL {
    if FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path) {
        return root
    }
    if let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
        let dirs = entries.filter { entry in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: root.appendingPathComponent(entry).path, isDirectory: &isDir) && isDir.boolValue
        }
        if dirs.count == 1 {
            return root.appendingPathComponent(dirs[0])
        }
    }
    return root // caller will fail manifest-not-found check with a clear message
}

private func downloadFile(from urlString: String, to dest: URL) throws {
    guard let url = URL(string: urlString) else {
        FileHandle.standardError.write(Data("lingcode: invalid URL '\(urlString)'\n".utf8))
        throw ExitCode(1)
    }
    let semaphore = DispatchSemaphore(value: 0)
    var downloadError: Error?
    var statusCode = 0
    let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
        defer { semaphore.signal() }
        if let e = error { downloadError = e; return }
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let temp = tempURL, statusCode >= 200, statusCode < 300 else { return }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: temp, to: dest)
        } catch {
            downloadError = error
        }
    }
    task.resume()
    semaphore.wait()
    if let e = downloadError {
        FileHandle.standardError.write(Data("lingcode: download failed: \(e.localizedDescription)\n".utf8))
        throw ExitCode(1)
    }
    if statusCode < 200 || statusCode >= 300 {
        FileHandle.standardError.write(Data("lingcode: download failed: HTTP \(statusCode)\n".utf8))
        throw ExitCode(1)
    }
}

private func shellOut(_ exe: String, _ args: [String], errorPrefix: String) throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: exe)
    proc.arguments = args
    let errPipe = Pipe()
    proc.standardError = errPipe
    do { try proc.run() } catch {
        FileHandle.standardError.write(Data("lingcode: \(errorPrefix): \(error.localizedDescription)\n".utf8))
        throw ExitCode(1)
    }
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        FileHandle.standardError.write(Data("lingcode: \(errorPrefix) (exit \(proc.terminationStatus))\n\(stderr)\n".utf8))
        throw ExitCode(1)
    }
}

private func readManifest(at url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return json
}

/// Validates a plugin manifest dict. Returns `nil` when valid; otherwise an
/// error message naming the first problem found (so users see one fix at a
/// time instead of a wall of errors). Run by `plugin install` before linking
/// any contributions, so a typo in `commands:` doesn't half-install the plugin.
func validatePluginManifest(_ m: [String: Any]) -> String? {
    guard let name = m["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
        return "manifest is missing required `name` (non-empty string)"
    }
    if !name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
        return "manifest `name` may only contain letters, digits, '-', '_' (got '\(name)')"
    }
    if let v = m["version"], !(v is String) {
        return "manifest `version` must be a string"
    }
    if let d = m["description"], !(d is String) {
        return "manifest `description` must be a string"
    }
    for key in ["commands", "agents", "output-styles", "outputStyles"] {
        guard let val = m[key] else { continue }
        guard let arr = val as? [Any] else {
            return "manifest `\(key)` must be an array of relative paths (got \(type(of: val)))"
        }
        for item in arr {
            guard let s = item as? String, !s.isEmpty else {
                return "manifest `\(key)` entries must be non-empty strings"
            }
            if s.hasPrefix("/") || s.contains("..") {
                return "manifest `\(key)` entries must be relative paths within the plugin directory (got '\(s)')"
            }
        }
    }
    if let h = m["hooks"], !(h is String) {
        return "manifest `hooks` must be a string path to a hooks JSON file"
    }
    return nil
}
