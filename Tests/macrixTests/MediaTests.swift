import XCTest
@testable import macrix

final class MediaTests: XCTestCase {
    func testImgPipeline() {
        // QR png as a guaranteed-valid image fixture.
        let q = Codec.qr("media-fixture")
        XCTAssertTrue(q.hasPrefix("qr: "), q)
        let src = String(q.dropFirst(4))
        defer { try? FileManager.default.removeItem(atPath: src) }
        let info = Media.imgInfo(src)
        XCTAssertTrue(info.contains("pixelWidth"), info)
        let r = Media.imgResize(src, maxSide: 64)
        XCTAssertTrue(r.hasPrefix("resized: "), r)
        let rp = String(r.dropFirst(9))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rp))
        try? FileManager.default.removeItem(atPath: rp)
        let c = Media.imgConvert(src, format: "jpeg")
        XCTAssertTrue(c.hasPrefix("converted: "), c)
        try? FileManager.default.removeItem(atPath: String(c.dropFirst(11)))
        XCTAssertTrue(Media.imgConvert(src, format: "bmp").contains("must be png"))
    }
    func testMediaRefusals() {
        XCTAssertTrue(Media.imgInfo("/tmp/nope.png").contains("missing"))
        XCTAssertTrue(Media.audioInfo("/tmp/nope.aiff").contains("missing"))
        XCTAssertTrue(Media.audioInfo("/tmp/x").contains("missing"))
    }
    func testRegistryCount() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        XCTAssertGreaterThanOrEqual(r.list().count, 81)
    }
}
