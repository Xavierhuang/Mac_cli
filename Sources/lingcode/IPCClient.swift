#if os(macOS)
//
//  IPCClient.swift
//  lingcode
//
//  POSIX Unix-domain socket client. Connects to LingCode.app's IPC server,
//  sends a single request, reads one or more newline-delimited JSON responses.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import LingCodeIPC

public enum IPCClientError: Error, CustomStringConvertible {
    case connectFailed(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
    case encodingFailed
    case malformedResponse

    public var description: String {
        switch self {
        case .connectFailed(let errno):
            return "Could not connect to LingCode.app IPC socket (errno \(errno)). Is the app running?"
        case .writeFailed(let e):  return "Socket write failed (errno \(e))."
        case .readFailed(let e):   return "Socket read failed (errno \(e))."
        case .encodingFailed:      return "Failed to encode request as JSON."
        case .malformedResponse:   return "App returned malformed IPC response."
        }
    }
}

public final class IPCClient {
    private let socketPath: String

    public init(socketPath: String = IPCSocket.defaultPath) {
        self.socketPath = socketPath
    }

    public var appIsLikelyRunning: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    /// Opens a connection, sends one request, returns the first response.
    /// Use `sendStreaming` for methods that stream multiple frames.
    public func send(_ request: IPCRequest) throws -> IPCResponse {
        let fd = try connect()
        defer { Darwin.close(fd) }
        try writeFrame(fd: fd, request: request)
        return try readFrame(fd: fd)
    }

    /// Opens a connection, sends one request, streams responses to `onFrame`.
    /// Returns when the server sends a frame with `streaming == false || nil`.
    public func sendStreaming(_ request: IPCRequest, onFrame: (IPCResponse) -> Void) throws {
        let fd = try connect()
        defer { Darwin.close(fd) }
        try writeFrame(fd: fd, request: request)
        while true {
            let response = try readFrame(fd: fd)
            onFrame(response)
            if response.streaming != true { break }
        }
    }

    // MARK: - Socket plumbing

    private func connect() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCClientError.connectFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // sun_path is a C char array; copy the utf8 bytes in.
        let pathBytes = Array(socketPath.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < pathCapacity else {
            Darwin.close(fd)
            throw IPCClientError.connectFailed(ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { cPtr in
                for (i, b) in pathBytes.enumerated() { cPtr[i] = CChar(bitPattern: b) }
                cPtr[pathBytes.count] = 0
            }
        }

        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(fd, sp, addrSize)
            }
        }
        guard connectResult == 0 else {
            let e = errno
            Darwin.close(fd)
            throw IPCClientError.connectFailed(e)
        }
        return fd
    }

    private func writeFrame(fd: Int32, request: IPCRequest) throws {
        let encoder = JSONEncoder()
        guard var data = try? encoder.encode(request) else {
            throw IPCClientError.encodingFailed
        }
        data.append(0x0A) // newline terminator
        try data.withUnsafeBytes { buf in
            var offset = 0
            let total = buf.count
            while offset < total {
                let written = Darwin.write(fd, buf.baseAddress!.advanced(by: offset), total - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw IPCClientError.writeFailed(errno)
                }
                offset += written
            }
        }
    }

    private var readBuffer = Data()

    private func readFrame(fd: Int32) throws -> IPCResponse {
        // Read byte chunks until we see a newline or the connection closes.
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !readBuffer.contains(0x0A) {
            let n = chunk.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if n == 0 { throw IPCClientError.malformedResponse }   // peer closed mid-frame
            if n < 0 {
                if errno == EINTR { continue }
                throw IPCClientError.readFailed(errno)
            }
            readBuffer.append(chunk, count: n)
        }
        guard let nlIndex = readBuffer.firstIndex(of: 0x0A) else {
            throw IPCClientError.malformedResponse
        }
        let frame = readBuffer.subdata(in: readBuffer.startIndex..<nlIndex)
        readBuffer.removeSubrange(readBuffer.startIndex...nlIndex)
        do {
            return try JSONDecoder().decode(IPCResponse.self, from: frame)
        } catch {
            throw IPCClientError.malformedResponse
        }
    }
}

#endif
