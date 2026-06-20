import ArgumentParser
import Foundation
import LingCodeAgentCore

enum HeadlessCodexExit: Error {
    case codexNotFound
    case nonZeroExit(Int32, String)
}

/// Headless one-shot codex invocation. Shells out to the codex binary's native
/// `exec` subcommand. AGENTS.md context + skills are gathered locally and
/// prepended; custom slash commands are resolved before codex sees the prompt.
///
/// Autonomous-mode features (parity with `runHeadlessClaude`):
///   - Retry with exponential backoff on rate-limit / transient network errors
///   - Session resume via `codex exec resume <id>` or `--last`
///   - `-i/--image <FILE>` passthrough for attachments
///   - `--output-schema <FILE>` for structured JSON output
///
/// Approval policy maps:
///   - `yolo=true`              → `--dangerously-bypass-approvals-and-sandbox`
///   - `permissionMode=readOnly`→ `--sandbox read-only`
///   - `permissionMode=autoEdit`→ `--sandbox workspace-write`
///   - default                  → `--full-auto`
@available(macOS 12.0, *)
func runHeadlessCodex(
    prompt: String,
    project: String?,
    yolo: Bool,
    permissionMode: String?,
    modelOverride: String?,
    includeAgentsMd: Bool,
    includeSkills: Bool,
    outputFile: String?,
    verbose: Bool,
    imagePaths: [String] = [],
    outputSchema: String? = nil,
    resumeSessionId: String? = nil,
    continueLast: Bool = false,
    maxRetries: Int = 3
) async throws {
    let cwd: URL = {
        if let project, !project.isEmpty {
            return URL(fileURLWithPath: (project as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }()

    guard let codexPath = locateCodexBinary() else {
        FileHandle.standardError.write(Data(
            "error: codex CLI not found. Install it with `npm install -g @openai/codex`.\n".utf8))
        throw HeadlessCodexExit.codexNotFound
    }

    // Resolve slash command if present.
    var effectivePrompt = prompt
    let trimmed = prompt.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("/") {
        let token = String(trimmed.dropFirst()).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        if let resolved = CodexCustomSlashCommands.resolve(token, cwd: cwd) {
            effectivePrompt = resolved
        }
    }

    // Composite prompt: AGENTS.md + skills + user prompt.
    var composite = ""
    if includeAgentsMd, let agents = CodexMemoryLoader.load(startingAt: cwd) {
        composite += "[Project context from AGENTS.md files:]\n\n\(agents)\n\n"
    }
    if includeSkills {
        let skills = CodexSkillsContext.loadSkills(cwd: cwd)
        if let preamble = CodexSkillsContext.formatPreamble(skills) {
            composite += "\(preamble)\n\n"
        }
    }
    composite += effectivePrompt

    // Build base args. `codex exec` is non-interactive: it has `--sandbox`,
    // `--full-auto`, and `--dangerously-bypass-approvals-and-sandbox` but no
    // `--ask-for-approval` (approvals can't run without a TTY). Verified
    // against codex-cli 0.121.
    var args: [String] = ["exec"]
    if let id = resumeSessionId, !id.isEmpty {
        args.append(contentsOf: ["resume", id])
    } else if continueLast {
        args.append(contentsOf: ["resume", "--last"])
    }
    args.append(contentsOf: ["--cd", cwd.path])
    switch (yolo, permissionMode ?? "") {
    case (true, _):
        args.append("--dangerously-bypass-approvals-and-sandbox")
    case (_, "readOnly"):
        args.append(contentsOf: ["--sandbox", "read-only"])
    case (_, "autoEdit"), (_, "askBeforeEdit"):
        args.append(contentsOf: ["--sandbox", "workspace-write"])
    default:
        args.append("--full-auto")
    }
    if let model = modelOverride { args.append(contentsOf: ["--model", model]) }
    for path in imagePaths where !path.isEmpty {
        args.append(contentsOf: ["--image", (path as NSString).expandingTildeInPath])
    }
    if let schema = outputSchema, !schema.isEmpty {
        args.append(contentsOf: ["--output-schema", (schema as NSString).expandingTildeInPath])
    }
    args.append(composite)

    // Retry loop. Codex exec errors with non-zero exit on rate limits / server
    // errors and prints the reason to stderr. We capture stderr, classify, and
    // back off using the same helpers HeadlessClaude does. Output streams live
    // to stdout on every attempt so the user sees progress even on retries.
    var attempt = 1
    while true {
        let outcome = try await spawnCodexOnce(
            codexPath: codexPath,
            args: args,
            cwd: cwd,
            outputFile: outputFile,
            verbose: verbose
        )
        switch outcome {
        case .success:
            return
        case .failure(let code, let errStr):
            let recoverable = isRecoverableError(errStr)
            if recoverable && attempt < maxRetries {
                let wait = min(60.0, pow(2.0, Double(attempt)))
                FileHandle.standardError.write(Data(
                    "lingcode: codex transient error (attempt \(attempt)/\(maxRetries)); retrying in \(Int(wait))s\n".utf8))
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                attempt += 1
                continue
            }
            FileHandle.standardError.write(Data(
                "lingcode: codex exited \(code)\n\(retryHint(for: errStr))\n".utf8))
            throw HeadlessCodexExit.nonZeroExit(code, errStr)
        }
    }
}

private enum CodexOutcome {
    case success
    case failure(Int32, String)
}

@available(macOS 12.0, *)
private func spawnCodexOnce(
    codexPath: String,
    args: [String],
    cwd: URL,
    outputFile: String?,
    verbose: Bool
) async throws -> CodexOutcome {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: codexPath)
    process.arguments = args
    process.currentDirectoryURL = cwd
    process.environment = ProcessInfo.processInfo.environment

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    let outputHandle: FileHandle? = {
        guard let outputFile, !outputFile.isEmpty else { return nil }
        FileManager.default.createFile(atPath: outputFile, contents: nil)
        return FileHandle(forWritingAtPath: outputFile)
    }()

    outPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        FileHandle.standardOutput.write(data)
        outputHandle?.write(data)
    }
    if verbose {
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            FileHandle.standardError.write(data)
        }
    }

    try process.run()
    process.waitUntilExit()
    outPipe.fileHandleForReading.readabilityHandler = nil
    errPipe.fileHandleForReading.readabilityHandler = nil
    try? outputHandle?.close()

    if process.terminationStatus == 0 {
        return .success
    }
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    let errStr = String(data: errData, encoding: .utf8) ?? ""
    return .failure(process.terminationStatus, errStr)
}

/// Replaces the current process with an interactive `codex` invocation so the
/// user lands directly in codex's own REPL. We pass `--cd` for the workspace
/// and translate LingCode's permissionMode strings into codex's flag set.
@available(macOS 12.0, *)
func execCodexRepl(cwd: URL, model: String?, permissionMode: String?, yolo: Bool) throws {
    guard let codexPath = locateCodexBinary() else {
        FileHandle.standardError.write(Data(
            "error: codex CLI not found. Install it with `npm install -g @openai/codex`.\n".utf8))
        throw ExitCode(1)
    }
    let approvalPolicy: String
    let sandbox: String
    switch (yolo, permissionMode ?? "") {
    case (true, _):
        approvalPolicy = "never"; sandbox = "danger-full-access"
    case (_, "readOnly"):
        approvalPolicy = "never"; sandbox = "read-only"
    case (_, "autoEdit"):
        approvalPolicy = "never"; sandbox = "workspace-write"
    default:
        approvalPolicy = "untrusted"; sandbox = "workspace-write"
    }
    var args: [String] = [codexPath,
                          "--ask-for-approval", approvalPolicy,
                          "--sandbox", sandbox,
                          "--cd", cwd.path]
    if let model { args.append(contentsOf: ["--model", model]) }

    let argv = args.map { strdup($0) } + [UnsafeMutablePointer<CChar>?(nil)]
    _ = execv(codexPath, argv)
    FileHandle.standardError.write(Data("error: failed to exec codex at \(codexPath)\n".utf8))
    throw ExitCode(1)
}

func locateCodexBinary() -> String? {
    let candidates = [
        "\(NSHomeDirectory())/.local/bin/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "/usr/bin/codex",
        "\(NSHomeDirectory())/.npm-global/bin/codex",
    ]
    let fm = FileManager.default
    for path in candidates where fm.isExecutableFile(atPath: path) {
        return path
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["which", "codex"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? nil : path
        }
    } catch { return nil }
    return nil
}
