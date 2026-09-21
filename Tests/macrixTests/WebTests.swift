import XCTest
@testable import macrix

final class WebTests: XCTestCase {
    func testURLGate() {
        XCTAssertTrue(Web.validURL("https://example.com"))
        XCTAssertFalse(Web.validURL("file:///etc/passwd"))
        XCTAssertFalse(Web.validURL("javascript:alert(1)"))
        XCTAssertFalse(Web.validURL("not a url"))
    }
    func testRegistryHasWeb() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        let names = Set(r.list().map { $0.name })
        for w in ["web_shot","web_text","web_pdf"] {
            XCTAssertTrue(names.contains(w), "missing \(w)")
        }
        XCTAssertGreaterThanOrEqual(r.list().count, 40)
    }
}
