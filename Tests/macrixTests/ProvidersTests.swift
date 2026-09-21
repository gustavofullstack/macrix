import XCTest
@testable import macrix

final class ProvidersTests: XCTestCase {
    func testScanFixture() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrix-prov-\(Int(Date().timeIntervalSince1970))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "a\nb\nc\n".write(to: dir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        try "x\ny\n".write(to: dir.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)
        let def = ProviderDef(name: "t", root: dir.path, fileExt: "jsonl")
        let s = Providers.scan(def)
        XCTAssertEqual(s.sessions, 2)
        XCTAssertEqual(s.events, 5)
        XCTAssertGreaterThan(s.bytes, 0)
        XCTAssertNotNil(s.lastActive)
    }
    func testMissingRoot() {
        let s = Providers.scan(ProviderDef(name: "nope", root: "/nonexistent-xyz", fileExt: "jsonl"))
        XCTAssertEqual(s.sessions, 0)
        XCTAssertEqual(s.events, 0)
    }
    func testReportShape() {
        let r = Providers.report()
        XCTAssertTrue(r.contains("codex:"))
        XCTAssertTrue(r.contains("muse:"))
    }
}
