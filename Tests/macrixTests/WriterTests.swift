import XCTest
@testable import macrix

final class WriterTests: XCTestCase {
    func testRegistryHasWriters() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        let names = Set(r.list().map { $0.name })
        for w in ["calendar_create_event","calendar_delete_event","reminders_create","reminders_complete"] {
            XCTAssertTrue(names.contains(w), "missing \(w)")
        }
        XCTAssertEqual(r.list().count, 37)
    }
    func testCreateValidation() async {
        let r = ToolRegistry()
        registerAllTools(into: r)
        // bad dates must fail validation before touching EventKit
        let res = await r.call(name: "calendar_create_event", args: .object([
            "title": .string("t"), "start": .string("nope"), "end": .string("nope")]))
        XCTAssertEqual(res["isError"]?.bool, true)
    }
}
