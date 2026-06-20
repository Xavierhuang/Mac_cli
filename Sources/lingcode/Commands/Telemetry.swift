import ArgumentParser
import Foundation
import LingCodeAgentCore

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Telemetry: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "telemetry",
        abstract: "Toggle anonymous CLI usage telemetry.",
        discussion: """
        LingCode collects anonymous usage data by default to inform the
        roadmap: a daily heartbeat (install ID, version, OS, arch) plus
        per-turn model events (provider, model, token counts, latency).
        Never sent: prompts, file contents, API keys, file paths.

        Storage:    ~/.config/lingcode/telemetry.json (chmod 600)
        Endpoint:   https://lingcode.dev/api/cli/heartbeat
                    https://lingcode.dev/api/telemetry/model-events

        Examples:
          lingcode telemetry              # show current state
          lingcode telemetry off          # disable
          lingcode telemetry on           # re-enable
        """,
        subcommands: [Status.self, On.self, Off.self, Sample.self],
        defaultSubcommand: Status.self
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show whether telemetry is enabled and the install ID."
        )
        func run() throws {
            let c = TelemetryClient.shared
            let state = c.isEnabled ? "ON" : "OFF"
            Swift.print("telemetry: \(state)")
            Swift.print("installId: \(c.currentInstallId)")
            Swift.print("opt out:   lingcode telemetry off")
        }
    }

    struct On: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "on",
            abstract: "Enable anonymous telemetry."
        )
        func run() throws {
            TelemetryClient.shared.setEnabled(true)
            Swift.print("✓ telemetry enabled")
        }
    }

    struct Off: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "off",
            abstract: "Disable anonymous telemetry. Heartbeat and model events stop immediately."
        )
        func run() throws {
            TelemetryClient.shared.setEnabled(false)
            Swift.print("✓ telemetry disabled")
        }
    }

    struct Sample: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sample",
            abstract: "Print exactly what gets sent in the next heartbeat / model event — for transparency."
        )
        @Flag(name: .long, help: "Output JSON instead of the human-readable preview.")
        var json: Bool = false

        func run() throws {
            let c = TelemetryClient.shared
            let payload: [String: Any] = [
                "kind": "heartbeat",
                "installId": c.currentInstallId,
                "version": "0.8.16",
                "os": "macOS",
                "arch": archString(),
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            let modelEventShape: [String: Any] = [
                "kind": "model_event",
                "installId": c.currentInstallId,
                "provider": "<provider name, e.g. claude>",
                "model": "<model id, e.g. claude-sonnet-4-6>",
                "promptTokens": "<int>",
                "completionTokens": "<int>",
                "latencyMs": "<int>",
                "outcome": "<success|error|cancelled>",
                "timestamp": "<ISO 8601>"
            ]
            let combined: [String: Any] = [
                "heartbeat": payload,
                "modelEventShape": modelEventShape,
                "neverSent": [
                    "prompts", "assistant_text", "file_contents", "file_paths",
                    "api_keys", "session_ids", "tool_inputs", "tool_outputs"
                ]
            ]
            if json {
                let data = try JSONSerialization.data(withJSONObject: combined, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                Swift.print("Heartbeat (sent once per day on first lingcode invocation):")
                for (k, v) in payload.sorted(by: { $0.key < $1.key }) {
                    Swift.print("  \(k.padding(toLength: 12, withPad: " ", startingAt: 0)) \(v)")
                }
                Swift.print("\nModel event (sent per agent turn):")
                for (k, v) in modelEventShape.sorted(by: { $0.key < $1.key }) {
                    Swift.print("  \(k.padding(toLength: 18, withPad: " ", startingAt: 0)) \(v)")
                }
                Swift.print("\nNever sent:")
                for k in (combined["neverSent"] as! [String]) {
                    Swift.print("  • \(k)")
                }
                Swift.print("\nDisable everything:  lingcode telemetry off")
                Swift.print("Status:              telemetry is currently \(c.isEnabled ? "ON" : "OFF")")
            }
        }

        private func archString() -> String {
            #if arch(arm64)
            return "arm64"
            #elseif arch(x86_64)
            return "x86_64"
            #else
            return "unknown"
            #endif
        }
    }
}
