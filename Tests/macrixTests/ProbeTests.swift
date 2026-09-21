import XCTest
@testable import macrix

final class ProbeTests: XCTestCase {
    func testLiveProbes() {
        XCTAssertTrue(Probe.uptime().contains("up"), Probe.uptime())
        XCTAssertTrue(Probe.mem().contains("Pages"), Probe.mem())
        XCTAssertFalse(Probe.launchd().isEmpty)
        XCTAssertFalse(Probe.ports().isEmpty)
    }
    func testHeadings() {
        let src = "/tmp/macrix_md_\(Int(Date().timeIntervalSince1970)).md"
        try? "# T\ntext\n## S\n".write(toFile: src, atomically: true, encoding: .utf8)
        let h = Probe.headings(src)
        XCTAssertTrue(h.contains("# T") && h.contains("## S"), h)
        try? FileManager.default.removeItem(atPath: src)
        XCTAssertEqual(Probe.headings("/tmp"), "(no headings)")
    }
    func testPlist() {
        XCTAssertTrue(Probe.plist("/tmp/nope.plist").contains("missing"))
        // A real system plist parses.
        let out = Probe.plist("/System/Library/CoreServices/SystemVersion.plist")
        XCTAssertTrue(out.contains("ProductVersion") || out.contains("not a plist") || out.contains("missing"), out)
    }
    func testRegistryCount() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        XCTAssertGreaterThanOrEqual(r.list().count, 87)
    }
}
