import XCTest
@testable import macrix

final class HundredTests: XCTestCase {
    func testWebOriginalsIntact() {
        XCTAssertNotNil(Web.browser())
        XCTAssertTrue(Web.shot(url: "file:///tmp").contains("web unavailable"))
        XCTAssertTrue(Web.text(url: "").contains("web unavailable"))
        XCTAssertTrue(Web.pdf(url: "ftp://x").contains("web unavailable"))
    }
    func testFileB64RandomPlistGet() {
        let src = "/tmp/macrix_fb_\(Int(Date().timeIntervalSince1970)).txt"
        try? "abc".write(toFile: src, atomically: true, encoding: .utf8)
        XCTAssertEqual(Codec.fileB64(src), "YWJj")
        try? FileManager.default.removeItem(atPath: src)
        XCTAssertTrue(Codec.fileB64("/tmp/nope").contains("missing"))
        let h1 = Codec.randomHex(16), h2 = Codec.randomHex(16)
        XCTAssertEqual(h1.count, 32)
        XCTAssertNotEqual(h1, h2)
        XCTAssertEqual(Codec.randomHex(999).count, 128)
        let sys = "/System/Library/CoreServices/SystemVersion.plist"
        let v = Probe.plistGet(sys, key: "ProductVersion")
        XCTAssertTrue(v.contains("26") || v.contains("key not found"), v)
        XCTAssertTrue(Probe.plistGet(sys, key: "no/such").contains("need a dot-separated"))
        XCTAssertTrue(Probe.plistGet("/tmp/nope.plist", key: "a").contains("missing"))
    }
    func testJevValidation() {
        XCTAssertTrue(Jev.judge(state: "", question: "q").contains("need state"))
        XCTAssertTrue(Jev.skill("").contains("need a prompt"))
    }
    func testUrlCodec() {
        XCTAssertEqual(Codec.urlDecode(Codec.urlEncode("olá mundo &+=")), "olá mundo &+=")
        XCTAssertTrue(Codec.urlDecode("%zz").contains("invalid") || Codec.urlDecode("%zz") == "%zz")
    }
    func testFileHashDirSize() {
        let src = "/tmp/macrix_hash_\(Int(Date().timeIntervalSince1970)).txt"
        try? "abc".write(toFile: src, atomically: true, encoding: .utf8)
        XCTAssertEqual(Probe.fileHash(src), Codec.sha256("abc"))
        try? FileManager.default.removeItem(atPath: src)
        XCTAssertTrue(Probe.fileHash("/tmp/nope").contains("missing"))
        XCTAssertTrue(Probe.dirSize("/etc").contains("refused"))
        XCTAssertFalse(Probe.dirSize("/tmp").isEmpty)
    }
    func testHostAndTailscale() {
        XCTAssertFalse(Probe.hostName().isEmpty)
        XCTAssertTrue(Probe.tailscale().contains("sugs-macbook") || Probe.tailscale().contains("100."),
                      Probe.tailscale())
    }
    func testCsvCols() {
        let src = "/tmp/macrix_cols_\(Int(Date().timeIntervalSince1970)).csv"
        try? "nome,idade,cidade\nana,3,sp\n".write(toFile: src, atomically: true, encoding: .utf8)
        let out = TextUtil.csvCols(src)
        XCTAssertTrue(out.contains("1. nome") && out.contains("3. cidade"), out)
        try? FileManager.default.removeItem(atPath: src)
    }
    func testHundred() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        XCTAssertEqual(r.list().count, 107)
    }
}
