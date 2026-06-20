//
//  IPCProtocol.swift
//  LingCodeIPC
//
//  Wire protocol between the `lingcode` CLI and the LingCode.app IPC server.
//  Transport: Unix domain socket, newline-delimited JSON (one object per line).
//

import Foundation

public enum IPCSocket {
    /// Per-user socket path the app listens on and the CLI connects to.
    /// `~/Library/Application Support/LingCode/ipc.sock`.
    public static var defaultPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return dir.appendingPathComponent("LingCode/ipc.sock").path
    }
}

// MARK: - Request

public struct IPCRequest: Codable {
    public let id: String
    public let method: String
    public let params: IPCParams?

    public init(id: String = UUID().uuidString, method: String, params: IPCParams? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public enum IPCMethod: String {
    case ping
    case open       // params: { path: String, line: Int?, column: Int? }
    case status     // params: nil
    case ask        // params: { prompt: String }  (streams response events back)
    case watch      // params: nil                  (streams events until disconnect)
}

// MARK: - Response

public struct IPCResponse: Codable {
    public let id: String
    public let ok: Bool
    public let result: IPCResult?
    public let error: IPCError?
    /// When true, more frames will follow for this request (streaming responses).
    public let streaming: Bool?

    public init(id: String, ok: Bool, result: IPCResult? = nil, error: IPCError? = nil, streaming: Bool? = nil) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
        self.streaming = streaming
    }
}

public struct IPCError: Codable, Error {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public static let appNotRunning = IPCError(
        code: "app_not_running",
        message: "LingCode.app is not running. Launch the app or run `lingcode ask --headless` (requires DEEPSEEK_API_KEY)."
    )
    public static func unknownMethod(_ m: String) -> IPCError {
        IPCError(code: "unknown_method", message: "Unknown IPC method: \(m)")
    }
    public static func badParams(_ m: String) -> IPCError {
        IPCError(code: "bad_params", message: m)
    }
}

// MARK: - Untyped params / result bag
//
// The CLI and app know each method's shape; we pass through a flexible bag
// instead of one Codable per method. Keep the field names stable — they are
// the public contract for external scripts that talk to the socket directly.

public struct IPCParams: Codable {
    public var path: String?
    public var line: Int?
    /// 0-indexed character column within the target line (same convention as
    /// `EditorViewModel.scrollActiveDocumentToLineAndColumn`). Optional —
    /// callers that only have a line jump leave this nil.
    public var column: Int?
    public var prompt: String?
    public var sessionID: String?

    public init(path: String? = nil, line: Int? = nil, column: Int? = nil, prompt: String? = nil, sessionID: String? = nil) {
        self.path = path
        self.line = line
        self.column = column
        self.prompt = prompt
        self.sessionID = sessionID
    }
}

public struct IPCResult: Codable {
    /// For `ping`: app version.
    public var version: String?
    /// For `status`: the workspace currently focused in the app.
    public var projectPath: String?
    /// For `status`: active agent session id, if any.
    public var activeSessionID: String?
    /// For `status`: number of running agent tasks.
    public var activeTaskCount: Int?
    /// Streaming frames (ask / watch): one text chunk.
    public var chunk: String?
    /// Streaming frames (watch): a structured event name (e.g., "tool_call", "step_completed").
    public var event: String?
    /// Generic human-readable string for simple acks.
    public var message: String?

    public init(
        version: String? = nil,
        projectPath: String? = nil,
        activeSessionID: String? = nil,
        activeTaskCount: Int? = nil,
        chunk: String? = nil,
        event: String? = nil,
        message: String? = nil
    ) {
        self.version = version
        self.projectPath = projectPath
        self.activeSessionID = activeSessionID
        self.activeTaskCount = activeTaskCount
        self.chunk = chunk
        self.event = event
        self.message = message
    }
}
