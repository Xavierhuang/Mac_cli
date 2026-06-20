//
//  LingCodeEntry.swift
//  lingcode
//
//  Entry point for the `lingcode` terminal binary.
//  Drives the running LingCode.app over Unix-socket IPC; falls back to a
//  headless Claude run for `repl`/`ask` when the app isn't open.
//

import ArgumentParser
import Foundation

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct LingCode: AsyncParsableCommand {
    /// Overrides ArgumentParser's default `main()` so we can intercept "unknown
    /// subcommand" errors and print a "did you mean…" hint before falling back
    /// to the standard usage error. Everything else delegates to ArgumentParser.
    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst())

        // VS Code-compat shortcut: `lingcode -g <file>:<line>[:<col>]` is the
        // canonical "goto file at line" call shape that the wider editor-CLI
        // ecosystem (`code -g`, `cursor -g`) standardised on. ArgumentParser
        // can't model it without a custom flag at every subcommand, so we
        // intercept it here, parse the trailing `file:N[:M]` triplet, and
        // re-route into the `Open` subcommand's shared dispatch path. Anything
        // that doesn't match the exact shape falls through to ArgumentParser.
        // The `LINGCODE_QUIET=1` / `--json` toggles aren't honoured here — it's
        // a one-shot launcher, not a query.
        #if os(macOS)
        if argv.count >= 2, argv[0] == "-g" || argv[0] == "--goto" {
            if let parsed = parseGotoArgument(argv[1]) {
                do {
                    try Open.dispatch(path: parsed.path, line: parsed.line, column: parsed.column, json: false)
                } catch {
                    exit(withError: error)
                }
                // Open.dispatch always terminates via exitWith(...), but be
                // defensive: if a future refactor returns normally, fall through.
                return
            } else {
                FileHandle.standardError.write(Data(
                    "lingcode: -g expects \"<file>:<line>[:<col>]\" — got: \(argv[1])\n".utf8
                ))
                // Disambiguate from the inherited `ParsableCommand.exit(_:)`
                // instance method — bare `exit(2)` resolves to that and won't
                // compile inside the struct's static context.
                Darwin.exit(2)
            }
        }
        #endif

        do {
            var command = try parseAsRoot(argv)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            if let first = argv.first, !first.hasPrefix("-") {
                let msg = String(describing: error).lowercased()
                if msg.contains("unknown") || msg.contains("unexpected"),
                   let suggestion = closestSubcommandName(to: first) {
                    FileHandle.standardError.write(Data(
                        "lingcode: '\(first)' is not a known subcommand. Did you mean '\(suggestion)'?\n".utf8
                    ))
                }
            }
            exit(withError: error)
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "lingcode",
        abstract: "Agentic coding assistant. Run with no arguments for an interactive session.",
        discussion: """
        `lingcode` with no arguments starts an interactive REPL (same as `lingcode repl`).
        The default provider is Claude (full tool use via the Agent SDK); swap with
        `--provider` for OpenAI-compatible endpoints (OpenAI, Groq, Together, OpenRouter,
        Mistral, xAI, Fireworks, Ollama, etc. — text-only, no tools).

        One-shot:         lingcode ask "explain this error" < log.txt
        Session:          lingcode                         # starts REPL
                          lingcode --provider ollama --model llama3.2
        Authentication:   lingcode auth login              # browser-assisted key setup
                          lingcode auth status             # show configured providers
        Project setup:    lingcode init                    # generate CLAUDE.md

        Output control:   --no-color (or NO_COLOR=1)       # disable ANSI styling
                          --quiet    (or LINGCODE_QUIET=1) # suppress banner/spinner/summary

        Exit codes:
          0   success
          1   runtime failure (network, auth, tool error, prompt rejected)
          2   usage error (bad flag, missing required argument)
          130 interrupted (Ctrl-C)

        Run `lingcode help <subcommand>` for detailed options on any command.
        """,
        version: "0.8.22",
        subcommands: subcommandList(),
        defaultSubcommand: Repl.self
    )
}

#if os(macOS)
/// Parses the `<file>:<line>[:<col>]` argument of `lingcode -g <arg>`. Returns
/// nil if the shape is wrong (no colon, non-numeric line, etc.) — the caller
/// prints a usage error in that case. Paths containing colons would be
/// ambiguous; we treat the LAST one or two colon-separated tokens that parse
/// as Int as the line/column, which lets `Some:File.swift:42` work (the
/// dominant case) while still tolerating `/abs/path:42:8`.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
internal func parseGotoArgument(_ arg: String) -> (path: String, line: Int?, column: Int?)? {
    let parts = arg.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2 else { return nil }

    // Try parsing the last two tokens as line:col. If both numeric: file is the
    // remainder. If only the last is numeric: file is the remainder + line.
    if parts.count >= 3,
       let col = Int(parts[parts.count - 1]),
       let line = Int(parts[parts.count - 2]) {
        let path = parts[0..<(parts.count - 2)].joined(separator: ":")
        guard !path.isEmpty else { return nil }
        return (path, line, col)
    }
    if let line = Int(parts[parts.count - 1]) {
        let path = parts[0..<(parts.count - 1)].joined(separator: ":")
        guard !path.isEmpty else { return nil }
        return (path, line, nil)
    }
    return nil
}
#endif

/// Returns the subcommand name nearest to `name` (Levenshtein ≤ 3) or nil.
/// Powers the `did you mean…` suggestion when a user mistypes a subcommand.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
private func closestSubcommandName(to name: String) -> String? {
    let candidates = subcommandList().map { String(describing: $0).lowercased() }
        + ["mcp", "plugin"] // anticipate near-future subcommands
    let lower = name.lowercased()
    var best: (String, Int)?
    for c in candidates {
        let dist = lev(lower, c)
        if dist <= 3, best == nil || dist < best!.1 { best = (c, dist) }
    }
    return best?.0
}

private func lev(_ a: String, _ b: String) -> Int {
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

/// Top-level subcommands. Linux builds drop the IPC subcommands that talk to
/// the macOS app's Unix-domain socket — they wouldn't have anything to talk to.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
fileprivate func subcommandList() -> [ParsableCommand.Type] {
    var cmds: [ParsableCommand.Type] = [
        Repl.self,
        Ask.self,
        Auth.self,
        Build.self,
        Convert.self,
        Deploy.self,
        Config.self,
        Init.self,
        History.self,
        Completion.self,
        Upgrade.self,
        Telemetry.self,
        MCP.self,
        Plugin.self,
        Trust.self,
        Worktree.self,
        DoctorCommand.self,
        ExportCommand.self,
    ]
    #if os(macOS)
    cmds.append(contentsOf: [
        Ping.self,
        Open.self,
        Status.self,
        Watch.self,
        Install.self,
        BridgeCommand.self, // talks to the Mac-side bridge daemon
    ])
    if #available(macOS 13, *) {
        cmds.append(Serve.self)
    }
    cmds.append(AcpServe.self)
    #endif
    return cmds
}
