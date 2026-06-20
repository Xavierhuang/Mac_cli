#if os(macOS)
import ArgumentParser
import Foundation
import LingCodeIPC

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the running app's focused project and active agents."
    )

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() throws {
        let client = IPCClient()
        guard client.appIsLikelyRunning else {
            exitWith(json: json, ok: false, message: "LingCode.app is not running.")
        }

        do {
            let response = try client.send(IPCRequest(method: IPCMethod.status.rawValue))
            guard response.ok, let result = response.result else {
                exitWith(json: json, ok: false, message: response.error?.message ?? "status failed")
            }
            if json {
                let payload: [String: Any] = [
                    "ok": true,
                    "projectPath": result.projectPath as Any,
                    "activeSessionID": result.activeSessionID as Any,
                    "activeTaskCount": result.activeTaskCount ?? 0
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
                   let s = String(data: data, encoding: .utf8) {
                    print(s)
                }
                Foundation.exit(0)
            }
            let project = result.projectPath ?? "(no project open)"
            let session = result.activeSessionID ?? "(none)"
            let tasks = result.activeTaskCount ?? 0
            print("project:         \(project)")
            print("active session:  \(session)")
            print("active tasks:    \(tasks)")
            Foundation.exit(0)
        } catch {
            exitWith(json: json, ok: false, message: "\(error)")
        }
    }
}

#endif
