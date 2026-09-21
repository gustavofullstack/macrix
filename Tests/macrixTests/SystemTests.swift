import XCTest
@testable import macrix

final class SystemTests: XCTestCase {
    func testInfoShape() {
        let s = Sys.info()
        XCTAssertTrue(s.contains("model=") && s.contains("macos="))
    }
    func testBatteryShape() {
        XCTAssertFalse(Sys.battery().isEmpty)
    }
    func testDiskShape() {
        XCTAssertTrue(Sys.disk().contains("/"))
    }
    func testOpenRefusesJunk() {
        XCTAssertTrue(Sys.openTarget("").contains("refused"))
        XCTAssertTrue(Sys.openTarget("rm -rf /").contains("refused"))
    }
    func testRegistryHasSysFamily() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        let names = Set(r.list().map { $0.name })
        for w in ["sys_info","sys_battery","sys_volume","sys_wifi","sys_clipboard","sys_procs","sys_disk","sys_open"] {
            XCTAssertTrue(names.contains(w), "missing \(w)")
        }
        XCTAssertEqual(r.list().count, 33)
    }
}
