import XCTest
@testable import macrix

final class SpendTests: XCTestCase {
    func testMuseFixture() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrix-spend-\(Int(Date().timeIntervalSince1970))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let line = #"{"payload":{"event":{"kind":"model_completed","usage":{"input_tokens":100,"output_tokens":20,"cached_tokens":10}}}}"#
        try (line + "\n" + line + "\n").write(to: dir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let (tot, per) = Spend.scanMuse(root: dir.path)
        XCTAssertEqual(tot.input, 200)
        XCTAssertEqual(tot.output, 40)
        XCTAssertEqual(tot.cached, 20)
        XCTAssertEqual(per["unknown"], 240)
    }
    func testCodexLimitsFixture() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrix-lim-\(Int(Date().timeIntervalSince1970))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let line = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","credits":{"has_credits":false}}}}"#
        try (line + "\n").write(to: dir.appendingPathComponent("r.jsonl"), atomically: true, encoding: .utf8)
        let out = Spend.scanCodexLimits(root: dir.path)
        XCTAssertEqual(out, ["premium has_credits=false"])
    }
}
