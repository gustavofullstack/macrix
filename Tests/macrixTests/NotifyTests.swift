import XCTest
@testable import macrix

final class NotifyTests: XCTestCase {
    func testQuitRefusals() {
        XCTAssertTrue(Notify.quitApp("").contains("refused"))
        XCTAssertTrue(Notify.quitApp("/bin/x").contains("refused"))
        XCTAssertTrue(Notify.quitApp("a\"b").contains("refused"))
    }
    func testRenderValidation() {
        XCTAssertTrue(Notify.render("", voice: nil).contains("missing"))
    }
    func testRegistryCount() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        XCTAssertGreaterThanOrEqual(r.list().count, 56)
    }
}
