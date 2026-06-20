import ArgumentParser
import Foundation

/// A subagent loaded from `.claude/agents/<name>.md` — Claude-Code-compatible
/// agent definitions with simple YAML frontmatter, used in Lite mode by
/// `lingcode ask --agent <name>` and `lingcode --agent <name>` (REPL).
///
/// "Lite" means: we don't dispatch the SDK's actual subagent machinery (which
/// would spawn a separate context window). We just apply the agent's
/// system-prompt body, tool allowlist, and model override to the main query.
/// That's enough to give users a way to run pre-canned personas like "reviewer"
/// or "test-writer" without having to remember the right `--allowed-tools`,
/// `--append-system-prompt`, and `--claude-model` combination every time.
struct Subagent {
    let name: String
    let description: String
    /// Frontmatter `tools:` — comma-separated tool names. Empty = no restriction.
    let tools: [String]
    /// Frontmatter `model:` — overrides the user's chosen model when set.
    let model: String?
    /// Markdown body after the frontmatter. Used as `appendSystemPrompt`.
    let body: String

    /// Builds the agent-registration dict expected by the bridge for Full mode.
    /// Keys mirror what the Claude Agent SDK accepts on its `agents:` option.
    /// Used by `lingcode --agent-mode=full --agent <name>`.
    func toBridgeDefinition() -> [String: String] {
        var d: [String: String] = [
            "description": description,
            "prompt": body
        ]
        if !tools.isEmpty { d["tools"] = tools.joined(separator: ",") }
        if let m = model { d["model"] = m }
        return d
    }

    /// Resolution order: project's `.claude/agents/<name>.md` → `~/.claude/agents/<name>.md`.
    /// Returns nil if not found at either location, or if the file is unparseable.
    static func load(name: String, cwd: URL) -> Subagent? {
        let candidates = [
            cwd.appendingPathComponent(".claude/agents/\(name).md"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/agents/\(name).md")
        ]
        for url in candidates {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            return parse(raw, fallbackName: name)
        }
        return nil
    }

    /// Lists all subagents discoverable in `.claude/agents/` (project + user).
    /// Used by `lingcode ask --agent` error suggestions and `--help`.
    static func list(cwd: URL) -> [String] {
        let dirs = [
            cwd.appendingPathComponent(".claude/agents"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/agents")
        ]
        var names = Set<String>()
        for dir in dirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for f in entries where f.hasSuffix(".md") {
                names.insert(String(f.dropLast(3)))
            }
        }
        return names.sorted()
    }

    private static func parse(_ raw: String, fallbackName: String) -> Subagent {
        var name = fallbackName
        var description = ""
        var tools: [String] = []
        var model: String?
        var body = raw

        // Detect a `---\n…\n---` frontmatter block at the very start.
        if raw.hasPrefix("---\n") || raw.hasPrefix("---\r\n") {
            let afterFirst = raw.index(raw.startIndex, offsetBy: 4)
            if let endRange = raw.range(of: "\n---\n", range: afterFirst..<raw.endIndex)
                              ?? raw.range(of: "\n---\r\n", range: afterFirst..<raw.endIndex) {
                let frontmatter = raw[afterFirst..<endRange.lowerBound]
                body = String(raw[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                for line in frontmatter.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let val = line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    switch key {
                    case "name":        name = val
                    case "description": description = val
                    case "model":       model = val.isEmpty ? nil : val
                    case "tools":
                        tools = val.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    default: break
                    }
                }
            }
        }
        return Subagent(name: name, description: description, tools: tools, model: model, body: body)
    }
}

/// Default value of `--agent-mode`. `lite` keeps the safe path that only edits
/// the system prompt + tool allowlist client-side; `full` registers the agent
/// with the SDK so it gets a separate context window and proper subagent
/// semantics in the transcript. Full is opt-in and may surface SDK quirks.
enum SubagentMode: String, ExpressibleByArgument {
    case lite, full
}
