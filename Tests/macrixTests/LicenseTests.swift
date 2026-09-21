import XCTest
@testable import macrix

final class LicenseTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Never pollute production metering: quota tests use a tmp file.
        setenv("MACRIX_USAGE_PATH", "/tmp/macrix_test_usage.json", 1)
        try? FileManager.default.removeItem(atPath: "/tmp/macrix_test_usage.json")
    }
    override func tearDown() {
        unsetenv("MACRIX_USAGE_PATH")
        try? FileManager.default.removeItem(atPath: "/tmp/macrix_test_usage.json")
        super.tearDown()
    }
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
    func testAdmitAtomic() {
        let fp = "admitfp-\(Int(Date().timeIntervalSince1970))"
        XCTAssertNil(Usage.admit(keyFP: fp, tool: "health", tier: .free))
        XCTAssertNil(Usage.check(keyFP: fp, tool: "health", tier: .free))  // 1 < 1000
        for _ in 0..<999 { Usage.record(keyFP: fp, tool: "health") }  // total 1000
        XCTAssertNotNil(Usage.admit(keyFP: fp, tool: "health", tier: .free))  // over, uncounted
        XCTAssertNil(Usage.admit(keyFP: fp, tool: "health", tier: .lifetime))  // unlimited
    }
}
