import ArgumentParser
import Foundation
import LingCodeAgentCore

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Get or set LingCode CLI configuration.",
        discussion: """
        Configuration is stored in ~/.lingcode/config.json.
        Environment variables always take precedence over stored config values.

        Available keys:
          default-provider        claude or deepseek (default: claude)
          default-claude-model    e.g. claude-sonnet-4-6
          default-permission-mode default, acceptEdits, plan, dontAsk, bypassPermissions
          default-max-turns       positive integer (default: 50)
          anthropic-api-key       stored key (env ANTHROPIC_API_KEY wins at runtime)
          deepseek-api-key        stored key (env DEEPSEEK_API_KEY wins at runtime)

        Two config homes — both intentional:
          ~/.lingcode/   CLI-only state: this config.json, history.jsonl, sessions/.
                         Owned by the lingcode binary. Safe to delete to reset CLI state.
          ~/.claude/     Ecosystem files shared with Claude Code: CLAUDE.md, MCP servers
                         (.mcp.json), commands/, agents/, output-styles/, hooks. Lives
                         here so existing Claude Code users get their commands and skills
                         for free without copying anything. Read-only from lingcode's
                         perspective — we never write to it unless you run `lingcode init`.
        """,
        subcommands: [Get.self, Set.self, Unset.self, List.self]
    )

    // MARK: - get

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Print the value of a config key."
        )

        @Argument(help: "Config key to read.")
        var key: String

        func run() throws {
            guard let value = ConfigStore.get(key: key) else {
                FileHandle.standardError.write(Data("lingcode: unknown config key '\(key)'\n".utf8))
                throw ExitCode(1)
            }
            print(value)
        }
    }

    // MARK: - set

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set a config key to a value."
        )

        @Argument(help: "Config key.")
        var key: String

        @Argument(help: "Value to store.")
        var value: String

        func run() throws {
            do {
                try ConfigStore.set(key: key, value: value)
                print("✓ \(key) = \(key.contains("key") ? "****" : value)")
            } catch let err as ConfigError {
                FileHandle.standardError.write(Data("lingcode: \(err.description)\n".utf8))
                throw ExitCode(1)
            }
        }
    }

    // MARK: - unset

    struct Unset: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "unset",
            abstract: "Clear a config key (restore to default)."
        )

        @Argument(help: "Config key to clear.")
        var key: String

        func run() throws {
            do {
                try ConfigStore.unset(key: key)
                print("✓ \(key) cleared")
            } catch let err as ConfigError {
                FileHandle.standardError.write(Data("lingcode: \(err.description)\n".utf8))
                throw ExitCode(1)
            }
        }
    }

    // MARK: - list

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "Print all config key-value pairs."
        )

        @Flag(name: .long, help: "Output as JSON.")
        var json: Bool = false

        func run() throws {
            let entries = ConfigStore.allEntries()
            if json {
                var obj: [String: String] = [:]
                for (k, v) in entries { obj[k] = v }
                let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
                print(String(data: data, encoding: .utf8) ?? "{}")
            } else {
                let maxKey = entries.map { $0.key.count }.max() ?? 0
                for (k, v) in entries {
                    let pad = String(repeating: " ", count: maxKey - k.count)
                    print("\(k)\(pad)  \(v)")
                }
            }
        }
    }
}
