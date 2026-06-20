// Mac-only: talks to LingCode.app's Unix-domain bridge daemon via Darwin
// socket APIs. On Linux there's no app to talk to and Darwin.connect doesn't
// exist, so the whole file compiles to nothing. The subcommand registration
// in LingCodeEntry.swift is also gated on macOS.
#if os(macOS)
import ArgumentParser
import Foundation
import LingCodeAgentCore

/// `lingcode bridge` — diagnostic surface for the Node bridge subprocess. We
/// don't yet ship a long-running daemon (that needs `bridge.mjs` reworked for
/// multi-session-per-process — substantial). What we ship today is visibility:
/// `status` lists any bridge.mjs node processes currently running on this Mac,
/// `kill` terminates them. Useful when a previous run crashed mid-stream and
/// left a zombie holding port/cpu, or when bridge errors look like duplicate
/// instances stepping on each other.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct BridgeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bridge",
        abstract: "Inspect or clean up Node agent-bridge subprocesses.",
        discussion: """
        Examples:
          lingcode bridge status           # list running bridge.mjs processes
          lingcode bridge kill             # SIGTERM all of them
          lingcode bridge kill --force     # SIGKILL (last resort)

        Note: a long-running bridge daemon — where `lingcode ask` connects to a
        warm process instead of cold-spawning Node every time — is on the roadmap
        but not yet shipped. This subcommand is for diagnosing the current
        per-invocation model, not driving it.
        """,
        subcommands: [BridgeStatus.self, BridgeKill.self, BridgeDaemonStart.self, BridgeDaemonStop.self, BridgeDaemonStatus.self, BridgeDaemonPing.self]
    )

    // MARK: - Daemon control

    /// Where the daemon's pid file + socket live.
    static let daemonDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".lingcode/bridge")
    static var daemonPidFile: URL { daemonDir.appendingPathComponent("daemon.pid") }
    static var daemonSocket: URL { daemonDir.appendingPathComponent("daemon.sock") }

    struct BridgeDaemonStart: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "daemon-start",
            abstract: "Spawn a long-lived bridge that keeps Node + the Agent SDK warm between invocations."
        )

        @Option(name: .long, help: "Idle seconds before the daemon exits on its own.")
        var idleTimeout: Int = 600

        func run() throws {
            try? FileManager.default.createDirectory(at: BridgeCommand.daemonDir, withIntermediateDirectories: true)

            // Refuse to start a second daemon — the socket is single-tenant.
            if let existing = readDaemonPid(), processIsAlive(existing) {
                Swift.print("Daemon already running (pid \(existing)). `lingcode bridge daemon-stop` first if you want to restart.")
                return
            }

            // Locate node + bridge.mjs the same way HeadlessClaude does.
            let extraNodePaths = [CLIResources.bundledNodePath()].compactMap { $0 }
            guard let node = NodeResolver.resolve(extraSearchPaths: extraNodePaths) else {
                FileHandle.standardError.write(Data("lingcode: bundled node is missing and no system node was found — run `lingcode doctor` for details.\n".utf8))
                throw ExitCode(1)
            }
            let bundledRoot = Bundle.module.bundleURL.appendingPathComponent("agent-bridge").path
            guard let res = try? BridgeResourceLocator(extraSearchRoots: [bundledRoot]).locate() else {
                FileHandle.standardError.write(Data("lingcode: agent bridge resources missing — reinstall lingcode.\n".utf8))
                throw ExitCode(1)
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: node)
            proc.arguments = [
                res.bridgeScriptPath,
                "--daemon-socket", BridgeCommand.daemonSocket.path,
                "--idle-timeout", String(idleTimeout)
            ]
            // The daemon outlives this command, so it can't ask the keychain
            // per-query later. Resolve the API key now (env → keychain → config)
            // and inject into the daemon's env so the SDK can authenticate.
            var env = ProcessInfo.processInfo.environment
            if env["ANTHROPIC_API_KEY"]?.isEmpty != false {
                let active = ConfigStore.load().activeAccountName(for: "anthropic")
                let kAccount = keychainAccount(base: "anthropic-api-key", account: active)
                if let kc = try? SecretStore.get(service: keychainService, account: kAccount), !kc.isEmpty {
                    env["ANTHROPIC_API_KEY"] = kc
                } else if let cfg = ConfigStore.load().anthropicAPIKey, !cfg.isEmpty {
                    env["ANTHROPIC_API_KEY"] = cfg
                }
            }
            proc.environment = env
            // Detach: redirect IO so the child doesn't keep our terminal alive.
            proc.standardInput = FileHandle.nullDevice
            let logFile = BridgeCommand.daemonDir.appendingPathComponent("daemon.log")
            try? "".write(to: logFile, atomically: true, encoding: .utf8)
            if let fh = try? FileHandle(forWritingTo: logFile) {
                proc.standardOutput = fh
                proc.standardError = fh
            }
            try proc.run()
            // Hand the parent role over — process detaches when we exit.
            try writeDaemonPid(Int(proc.processIdentifier))

            // Briefly poll for the socket to appear so we can confirm readiness.
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: BridgeCommand.daemonSocket.path) {
                    Swift.print("✓ daemon started (pid \(proc.processIdentifier), socket \(BridgeCommand.daemonSocket.path), idle-timeout \(idleTimeout)s)")
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            FileHandle.standardError.write(Data("lingcode: daemon spawned but socket didn't appear within 5s — check \(logFile.path)\n".utf8))
            throw ExitCode(1)
        }
    }

    struct BridgeDaemonStop: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "daemon-stop",
            abstract: "Stop the running bridge daemon (SIGTERM, then SIGKILL after 3s)."
        )

        func run() throws {
            guard let pid = readDaemonPid() else {
                Swift.print("No daemon pid file. Nothing to stop.")
                return
            }
            if !processIsAlive(pid) {
                Swift.print("Daemon pid \(pid) is not running. Cleaning up pidfile.")
                try? FileManager.default.removeItem(at: BridgeCommand.daemonPidFile)
                try? FileManager.default.removeItem(at: BridgeCommand.daemonSocket)
                return
            }
            _ = Foundation.kill(pid_t(pid), SIGTERM)
            // Wait briefly for graceful exit, then SIGKILL.
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if !processIsAlive(pid) { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if processIsAlive(pid) {
                _ = Foundation.kill(pid_t(pid), SIGKILL)
            }
            try? FileManager.default.removeItem(at: BridgeCommand.daemonPidFile)
            try? FileManager.default.removeItem(at: BridgeCommand.daemonSocket)
            Swift.print("✓ daemon stopped (pid \(pid))")
        }
    }

    struct BridgeDaemonStatus: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "daemon-status",
            abstract: "Show whether the bridge daemon is running, its pid, and socket path."
        )

        func run() throws {
            guard let pid = readDaemonPid() else {
                Swift.print("daemon: not running (no pid file)")
                return
            }
            if !processIsAlive(pid) {
                Swift.print("daemon: stale pid file (\(pid) not alive). Run `daemon-stop` to clean up.")
                return
            }
            let sock = BridgeCommand.daemonSocket.path
            let sockExists = FileManager.default.fileExists(atPath: sock)
            Swift.print("daemon: running")
            Swift.print("  pid:    \(pid)")
            Swift.print("  socket: \(sock)\(sockExists ? "" : "  (missing! daemon may be unhealthy)")")
        }
    }

    struct BridgeDaemonPing: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "daemon-ping",
            abstract: "Send a `ping` to the daemon and report the response — confirms IPC works end-to-end."
        )

        func run() throws {
            guard let pid = readDaemonPid(), processIsAlive(pid) else {
                FileHandle.standardError.write(Data("lingcode: daemon is not running. Start it with `lingcode bridge daemon-start`.\n".utf8))
                throw ExitCode(1)
            }
            let sockPath = BridgeCommand.daemonSocket.path
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                FileHandle.standardError.write(Data("lingcode: socket() failed.\n".utf8))
                throw ExitCode(1)
            }
            defer { close(fd) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
                    _ = sockPath.withCString { src in strncpy(cptr, src, 103) }
                }
            }
            let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connectResult == 0 else {
                FileHandle.standardError.write(Data("lingcode: connect to \(sockPath) failed: \(String(cString: strerror(errno)))\n".utf8))
                throw ExitCode(1)
            }
            let line = "{\"type\":\"ping\"}\n"
            _ = line.withCString { ptr in send(fd, ptr, strlen(ptr), 0) }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = recv(fd, &buf, 4096, 0)
            if n <= 0 {
                FileHandle.standardError.write(Data("lingcode: no response from daemon.\n".utf8))
                throw ExitCode(1)
            }
            let response = String(bytes: buf.prefix(n), encoding: .utf8) ?? "<binary>"
            Swift.print("✓ pong: \(response.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

// MARK: - Daemon helpers (file-scope so subcommand structs share them)

private func readDaemonPid() -> Int? {
    guard let s = try? String(contentsOf: BridgeCommand.daemonPidFile, encoding: .utf8) else { return nil }
    return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func writeDaemonPid(_ pid: Int) throws {
    try "\(pid)\n".write(to: BridgeCommand.daemonPidFile, atomically: true, encoding: .utf8)
}

/// `kill(pid, 0)` returns 0 when the pid exists and we have permission to signal
/// it. ESRCH (no such process) means the daemon died. Cheap liveness check.
private func processIsAlive(_ pid: Int) -> Bool {
    return Foundation.kill(pid_t(pid), 0) == 0
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct BridgeStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "List currently running agent-bridge processes."
    )

    func run() throws {
        let procs = findBridgeProcesses()
        if procs.isEmpty {
            Swift.print("No agent-bridge processes running.")
            return
        }
        Swift.print("PID    AGE    COMMAND")
        for p in procs {
            Swift.print("\(p.pid.padding(toLength: 6, withPad: " ", startingAt: 0)) \(p.age.padding(toLength: 6, withPad: " ", startingAt: 0)) \(p.command)")
        }
    }
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct BridgeKill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kill",
        abstract: "Terminate any running agent-bridge processes."
    )

    @Flag(name: .long, help: "Use SIGKILL instead of SIGTERM. Use only if SIGTERM didn't work.")
    var force: Bool = false

    func run() throws {
        let procs = findBridgeProcesses()
        if procs.isEmpty {
            Swift.print("No agent-bridge processes to kill.")
            return
        }
        let signal = force ? SIGKILL : SIGTERM
        var killed = 0
        for p in procs {
            guard let pidNum = pid_t(p.pid) else { continue }
            if Foundation.kill(pidNum, signal) == 0 {
                Swift.print("✓ killed pid \(p.pid)")
                killed += 1
            } else {
                FileHandle.standardError.write(Data("✗ failed to signal pid \(p.pid): \(String(cString: strerror(errno)))\n".utf8))
            }
        }
        if killed == 0 {
            throw ExitCode(1)
        }
    }
}

private struct BridgeProcess {
    let pid: String
    let age: String
    let command: String
}

/// Shells out to `ps` and grep-filters for `bridge.mjs` invocations launched
/// by either lingcode (CLI) or LingCode.app. Avoids matching this very `lingcode
/// bridge status` invocation. Best-effort — `ps` output format varies between
/// macOS versions, so we parse loosely.
private func findBridgeProcesses() -> [BridgeProcess] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-eo", "pid,etime,command"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch { return [] }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    let myPid = String(ProcessInfo.processInfo.processIdentifier)
    var out: [BridgeProcess] = []
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.contains("bridge.mjs") else { continue }
        guard !line.contains("lingcode bridge ") else { continue } // skip self
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3 else { continue }
        if parts[0] == myPid { continue }
        out.append(BridgeProcess(pid: parts[0], age: parts[1], command: String(parts[2].prefix(80))))
    }
    return out
}
#endif
