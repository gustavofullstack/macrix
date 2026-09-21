import XCTest
@testable import macrix

final class CatalogTests: XCTestCase {
    func testInstalledCatalogLoads() {
        // Runs against the real installed copy; asserts schema, not size.
        guard let doc = Catalog.load() else { return XCTFail("catalog missing") }
        XCTAssertEqual(doc.version, 1)
        XCTAssertGreaterThan(doc.entries.count, 100)
        XCTAssertEqual(doc.target, 1000)
    }
    func testStatsShape() {
        XCTAssertTrue(Catalog.stats().contains("/1000"))
    }
    func testSearchHitAndMiss() {
        XCTAssertTrue(Catalog.search("macrix", limit: 5).contains("macrix-tool"))
        XCTAssertTrue(Catalog.search("zzz-no-such-capability", limit: 5).contains("no catalog entries"))
    }
    func testSearchSubstringFallback() {
        // Jev off: same hits, no scores, nothing dropped.
        unsetenv("MACRIX_JEV")
        let out = Catalog.search("macrix", limit: 5)
        XCTAssertFalse(out.contains("noul"))
        XCTAssertEqual(out.split(separator: "\n").count, 5)
    }
}
