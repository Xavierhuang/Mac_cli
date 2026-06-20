#if os(macOS)
import ArgumentParser
import Foundation
import LingCodeIPC

struct Ping: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ping",
        abstract: "Check whether LingCode.app is running and responsive."
    )

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() throws {
        let client = IPCClient()
        guard client.appIsLikelyRunning else {
            exitWith(json: json, ok: false, message: "LingCode.app is not running.")
        }
        do {
            let response = try client.send(IPCRequest(method: IPCMethod.ping.rawValue))
            if response.ok {
                let version = response.result?.version ?? "unknown"
                exitWith(json: json, ok: true, message: "pong (app version \(version))")
            } else {
                exitWith(json: json, ok: false, message: response.error?.message ?? "ping failed")
            }
        } catch {
            exitWith(json: json, ok: false, message: "\(error)")
        }
    }
}

func exitWith(json: Bool, ok: Bool, message: String) -> Never {
    if json {
        let payload: [String: Any] = ["ok": ok, "message": message]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    } else {
        FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    }
    Foundation.exit(ok ? 0 : 1)
}

#endif
