import ArgumentParser
import Foundation

/// `lingcode mcp` — discover, install, and remove Model Context Protocol servers
/// in the project's `.mcp.json` (or `~/.claude.json`). The "marketplace" is a
/// hand-curated static registry below; we don't fetch from a remote index because
/// the MCP ecosystem doesn't have a single authoritative one yet. Pull-requests
/// to extend the registry are welcome.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Manage Model Context Protocol servers in this project's .mcp.json.",
        discussion: """
        Examples:
          lingcode mcp search                # list every server in the curated registry
          lingcode mcp search filesystem     # filter
          lingcode mcp install filesystem    # add to ./.mcp.json
          lingcode mcp list                  # show servers configured for this project
          lingcode mcp remove filesystem     # remove from ./.mcp.json
        """,
        subcommands: [Search.self, Install.self, ListInstalled.self, Remove.self]
    )

    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "List known MCP servers from the built-in registry."
        )

        @Argument(help: "Optional substring filter on name or description.")
        var query: String?

        func run() throws {
            let q = query?.lowercased() ?? ""
            for entry in MCPRegistry.all where q.isEmpty
                || entry.name.contains(q)
                || entry.description.lowercased().contains(q) {
                Swift.print("  \(entry.name.padding(toLength: 18, withPad: " ", startingAt: 0))  \(entry.description)")
            }
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Add an MCP server from the registry to this project's .mcp.json."
        )

        @Argument(help: "Server name (run `lingcode mcp search` to list).")
        var name: String

        @Flag(name: .long, help: "Install to ~/.claude.json (user-global) instead of ./.mcp.json (project-local).")
        var user: Bool = false

        func run() throws {
            guard let entry = MCPRegistry.find(name) else {
                let suggestion = MCPRegistry.closestMatch(to: name).map { " — did you mean '\($0)'?" } ?? ""
                FileHandle.standardError.write(Data("lingcode: unknown MCP server '\(name)'\(suggestion). Run `lingcode mcp search`.\n".utf8))
                throw ExitCode(2)
            }
            let path = user
                ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".mcp.json")
            var json = (try? Data(contentsOf: path)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            var servers = (json["mcpServers"] as? [String: Any]) ?? [:]
            servers[entry.name] = entry.toConfigDict()
            json["mcpServers"] = servers
            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: path, options: .atomic)
            Swift.print("✓ \(entry.name) → \(path.path)")
            if !entry.requiredEnv.isEmpty {
                Swift.print("  Required env: \(entry.requiredEnv.joined(separator: ", "))")
            }
            if !entry.notes.isEmpty {
                Swift.print("  Note: \(entry.notes)")
            }
        }
    }

    struct ListInstalled: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "Show MCP servers currently configured for this project."
        )

        func run() throws {
            let candidates = [
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".mcp.json"),
                URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
            ]
            var any = false
            for path in candidates {
                guard let data = try? Data(contentsOf: path),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let servers = json["mcpServers"] as? [String: Any], !servers.isEmpty else { continue }
                any = true
                Swift.print("  \(path.path):")
                for name in servers.keys.sorted() {
                    Swift.print("    • \(name)")
                }
            }
            if !any {
                Swift.print("No MCP servers configured. `lingcode mcp install <name>` to add one.")
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove an MCP server from this project's .mcp.json."
        )

        @Argument(help: "Server name to remove.")
        var name: String

        @Flag(name: .long, help: "Operate on ~/.claude.json instead of ./.mcp.json.")
        var user: Bool = false

        func run() throws {
            let path = user
                ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".mcp.json")
            guard let data = try? Data(contentsOf: path),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                FileHandle.standardError.write(Data("lingcode: \(path.path) doesn't exist or isn't valid JSON.\n".utf8))
                throw ExitCode(1)
            }
            var servers = (json["mcpServers"] as? [String: Any]) ?? [:]
            guard servers.removeValue(forKey: name) != nil else {
                FileHandle.standardError.write(Data("lingcode: '\(name)' is not configured in \(path.path).\n".utf8))
                throw ExitCode(1)
            }
            json["mcpServers"] = servers
            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: path, options: .atomic)
            Swift.print("✓ removed \(name) from \(path.path)")
        }
    }
}

/// Curated list of MCP servers we know how to install. The bar for inclusion is:
/// (a) published on npm or another well-known registry, (b) actively maintained,
/// (c) doesn't require unusual setup beyond an env var. Add new entries here.
private struct MCPRegistryEntry {
    let name: String
    let description: String
    let command: String
    let args: [String]
    let requiredEnv: [String]
    let notes: String

    func toConfigDict() -> [String: Any] {
        var d: [String: Any] = ["command": command, "args": args]
        if !requiredEnv.isEmpty {
            // Pre-fill the env keys to nudge users to set them; values stay empty
            // so the runtime falls back to ProcessInfo lookups.
            d["env"] = Dictionary(uniqueKeysWithValues: requiredEnv.map { ($0, "") })
        }
        return d
    }
}

private enum MCPRegistry {
    static let all: [MCPRegistryEntry] = [
        .init(
            name: "filesystem",
            description: "Read/write files in a sandbox directory.",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem", "."],
            requiredEnv: [],
            notes: "Replace the trailing '.' with the directory you want to expose."
        ),
        .init(
            name: "github",
            description: "GitHub issues, PRs, and code search.",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-github"],
            requiredEnv: ["GITHUB_TOKEN"],
            notes: "Generate a personal access token with `repo` scope."
        ),
        .init(
            name: "git",
            description: "Local git repo operations (log, diff, branch).",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-git"],
            requiredEnv: [],
            notes: ""
        ),
        .init(
            name: "postgres",
            description: "Read-only Postgres queries.",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-postgres"],
            requiredEnv: ["POSTGRES_CONNECTION_STRING"],
            notes: "Connection string format: postgresql://user:pass@host:5432/db"
        ),
        .init(
            name: "sqlite",
            description: "Query a local SQLite database.",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-sqlite", "--db-path", "./db.sqlite"],
            requiredEnv: [],
            notes: "Edit --db-path to point at your file."
        ),
        .init(
            name: "fetch",
            description: "HTTP GET against allowlisted URLs.",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-fetch"],
            requiredEnv: [],
            notes: ""
        ),
        .init(
            name: "slack",
            description: "Read Slack channels and DMs.",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-slack"],
            requiredEnv: ["SLACK_BOT_TOKEN", "SLACK_TEAM_ID"],
            notes: "Create a Slack bot user with read scopes."
        ),
        .init(
            name: "puppeteer",
            description: "Headless-browser navigation and screenshots.",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-puppeteer"],
            requiredEnv: [],
            notes: "Downloads Chromium on first run (~150MB)."
        )
    ]

    static func find(_ name: String) -> MCPRegistryEntry? {
        all.first { $0.name == name.lowercased() }
    }

    static func closestMatch(to query: String) -> String? {
        let lower = query.lowercased()
        return all.map(\.name).min { lev(lower, $0) < lev(lower, $1) }
            .flatMap { lev(lower, $0) <= 3 ? $0 : nil }
    }

    private static func lev(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0...bChars.count)
        var curr = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            curr[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
    }
}
