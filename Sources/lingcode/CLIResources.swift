import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// SwiftPM's auto-generated `Bundle.module` accessor calls `fatalError` when the
// resource bundle is missing next to the running executable. The CLI installer
// symlinks the binary into ~/.local/bin while the bundle stays in
// ~/.lingcode/cli, so going through `Bundle.module` crashes on first launch.
// CLIResources resolves the bundle by following the executable's real path
// instead, never touching `Bundle.module`.
enum CLIResources {
    enum LookupError: Swift.Error, CustomStringConvertible {
        case bundleMissing(searched: [String])

        var description: String {
            switch self {
            case .bundleMissing(let paths):
                let joined = paths.map { "  - \($0)" }.joined(separator: "\n")
                return "lingcode resources not found. Searched:\n\(joined)"
            }
        }
    }

    /// The directory that actually CONTAINS the resources — not merely the bundle
    /// directory.
    ///
    /// SwiftPM emits the resource bundle in two shapes depending on how it was built:
    /// flat, with `agent-bridge/` at the bundle root, or as a structured macOS bundle
    /// with everything under `Contents/Resources/`. Every caller appends a path like
    /// `agent-bridge/node` to whatever this returns, so returning the bundle root for
    /// a structured bundle makes all of them miss.
    ///
    /// The symptom is quiet rather than fatal, which is why it survived: each caller
    /// falls back to something that usually exists on a developer's machine. `lingcode
    /// doctor` on a structured install reported a Homebrew node and LingCode.app's
    /// bridge, both green — while the CLI's own bundled copies sat unused two
    /// directories away. On a machine with neither, the standalone tarball simply
    /// does not work, which is the one thing it exists to guarantee.
    static func bundleURL() throws -> URL {
        var searched: [String] = []
        let fm = FileManager.default
        for dir in candidateExecDirs() {
            for name in ["LingCodeCLI_lingcode.bundle", "LingCodeCLI_lingcode.resources"] {
                let path = (dir as NSString).appendingPathComponent(name)
                searched.append(path)
                guard fm.fileExists(atPath: path) else { continue }
                let root = URL(fileURLWithPath: path)
                // Structured bundle: descend to where the payload really lives.
                let contents = root.appendingPathComponent("Contents/Resources")
                if fm.fileExists(atPath: contents.appendingPathComponent("agent-bridge").path) {
                    return contents
                }
                return root
            }
        }
        throw LookupError.bundleMissing(searched: searched)
    }

    /// Returns the path of the universal `node` binary shipped inside the CLI's
    /// resource bundle, or `nil` when it isn't present (Linux tarball, dev
    /// builds without fetch-node, or a corrupted install).
    static func bundledNodePath() -> String? {
        guard let bundle = try? bundleURL() else { return nil }
        let path = bundle.appendingPathComponent("agent-bridge/node").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private static func candidateExecDirs() -> [String] {
        guard let exe = executablePath() else { return [] }
        let real = (exe as NSString).resolvingSymlinksInPath
        var dirs = [(real as NSString).deletingLastPathComponent]
        if real != exe {
            dirs.append((exe as NSString).deletingLastPathComponent)
        }
        return dirs
    }

    private static func executablePath() -> String? {
        #if canImport(Darwin)
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }
        return String(cString: buf)
        #elseif os(Linux)
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = readlink("/proc/self/exe", &buf, buf.count - 1)
        guard n > 0 else { return nil }
        buf[Int(n)] = 0
        return String(cString: buf)
        #else
        return nil
        #endif
    }
}
