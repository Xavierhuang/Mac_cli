import Foundation
#if canImport(Security)
import Security
#endif

/// Cross-platform secret store for API keys.
///
///   - On macOS: backed by the native Keychain (Security framework).
///   - On Linux: backed by a chmod-600 JSON file at
///     `$XDG_CONFIG_HOME/lingcode/keys.json` (defaulting to
///     `~/.config/lingcode/keys.json`).
///
/// Same `set / get / delete` signatures regardless of platform so call sites
/// don't need to branch.
public enum SecretStore {
    public static func set(service: String, account: String, secret: String) throws {
        try Backend.set(service: service, account: account, secret: secret)
    }

    public static func get(service: String, account: String) throws -> String {
        try Backend.get(service: service, account: account)
    }

    public static func delete(service: String, account: String) throws {
        try Backend.delete(service: service, account: account)
    }
}

public enum SecretStoreError: Error, CustomStringConvertible {
    case writeFailed(String)
    case notFound
    case readFailed(String)

    public var description: String {
        switch self {
        case .writeFailed(let s): return "secret store write failed: \(s)"
        case .notFound:           return "key not found in secret store"
        case .readFailed(let s):  return "secret store read failed: \(s)"
        }
    }
}

// The service identifier `com.lingcode.api-keys` is reused unchanged on Linux
// as the top-level key inside keys.json so existing call sites that pass
// `keychainService` work without rename.
let keychainService = "com.lingcode.api-keys"

// MARK: - Backend (platform-specific)

#if canImport(Security)

private enum Backend {
    static func set(service: String, account: String, secret: String) throws {
        let data = Data(secret.utf8)
        // Delete first so an existing entry doesn't collide.
        _ = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)

        let status = SecItemAdd([
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData:   data,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretStoreError.writeFailed("OSStatus \(status)")
        }
    }

    static func get(service: String, account: String) throws -> String {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { throw SecretStoreError.notFound }
        return string
    }

    static func delete(service: String, account: String) throws {
        SecItemDelete([
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
    }
}

#else

// Linux backend — chmod-600 JSON keyed as keys[service][account] = secret.
//
// Format:
// {
//   "com.lingcode.api-keys": {
//     "anthropic": "sk-ant-...",
//     "deepseek-api-key": "sk-..."
//   }
// }
//
// Permissions are restricted to the owner; we re-apply mode 0600 on every
// write so a careless user `chmod` doesn't quietly leave the file readable.

private enum Backend {
    static func set(service: String, account: String, secret: String) throws {
        var blob = try loadOrEmpty()
        var bucket = blob[service] ?? [:]
        bucket[account] = secret
        blob[service] = bucket
        try save(blob)
    }

    static func get(service: String, account: String) throws -> String {
        let blob = try loadOrEmpty()
        guard let value = blob[service]?[account], !value.isEmpty else {
            throw SecretStoreError.notFound
        }
        return value
    }

    static func delete(service: String, account: String) throws {
        var blob = try loadOrEmpty()
        if var bucket = blob[service] {
            bucket.removeValue(forKey: account)
            if bucket.isEmpty {
                blob.removeValue(forKey: service)
            } else {
                blob[service] = bucket
            }
            try save(blob)
        }
    }

    private static func storeURL() -> URL {
        let configHome: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            configHome = URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath)
        } else {
            configHome = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".config", isDirectory: true)
        }
        return configHome
            .appendingPathComponent("lingcode", isDirectory: true)
            .appendingPathComponent("keys.json")
    }

    private static func loadOrEmpty() throws -> [String: [String: String]] {
        let url = storeURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            return (try JSONSerialization.jsonObject(with: data) as? [String: [String: String]]) ?? [:]
        } catch {
            throw SecretStoreError.readFailed(error.localizedDescription)
        }
    }

    private static func save(_ blob: [String: [String: String]]) throws {
        let url = storeURL()
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: blob,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw SecretStoreError.writeFailed(error.localizedDescription)
        }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw SecretStoreError.writeFailed(error.localizedDescription)
        }
    }
}

#endif
