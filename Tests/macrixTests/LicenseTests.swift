import XCTest
@testable import macrix

final class LicenseTests: XCTestCase {
    func testFreeQuota() {
        XCTAssertEqual(License.Tier.free.dailyQuota, 1000)
        XCTAssertNil(License.Tier.pro.dailyQuota)
        XCTAssertNil(License.Tier.lifetime.dailyQuota)
    }
    func testFingerprintStable() {
        XCTAssertEqual(License.fingerprint("abc"), License.fingerprint("abc"))
        XCTAssertNotEqual(License.fingerprint("abc"), License.fingerprint("abd"))
        XCTAssertEqual(License.fingerprint("abc").count, 16)
    }
    func testQuotaGate() {
        // pro/lifetime never blocked
        XCTAssertNil(Usage.check(keyFP: "x", tool: "health", tier: .lifetime))
        XCTAssertNil(Usage.check(keyFP: "x", tool: "health", tier: .pro))
        // free with huge usage blocked (use synthetic fp unlikely to collide)
        let fp = "testfp-\(Int(Date().timeIntervalSince1970))"
        for _ in 0..<1005 { Usage.record(keyFP: fp, tool: "health") }
        XCTAssertNotNil(Usage.check(keyFP: fp, tool: "health", tier: .free))
    }
}
