import XCTest
@testable import LingCodeIPC

final class IPCProtocolTests: XCTestCase {
    func testRequestRoundtrip() throws {
        let req = IPCRequest(method: IPCMethod.open.rawValue, params: IPCParams(path: "/tmp/foo", line: 42))
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        XCTAssertEqual(decoded.method, "open")
        XCTAssertEqual(decoded.params?.path, "/tmp/foo")
        XCTAssertEqual(decoded.params?.line, 42)
    }

    func testResponseStreamingFlag() throws {
        let res = IPCResponse(id: "abc", ok: true, result: IPCResult(chunk: "hello"), streaming: true)
        let data = try JSONEncoder().encode(res)
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: data)
        XCTAssertTrue(decoded.streaming == true)
        XCTAssertEqual(decoded.result?.chunk, "hello")
    }

    func testSocketPathUnderAppSupport() {
        XCTAssertTrue(IPCSocket.defaultPath.hasSuffix("LingCode/ipc.sock"))
    }
}
