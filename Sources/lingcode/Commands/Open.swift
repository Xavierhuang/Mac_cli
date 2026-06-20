#if os(macOS)
import ArgumentParser
import Foundation
import LingCodeIPC

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a file or folder in LingCode.app (launches the app if needed)."
    )

    @Argument(help: "Path to a file or folder. Defaults to the current directory.")
    var path: String = "."

    @Option(name: .shortAndLong, help: "Jump to this 1-indexed line number (file only).")
    var line: Int?

    @Option(name: .shortAndLong, help: "0-indexed character column within the target line (requires --line).")
    var column: Int?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() throws {
        try Open.dispatch(path: path, line: line, column: column, json: json)
    }

    /// Shared dispatch path used by both `lingcode open …` and the root-level
    /// VS Code-compat `lingcode -g <file>:<line>[:<col>]` form (the latter
    /// re-parses its arg in `LingCodeEntry.main` and calls in here so both
    /// surfaces share IPC routing, launch-fallback, and exit-code behaviour).
    static func dispatch(path: String, line: Int?, column: Int?, json: Bool) throws {
        let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: absolute) else {
            exitWith(json: json, ok: false, message: "Path does not exist: \(absolute)")
        }

        let client = IPCClient()
        let request = IPCRequest(
            method: IPCMethod.open.rawValue,
            params: IPCParams(path: absolute, line: line, column: column)
        )

        if client.appIsLikelyRunning {
            do {
                let response = try client.send(request)
                if response.ok {
                    exitWith(json: json, ok: true, message: response.result?.message ?? "Opened \(absolute)")
                } else {
                    exitWith(json: json, ok: false, message: response.error?.message ?? "open failed")
                }
            } catch {
                exitWith(json: json, ok: false, message: "\(error)")
            }
        }

        // App not running: hand off via the `lingcode://open` URL scheme so the
        // app picks up the line/column on cold launch through `handleDeepLink`
        // → `enqueueOpenFileURL`. `/usr/bin/open -a LingCode <path>` drops the
        // line argument (file-association launch doesn't carry it), so we use
        // the URL scheme instead and that handler routes folder vs. file the
        // same way the IPC dispatcher does. The pending-URL queue in
        // AppDelegate covers the cold-launch race where ContentView hasn't
        // mounted yet — same path as Finder "Open With".
        var urlString = "lingcode://open?path=" + percentEncoded(absolute)
        if let line, line >= 1 {
            urlString += "&line=\(line)"
        }
        if let column, column >= 0 {
            urlString += "&column=\(column)"
        }
        guard let url = URL(string: urlString) else {
            exitWith(json: json, ok: false, message: "Failed to build lingcode://open URL")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [url.absoluteString]
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                let posSuffix = Self.suffix(line: line, column: column)
                exitWith(json: json, ok: true, message: "Launched LingCode.app with \(absolute)\(posSuffix)")
            } else {
                exitWith(json: json, ok: false, message: "open(1) exited with status \(task.terminationStatus). Is LingCode.app installed?")
            }
        } catch {
            exitWith(json: json, ok: false, message: "Failed to launch LingCode.app: \(error.localizedDescription)")
        }
    }

    private static func suffix(line: Int?, column: Int?) -> String {
        guard let line, line >= 1 else { return "" }
        if let column, column >= 0 { return ":\(line):\(column)" }
        return ":\(line)"
    }

    private static func percentEncoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}

#endif
