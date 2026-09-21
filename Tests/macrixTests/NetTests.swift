import XCTest
@testable import macrix

final class NetTests: XCTestCase {
    func testDnsLocalhost() {
        XCTAssertTrue(Net.dns("localhost").contains("127.0.0.1"))
        XCTAssertTrue(Net.dns("").contains("invalid"))
        XCTAssertTrue(Net.dns("a b").contains("invalid"))
    }
    func testIpsShape() {
        XCTAssertTrue(Net.ips().contains("127.0.0.1") || Net.ips().contains("."))
    }
    func testRegistryCount() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        XCTAssertGreaterThanOrEqual(r.list().count, 49)
    }
}
