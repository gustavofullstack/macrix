import XCTest
@testable import macrix

final class GitClockTests: XCTestCase {
    func testNonRepo() {
        XCTAssertTrue(Git.status("/tmp").contains("not a git repo"))
        XCTAssertTrue(Git.log("/tmp", n: 5).contains("not a git repo"))
        XCTAssertTrue(Git.diffstat("/tmp").contains("not a git repo"))
    }
    func testLogClamp() {
        // macrix repo itself: n=999 clamps to 30 lines max
        let out = Git.log(FileManager.default.currentDirectoryPath, n: 999)
        XCTAssertLessThanOrEqual(out.split(separator: "\n").count, 30)
    }
    func testClock() {
        XCTAssertFalse(Clock.now().isEmpty)
        XCTAssertTrue(Clock.world([]).contains("1-5"))
        XCTAssertTrue(Clock.world(["America/Sao_Paulo", "Nope/Zone"]).contains("unknown zone"))
        XCTAssertTrue(Clock.world(["America/Sao_Paulo"]).contains("America/Sao_Paulo: 20"))
    }
    func testRegistryCount() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        XCTAssertGreaterThanOrEqual(r.list().count, 65)
    }
}
