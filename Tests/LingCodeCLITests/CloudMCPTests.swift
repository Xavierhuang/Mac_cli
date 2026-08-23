#if canImport(CryptoKit)
import XCTest
import LingCodeAgentCore
@testable import lingcode

/// The CLI's project key MUST equal the Mac app's for the same folder.
///
/// `LingCodeCloudMCPSetup.projectKey(for:)` (app) and `CloudMCP.projectKey(for:)`
/// (CLI) are separate implementations of one hash. If they drift, the same folder
/// resolves to a DIFFERENT backend depending on whether the user opened it in the
/// app or ran `lingcode` in it — which surfaces as an empty database, i.e. looks
/// exactly like data loss.
///
/// The expected values below were computed INDEPENDENTLY of both implementations:
///
///   printf '%s' "/Users/example/Projects/demo" | shasum -a 256 | cut -c1-20
///
/// so this pins the contract rather than restating whatever the code happens to do.
/// LingCodeTests/CloudMCPProjectKeyTests.swift pins the app side to the same literal.
final class CloudMCPTests: XCTestCase {

    func testProjectKeyMatchesTheIndependentlyComputedHash() {
        let url = URL(fileURLWithPath: "/Users/example/Projects/demo")
        XCTAssertEqual(CloudMCP.projectKey(for: url), "proj_464cd4a6c1eaaeca0478")
    }

    func testProjectKeyShape() {
        let key = CloudMCP.projectKey(for: URL(fileURLWithPath: "/Users/example/another"))
        XCTAssertTrue(key.hasPrefix("proj_"))
        // 5 for "proj_" + 20 hex chars. The app truncates to exactly 20; a longer or
        // shorter slice is a different namespace.
        XCTAssertEqual(key.count, 25)
        XCTAssertTrue(key.dropFirst(5).allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testProjectKeyIsStableAcrossCalls() {
        let url = URL(fileURLWithPath: "/Users/example/Projects/demo")
        XCTAssertEqual(CloudMCP.projectKey(for: url), CloudMCP.projectKey(for: url))
    }

    func testDifferentFoldersGetDifferentKeys() {
        let a = CloudMCP.projectKey(for: URL(fileURLWithPath: "/Users/example/a"))
        let b = CloudMCP.projectKey(for: URL(fileURLWithPath: "/Users/example/b"))
        XCTAssertNotEqual(a, b)
    }

    // MARK: - project.json

    func testProjectIdReadsTheManifest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudmcp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".lingcode"), withIntermediateDirectories: true)
        try #"{"projectId":"abc-123","apiBase":"https://lingcode.dev"}"#
            .write(to: dir.appendingPathComponent(".lingcode/project.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(CloudMCP.projectId(for: dir), "abc-123")
    }

    func testProjectIdIsNilWithoutAManifest() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudmcp-missing-\(UUID().uuidString)")
        XCTAssertNil(CloudMCP.projectId(for: dir))
    }

    // MARK: - Signed-out behaviour
    //
    // A CLI run must never fail because there is no cloud session; the server map
    // is simply empty. (This asserts the shape, not the Keychain read — reading the
    // real account item from a test binary would prompt.)

    func testMergeKeepsOnDiskServersAndNeverThrows() {
        let onDisk = ["filesystem": MCPServerConfig(type: "stdio", command: "node", args: ["fs.js"])]
        let merged = mergingCloudMCP(onDisk, cwd: URL(fileURLWithPath: "/Users/example/nowhere"))
        XCTAssertEqual(merged["filesystem"]?.command, "node",
                       "an on-disk server must survive the merge untouched")
    }
}
#endif
