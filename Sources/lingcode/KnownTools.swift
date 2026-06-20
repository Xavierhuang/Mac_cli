import Foundation

/// Validates `--allowed-tools` / `--disallowed-tools` against the set of tools
/// the Claude Agent SDK actually exposes. A typo today lands as "tool not found"
/// only when the agent loop tries to dispatch — which is far from the call site
/// and confuses users. Catching it at parse time with a "did you mean…" hint is
/// strictly better.
///
/// Custom tools (MCP-provided) are NOT in this list; we let those through
/// without validation. Discrimination heuristic: any name with a colon (e.g.
/// `mcp__filesystem__read_file`) or starting with `mcp__` skips validation.
enum KnownTools {
    /// Built-in Claude Agent SDK tools, names as they appear in tool_use blocks
    /// and in `--allowed-tools` flags.
    static let builtins: Set<String> = [
        "Read", "Write", "Edit", "Bash", "Grep", "Glob",
        "WebFetch", "WebSearch", "Task", "TodoWrite", "NotebookEdit",
        "BashOutput", "KillBash"
    ]

    /// Returns `nil` if all tools are recognized. Otherwise returns an error
    /// message with a "did you mean…" hint for the first unknown tool.
    static func validate(_ names: [String]) -> String? {
        for name in names {
            if name.isEmpty { continue }
            // Skip MCP-prefixed tools — those come from external servers.
            if name.hasPrefix("mcp__") || name.contains(":") { continue }
            if builtins.contains(name) { continue }
            let suggestion = closestMatch(to: name)
            let suggestionPart = suggestion.map { " — did you mean '\($0)'?" } ?? ""
            return "unknown tool '\(name)'\(suggestionPart) Known: \(builtins.sorted().joined(separator: ", "))"
        }
        return nil
    }

    private static func closestMatch(to name: String) -> String? {
        let lower = name.lowercased()
        var best: (String, Int)?
        for builtin in builtins {
            let dist = levenshtein(lower, builtin.lowercased())
            if dist <= 3, best == nil || dist < best!.1 {
                best = (builtin, dist)
            }
        }
        return best?.0
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
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
