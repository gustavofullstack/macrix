import XCTest
@testable import macrix

final class CodecTests: XCTestCase {
    func testB64RoundTrip() {
        XCTAssertEqual(Codec.b64encode("ola"), "b2xh")
        XCTAssertEqual(Codec.b64decode("b2xh"), "ola")
        XCTAssertTrue(Codec.b64decode("!!!").contains("invalid"))
        XCTAssertTrue(Codec.b64encode("").contains("missing"))
    }
    func testSha256Vector() {
        XCTAssertEqual(Codec.sha256("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testUuid() {
        let u = Codec.uuid()
        XCTAssertEqual(u.count, 36)
        XCTAssertEqual(UUID(uuidString: u) != nil, true)
    }
    func testJsonPretty() {
        let out = Codec.jsonPretty("{\"b\":2,\"a\":1}")
        XCTAssertTrue(out.contains("\n"))
        XCTAssertTrue(out.range(of: "\"a\"")!.lowerBound < out.range(of: "\"b\"")!.lowerBound)
        XCTAssertTrue(Codec.jsonPretty("{nope").contains("invalid"))
    }
    func testQr() {
        let out = Codec.qr("https://triqhub.tech")
        XCTAssertTrue(out.hasPrefix("qr: /tmp/macrix_qr_"), out)
        let path = String(out.dropFirst(4))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        try? FileManager.default.removeItem(atPath: path)
        XCTAssertTrue(Codec.qr("").contains("need"))
    }
    func testRegistryCount() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        XCTAssertGreaterThanOrEqual(r.list().count, 71)
    }
}
