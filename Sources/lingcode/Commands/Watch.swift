#if os(macOS)
import ArgumentParser
import Foundation
import LingCodeIPC

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Stream agent activity from the running app. Ctrl-C to stop."
    )

    func run() throws {
        let client = IPCClient()
        guard client.appIsLikelyRunning else {
            FileHandle.standardError.write("LingCode.app is not running.\n".data(using: .utf8)!)
            Foundation.exit(1)
        }
        let request = IPCRequest(method: IPCMethod.watch.rawValue)
        do {
            try client.sendStreaming(request) { frame in
                let event = frame.result?.event ?? "frame"
                let msg = frame.result?.message ?? ""
                print("[\(event)] \(msg)")
            }
        } catch {
            FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
            Foundation.exit(1)
        }
    }
}

#endif
