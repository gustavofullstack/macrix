import XCTest
@testable import macrix

final class WebClipTests: XCTestCase {
    func testRefusals() {
        XCTAssertTrue(WebClip.fetch("file:///etc/passwd").contains("refused"))
        XCTAssertTrue(WebClip.fetch("ftp://x/y").contains("refused"))
        XCTAssertTrue(WebClip.download("file:///etc/passwd", name: nil).contains("refused"))
        XCTAssertTrue(WebClip.open("file:///tmp").contains("refused"))
        XCTAssertTrue(WebClip.download("https://example.com/", name: "").contains("need a filename"))
    }
    func testRegistryCount() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        XCTAssertGreaterThanOrEqual(r.list().count, 60)
    }
}
