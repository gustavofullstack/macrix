import XCTest
@testable import macrix

final class JevTests: XCTestCase {
    func testDisabledByDefault() {
        // CI/sandbox has no MACRIX_JEV: route must refuse with guidance.
        if ProcessInfo.processInfo.environment["MACRIX_JEV"] == "1" { return }
        let r = ToolRegistry()
        registerAllTools(into: r)
        XCTAssertTrue(Jev.route("x", tools: r.list()).contains("MACRIX_JEV=1"))
    }
    func testRegistryHasJevTools() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        let names = Set(r.list().map { $0.name })
        XCTAssertTrue(names.contains("jev_route"))
        XCTAssertTrue(names.contains("jev_ping"))
        XCTAssertGreaterThanOrEqual(r.list().count, 42)
    }
    func testChunked() {
        XCTAssertEqual([1, 2, 3, 4, 5].chunked(2), [[1, 2], [3, 4], [5]])
    }
}

final class JevParseTests: XCTestCase {
    func testParseSample() {
        let sample = """
        Resultados do re-ranqueamento Jev 1.13 para: 'screenshot' (modo: noul)
          #1 [Doc 12] Noul=0.38 -> screen_capture: ...
          #2 [Doc 20] Noul=0.19 -> cu_shot: ...
        """
        let got = Jev.parseRerank(sample)
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got[0].0, "screen_capture")
        XCTAssertEqual(got[0].1, 0.38, accuracy: 1e-9)
    }
}
