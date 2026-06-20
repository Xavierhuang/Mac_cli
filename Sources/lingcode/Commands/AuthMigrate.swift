// CryptoKit is Apple-only. The encrypted import/export round-trip relies on
// AES-GCM + SHA-256 from CryptoKit; on Linux we'd need swift-crypto as a new
// dep. Until that port lands, the whole file is gated and the AuthExport /
// AuthImport subcommands are dropped from `lingcode auth` on non-Apple
// platforms (see Auth.swift).
#if canImport(CryptoKit)
import ArgumentParser
import CryptoKit
import Foundation
import LingCodeAgentCore

/// `lingcode auth export` / `lingcode auth import` — round-trip every API key
/// + multi-account selection through an AES-GCM-encrypted file so users can
/// move credentials between machines without retyping. Password-derived key
/// (SHA-256 + 16-byte salt) is the threat-model match: this is a backup the
/// user themselves controls, not something we're protecting from a server-side
/// attacker.

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct AuthExport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Encrypt every stored API key + account selection to a portable file."
    )

    @Argument(help: "Output file path (e.g. ./lingcode-keys.json).")
    var path: String

    @Option(name: .long, help: "Password for the export. If omitted, prompted on TTY.")
    var password: String?

    func run() throws {
        let pw = try resolvePassword(provided: password, prompt: "Set export password (you'll need it to import):")
        let cfg = ConfigStore.load()
        var keys: [[String: String]] = []
        for p in authKnownProviders {
            let names = (cfg.accounts?[p.name] ?? []) + [""] // include default slot too
            for accountName in names {
                let kAccount = keychainAccount(base: p.account, account: accountName.isEmpty ? nil : accountName)
                guard let value = try? SecretStore.get(service: keychainService, account: kAccount), !value.isEmpty else { continue }
                keys.append([
                    "provider": p.name,
                    "account":  accountName,
                    "value":    value
                ])
            }
        }
        let payload: [String: Any] = [
            "schema": 1,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "keys": keys,
            "accounts": cfg.accounts ?? [:],
            "activeAccount": cfg.activeAccount ?? [:]
        ]
        let plaintext = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let encrypted = try encryptWithPassword(plaintext: plaintext, password: pw)
        try encrypted.write(to: URL(fileURLWithPath: path), options: .atomic)
        Swift.print("✓ exported \(keys.count) key(s) → \(path)")
        Swift.print("  Move this file to the other machine and run `lingcode auth import \(path)`.")
    }
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct AuthImport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Restore API keys + account selection from a `lingcode auth export` file."
    )

    @Argument(help: "Path to the encrypted export file.")
    var path: String

    @Option(name: .long, help: "Decryption password. If omitted, prompted on TTY.")
    var password: String?

    @Flag(name: .long, help: "Overwrite existing keychain entries. Default: skip slots that already have a value.")
    var force: Bool = false

    func run() throws {
        let pw = try resolvePassword(provided: password, prompt: "Decryption password:")
        let blob = try Data(contentsOf: URL(fileURLWithPath: path))
        let plaintext = try decryptWithPassword(envelope: blob, password: pw)
        guard let payload = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw ImportError.malformed
        }
        guard let keys = payload["keys"] as? [[String: String]] else {
            throw ImportError.malformed
        }
        var written = 0, skipped = 0
        for entry in keys {
            guard let provider = entry["provider"], let value = entry["value"] else { continue }
            let accountName = entry["account"] ?? ""
            guard let p = authProviderByName(provider) else { continue }
            let kAccount = keychainAccount(base: p.account, account: accountName.isEmpty ? nil : accountName)
            if !force, let existing = try? SecretStore.get(service: keychainService, account: kAccount), !existing.isEmpty {
                skipped += 1
                continue
            }
            try? SecretStore.set(service: keychainService, account: kAccount, secret: value)
            written += 1
        }
        // Restore accounts + active selection. We merge rather than replace so an
        // import doesn't wipe local-only accounts that aren't in the backup.
        if let importedAccounts = payload["accounts"] as? [String: [String]],
           let importedActive = payload["activeAccount"] as? [String: String] {
            var cfg = ConfigStore.load()
            var merged = cfg.accounts ?? [:]
            for (provider, names) in importedAccounts {
                var existing = Set(merged[provider] ?? [])
                names.forEach { existing.insert($0) }
                merged[provider] = Array(existing).sorted()
            }
            cfg.accounts = merged
            var active = cfg.activeAccount ?? [:]
            if force {
                for (k, v) in importedActive { active[k] = v }
            } else {
                for (k, v) in importedActive where active[k] == nil { active[k] = v }
            }
            cfg.activeAccount = active
            try ConfigStore.save(cfg)
        }
        Swift.print("✓ imported \(written) key(s)\(skipped > 0 ? " (\(skipped) skipped — pass --force to overwrite)" : "")")
    }

    enum ImportError: Error, CustomStringConvertible {
        case malformed
        var description: String { "import file is not a valid lingcode export (or wrong password)" }
    }
}

// MARK: - Crypto

private struct EncryptedEnvelope: Codable {
    let schema: Int
    let salt: String   // base64
    let sealed: String // base64 (combined nonce+ciphertext+tag from AES.GCM)
}

private func encryptWithPassword(plaintext: Data, password: String) throws -> Data {
    var salt = Data(count: 16)
    _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
    let key = deriveKey(password: password, salt: salt)
    let sealed = try AES.GCM.seal(plaintext, using: key)
    guard let combined = sealed.combined else {
        throw NSError(domain: "AuthMigrate", code: 1, userInfo: [NSLocalizedDescriptionKey: "encryption failed to produce combined output"])
    }
    let env = EncryptedEnvelope(
        schema: 1,
        salt: salt.base64EncodedString(),
        sealed: combined.base64EncodedString()
    )
    return try JSONEncoder().encode(env)
}

private func decryptWithPassword(envelope: Data, password: String) throws -> Data {
    let env = try JSONDecoder().decode(EncryptedEnvelope.self, from: envelope)
    guard let salt = Data(base64Encoded: env.salt),
          let sealedBytes = Data(base64Encoded: env.sealed) else {
        throw AuthImport.ImportError.malformed
    }
    let key = deriveKey(password: password, salt: salt)
    let box = try AES.GCM.SealedBox(combined: sealedBytes)
    return try AES.GCM.open(box, using: key)
}

/// Password-derived 256-bit AES key. Salted SHA-256 — not PBKDF2/Argon2 because
/// this isn't protecting against an offline brute-force attacker, just keeping
/// the file unreadable in transit. If the user picks a weak password, that's
/// their backup, their risk.
private func deriveKey(password: String, salt: Data) -> SymmetricKey {
    var input = salt
    input.append(Data(password.utf8))
    let digest = SHA256.hash(data: input)
    return SymmetricKey(data: Data(digest))
}

// MARK: - Password prompt

private func resolvePassword(provided: String?, prompt: String) throws -> String {
    if let p = provided, !p.isEmpty { return p }
    guard let tty = TTYIO.open() else {
        FileHandle.standardError.write(Data("lingcode: --password required when stdin isn't a TTY.\n".utf8))
        throw ExitCode(2)
    }
    defer { tty.close() }
    tty.write(prompt + " ")
    let raw = tty.readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !raw.isEmpty else {
        throw ExitCode(2)
    }
    return raw
}

// Bridge into Auth.swift's private types via small accessors.
private struct AuthProviderShim {
    let name: String
    let account: String
}

private var authKnownProviders: [AuthProviderShim] {
    // Mirrors Auth.swift's knownProviders. Kept in sync manually — when a new
    // provider is added there, add it here too. (Could be DRY'd by exposing the
    // list publicly, but Auth.swift's private scope is intentional.)
    return [
        .init(name: "anthropic",  account: "anthropic-api-key"),
        .init(name: "openai",     account: "openai-api-key"),
        .init(name: "deepseek",   account: "deepseek-api-key"),
        .init(name: "gemini",     account: "gemini-api-key"),
        .init(name: "groq",       account: "groq-api-key"),
        .init(name: "together",   account: "together-api-key"),
        .init(name: "openrouter", account: "openrouter-api-key"),
        .init(name: "mistral",    account: "mistral-api-key"),
        .init(name: "xai",        account: "xai-api-key"),
        .init(name: "fireworks",  account: "fireworks-api-key"),
        .init(name: "kimi",       account: "kimi-api-key"),
        .init(name: "qwen",       account: "qwen-api-key")
    ]
}

private func authProviderByName(_ name: String) -> AuthProviderShim? {
    authKnownProviders.first { $0.name == name.lowercased() }
}
#endif
