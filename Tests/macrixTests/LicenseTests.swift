import XCTest
@testable import macrix

final class LicenseTests: XCTestCase {
    func testFreeQuota() {
        XCTAssertEqual(License.Tier.free.dailyQuota, 1000)
        XCTAssertNil(License.Tier.lifetime.dailyQuota)
    }
    func testTierLadder() {
        XCTAssertEqual(License.Tier.starter.priceUSD, 20)
        XCTAssertEqual(License.Tier.growth.priceUSD, 50)
        XCTAssertEqual(License.Tier.scale.priceUSD, 100)
        XCTAssertEqual(License.Tier.max.priceUSD, 200)
        XCTAssertEqual(License.Tier.starter.dailyQuota, 10_000)
        XCTAssertEqual(License.Tier.growth.dailyQuota, 50_000)
        XCTAssertEqual(License.Tier.scale.dailyQuota, 200_000)
        XCTAssertNil(License.Tier.max.dailyQuota)
        XCTAssertEqual(License.Tier(name: "pro"), .growth)
        XCTAssertNil(Usage.check(keyFP: "zzz", tool: "health", tier: .max))
    }
    func testFingerprintStable() {
        XCTAssertEqual(License.fingerprint("abc"), License.fingerprint("abc"))
        XCTAssertNotEqual(License.fingerprint("abc"), License.fingerprint("abd"))
        XCTAssertEqual(License.fingerprint("abc").count, 16)
    }
    func testQuotaGate() {
        // pro/lifetime never blocked
        XCTAssertNil(Usage.check(keyFP: "x", tool: "health", tier: .lifetime))
        XCTAssertNil(Usage.check(keyFP: "x", tool: "health", tier: .growth))
        // free with huge usage blocked (use synthetic fp unlikely to collide)
        let fp = "testfp-\(Int(Date().timeIntervalSince1970))"
        for _ in 0..<1005 { Usage.record(keyFP: fp, tool: "health") }
        XCTAssertNotNil(Usage.check(keyFP: fp, tool: "health", tier: .free))
    }
}
