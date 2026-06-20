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

    static func bundleURL() throws -> URL {
        var searched: [String] = []
        for dir in candidateExecDirs() {
            for name in ["LingCodeCLI_lingcode.bundle", "LingCodeCLI_lingcode.resources"] {
                let path = (dir as NSString).appendingPathComponent(name)
                searched.append(path)
                if FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
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
