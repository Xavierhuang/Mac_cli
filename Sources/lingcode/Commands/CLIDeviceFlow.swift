// Browser-assisted device flow for `lingcode auth login --provider lingmodel`.
//
// `gh auth login`-style: the CLI starts a localhost HTTP listener on a random
// port, opens https://lingcode.dev/cli-token.html?session=<id>&redirect=<port>
// in the user's browser, and waits for the page to bounce the freshly-minted
// token back as a GET to that local listener. The browser closes the loop —
// no manual copy/paste required.
//
// Implementation is plain BSD sockets via Darwin. The first iteration used
// Network.framework's NWListener, but every parameter combination returned
// EINVAL on bind in the standalone-CLI build — likely an interaction with
// signing / sandboxing in the embedded universal binary. POSIX sockets bind
// without ceremony, so we skip the framework entirely.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum CLIDeviceFlow {

    enum FlowError: Error, CustomStringConvertible {
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)
        case acceptTimedOut
        case sessionMismatch
        case noToken
        case cancelled

        var description: String {
            switch self {
            case .bindFailed(let e):    return "bind failed (errno=\(e): \(String(cString: strerror(e))))"
            case .listenFailed(let e):  return "listen failed (errno=\(e))"
            case .acceptTimedOut:       return "browser did not call back in time"
            case .sessionMismatch:      return "session id mismatch in callback"
            case .noToken:              return "callback was missing a token"
            case .cancelled:            return "cancelled"
            }
        }
    }

    /// Result of a successful device-flow handoff.
    struct Result {
        let token: String
    }

    /// Run the full flow: bind, open browser, wait for callback. Throws on
    /// timeout / bind failure / mismatch so the caller can fall back.
    static func run(
        baseURL: String,
        timeoutSeconds: TimeInterval = 120,
        openBrowser: Bool = true
    ) async throws -> Result {
        let session = UUID().uuidString
        let (listenFd, port) = try bindEphemeralLocalhost()

        // Always close the listener no matter how we exit.
        defer { close(listenFd) }

        let redirectRaw = "http://localhost:\(port)/"
        var components = URLComponents(string: baseURL)!
        components.queryItems = [
            URLQueryItem(name: "session", value: session),
            URLQueryItem(name: "redirect", value: redirectRaw),
        ]
        guard let authURL = components.url else { throw FlowError.bindFailed(errno: 0) }

        if openBrowser {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = [authURL.absoluteString]
            try? proc.run()
            // Don't waitUntilExit — listener loop must keep running.
        } else {
            FileHandle.standardError.write(Data("Open this URL to continue: \(authURL.absoluteString)\n".utf8))
        }

        // Race the accept loop against a timeout. Both run on detached
        // tasks; whichever finishes first wins, the other is cancelled.
        return try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask {
                try acceptAndParse(listenFd: listenFd, expectedSession: session)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw FlowError.acceptTimedOut
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    // MARK: - socket helpers

    /// Bind a TCP socket to 127.0.0.1 on an ephemeral port. Returns the open
    /// file descriptor and the assigned port number.
    private static func bindEphemeralLocalhost() throws -> (Int32, UInt16) {
        // Darwin types SOCK_STREAM as Int32; Glibc types it as the enum
        // `__socket_type`, which needs a `.rawValue` cast to Int32. Branch.
        #if canImport(Darwin)
        let sockType: Int32 = SOCK_STREAM
        #else
        let sockType: Int32 = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_INET, sockType, 0)
        guard fd >= 0 else { throw FlowError.bindFailed(errno: errno) }

        // SO_REUSEADDR: not strictly required for ephemeral ports, but lets
        // a quick re-run of the CLI not fail on TIME_WAIT if the previous
        // run picked the same port by chance.
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // 0 = kernel picks ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // loopback only
        // `sin_len` is BSD-only (Darwin); Linux's sockaddr_in has no such field.
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw FlowError.bindFailed(errno: err)
        }

        // Find out which port the kernel actually assigned.
        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assigned) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        guard nameResult == 0 else {
            let err = errno
            close(fd)
            throw FlowError.bindFailed(errno: err)
        }
        // sin_port is in network byte order — flip to host order for printing.
        let port = UInt16(bigEndian: assigned.sin_port)

        guard listen(fd, 1) == 0 else {
            let err = errno
            close(fd)
            throw FlowError.listenFailed(errno: err)
        }

        return (fd, port)
    }

    /// Block on accept(), parse the first HTTP request that arrives, validate
    /// the session id, write a small HTML response, return the token.
    private static func acceptAndParse(listenFd: Int32, expectedSession: String) throws -> Result {
        // accept() blocks until the browser hits the localhost URL.
        let conn = accept(listenFd, nil, nil)
        guard conn >= 0 else { throw FlowError.noToken }
        defer { close(conn) }

        // Read up to 16 KB. An HTTP GET request line + headers fits comfortably.
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        let n = buf.withUnsafeMutableBytes { rawPtr -> ssize_t in
            guard let baseAddr = rawPtr.baseAddress else { return -1 }
            return read(conn, baseAddr, rawPtr.count)
        }
        guard n > 0 else { throw FlowError.noToken }

        let request = String(decoding: buf.prefix(Int(n)), as: UTF8.self)

        // Parse first line: "GET /?session=...&token=... HTTP/1.1"
        guard let firstLine = request.split(separator: "\r\n").first,
              let pathStart = firstLine.range(of: " ")?.upperBound,
              let pathEnd = firstLine.range(of: " HTTP/")?.lowerBound,
              pathStart < pathEnd
        else {
            sendHTTP(conn: conn, status: 400, html: "<h1>Bad request</h1>")
            throw FlowError.noToken
        }
        let path = String(firstLine[pathStart..<pathEnd])
        let query = parseQuery(path: path)

        let gotSession = query["session"] ?? ""
        let gotToken = query["token"] ?? ""

        guard gotSession == expectedSession else {
            sendHTTP(conn: conn, status: 400, html: "<h1>Session mismatch</h1>")
            throw FlowError.sessionMismatch
        }
        guard !gotToken.isEmpty else {
            sendHTTP(conn: conn, status: 400, html: "<h1>No token in callback</h1>")
            throw FlowError.noToken
        }

        sendHTTP(
            conn: conn,
            status: 200,
            html:
                "<!doctype html><meta charset='utf-8'><title>LingCode CLI</title>" +
                "<style>body{font-family:-apple-system,sans-serif;text-align:center;padding:80px 24px;color:#222}" +
                "h1{font-weight:600;font-size:1.5rem;margin:0 0 8px}p{color:#666;margin:0}</style>" +
                "<h1>✓ CLI signed in</h1><p>You can close this tab and return to your terminal.</p>"
        )
        return Result(token: gotToken)
    }

    private static func sendHTTP(conn: Int32, status: Int, html: String) {
        let statusText = (status == 200) ? "OK" : "Bad Request"
        let body = Data(html.utf8)
        let header =
            "HTTP/1.1 \(status) \(statusText)\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(body)
        _ = packet.withUnsafeBytes { rawPtr -> ssize_t in
            guard let baseAddr = rawPtr.baseAddress else { return -1 }
            return write(conn, baseAddr, rawPtr.count)
        }
    }

    private static func parseQuery(path: String) -> [String: String] {
        guard let q = path.split(separator: "?").dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let k = kv.first.map(String.init)?.removingPercentEncoding else { continue }
            let v = kv.dropFirst().first.map(String.init)?.removingPercentEncoding ?? ""
            out[k] = v
        }
        return out
    }
}
