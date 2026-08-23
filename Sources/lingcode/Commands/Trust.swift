import ArgumentParser
import Foundation
import LingCodeAgentCore

/// `lingcode trust [<path>]` — mark a project as trusted for hook execution.
/// `lingcode trust --list` — show all trusted projects.
/// `lingcode trust --remove [<path>]` — untrust a project.
///
/// Enforcement is live in `HooksConfig.load`: untrusted projects have their hook rules
/// skipped, with a TTY prompt to opt in. See docs/HOOKS.md.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Trust: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "trust",
        abstract: "Manage trusted projects for hook execution.",
        discussion: """
        Hooks in a project's .claude/settings.json are arbitrary shell commands that run \
        during agent activity, so LingCode requires explicit trust before firing them. \
        Untrusted projects have their hooks skipped; on a TTY you are prompted once. \
        Editing .claude/settings.json revokes trust until you re-confirm.

        Examples:
          lingcode trust                # trust the current directory
          lingcode trust ~/proj/api     # trust a specific path
          lingcode trust --list         # show all trusted projects
          lingcode trust --remove       # untrust the current directory
        """
    )

    @Argument(help: "Project path to trust or untrust. Defaults to the current directory.")
    var path: String?

    @Flag(name: .long, help: "List all currently-trusted projects.")
    var list: Bool = false

    @Flag(name: .long, help: "Remove trust for the given path (or current directory).")
    var remove: Bool = false

    func run() async throws {
        if list {
            let entries = HookTrustStore.listTrusted()
            if entries.isEmpty {
                print("No trusted projects.")
            } else {
                for p in entries {
                    print(p)
                }
            }
            return
        }

        let cwd = resolveCwd()

        if remove {
            let removed = try HookTrustStore.untrust(cwd: cwd)
            if removed {
                print("Untrusted: \(cwd.path)")
            } else {
                print("No trust entry for: \(cwd.path)")
            }
            return
        }

        try HookTrustStore.trust(cwd: cwd)
        let settingsURL = cwd.appendingPathComponent(".claude/settings.json")
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            print("Trusted: \(cwd.path)")
            print("  Hooks in .claude/settings.json may now fire when running `lingcode` here.")
        } else {
            print("Trusted: \(cwd.path)")
            print("  Note: no .claude/settings.json found yet — trust recorded for future hooks.")
        }
    }

    private func resolveCwd() -> URL {
        if let p = path, !p.isEmpty {
            let expanded = (p as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
    }
}
