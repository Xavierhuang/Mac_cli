import ArgumentParser
import Foundation
import LingCodeAgentCore

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct History: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "List past LingCode sessions.",
        discussion: """
        Shows sessions saved in ~/.lingcode/history.jsonl.
        Defaults to sessions from the current directory.
        """
    )

    @Option(name: .long, help: "Filter to a specific project directory (defaults to cwd).")
    var project: String?

    @Flag(name: .long, help: "Show sessions from all directories.")
    var all: Bool = false

    @Option(name: .long, help: "Maximum number of entries to show.")
    var limit: Int = 20

    @Flag(name: .long, help: "Output as JSON array.")
    var json: Bool = false

    @Flag(name: .long, help: "Clear all history.")
    var clear: Bool = false

    func run() throws {
        if clear {
            SessionHistory.clear()
            print("History cleared.")
            return
        }

        let entries: [SessionHistoryEntry]
        if all {
            entries = Array(SessionHistory.loadAll().prefix(limit))
        } else {
            let cwd = project.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            entries = Array(SessionHistory.loadForCwd(cwd).prefix(limit))
        }

        if entries.isEmpty {
            print("No sessions found.")
            return
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(entries),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let cwdHome = NSHomeDirectory()

        for entry in entries {
            let date = df.string(from: entry.startedAt)
            let shortCwd = entry.cwd.hasPrefix(cwdHome)
                ? "~" + entry.cwd.dropFirst(cwdHome.count)
                : entry.cwd
            let shortId = String(entry.sessionId.prefix(8))
            let preview = entry.promptPreview.isEmpty ? "" : "  \"\(entry.promptPreview)\""
            print("[\(date)]  \(shortId)…  \(shortCwd)\(preview)")
        }
    }
}
