import XCTest
@testable import macrix

final class ArchiveTests: XCTestCase {
    func testZipRoundTrip() {
        let src = "/tmp/macrix_ziptest_\(Int(Date().timeIntervalSince1970)).txt"
        try? "alpha\nbeta\ngamma\n".write(toFile: src, atomically: true, encoding: .utf8)
        let name = "macrix_rt_\(Int(Date().timeIntervalSince1970)).zip"
        let c = Archive.create(zipName: name, paths: [src])
        XCTAssertTrue(c.hasPrefix("zipped:"), c)
        let zp = "/tmp/\(name)"
        let l = Archive.list(zp)
        XCTAssertTrue(l.contains(URL(fileURLWithPath: src).lastPathComponent), l)
        let e = Archive.extract(zp)
        XCTAssertTrue(e.hasPrefix("extracted 1"), e)
        try? FileManager.default.removeItem(atPath: src)
        try? FileManager.default.removeItem(atPath: zp)
        if e.hasPrefix("extracted") {
            let dir = e.components(separatedBy: " ").last ?? ""
            try? FileManager.default.removeItem(atPath: dir)
        }
    }
    func testZipRefusals() {
        XCTAssertTrue(Archive.create(zipName: "../x.zip", paths: ["/tmp/a"]).contains("need"))
        XCTAssertTrue(Archive.list("/tmp/nope.txt").contains("need an existing .zip"))
        XCTAssertTrue(TextUtil.grep("/tmp", pattern: "").contains("need a literal"))
    }
    func testTextUtils() {
        let src = "/tmp/macrix_txt_\(Int(Date().timeIntervalSince1970)).csv"
        try? "a,b\n1,2\n3,4\n".write(toFile: src, atomically: true, encoding: .utf8)
        XCTAssertTrue(TextUtil.stats(src).contains("lines=4"))
        XCTAssertTrue(TextUtil.csvHead(src, n: 2).contains("1,2"))
        XCTAssertTrue(TextUtil.grep(src, pattern: "3,4").contains("3,4"))
        XCTAssertTrue(TextUtil.grep(src, pattern: "zzz") == "(no matches)")
        try? FileManager.default.removeItem(atPath: src)
    }
    func testRegistryCount() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        XCTAssertGreaterThanOrEqual(r.list().count, 77)
    }
}
