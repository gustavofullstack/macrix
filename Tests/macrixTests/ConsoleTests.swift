import XCTest
@testable import macrix

final class ConsoleTests: XCTestCase {
    func testHtml() {
        let page = Console.html(version: "0.23.0", tier: "lifetime", tools: 100, requests: 7, uptime: 3723)
        XCTAssertTrue(page.contains("macrix"))
        XCTAssertTrue(page.contains("0.23.0"))
        XCTAssertTrue(page.contains("100"))
        XCTAssertTrue(page.contains("1h 2m 3s"))
        XCTAssertFalse(page.contains("mcp_"))
    }
    func testCatalog() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        let body = Console.catalog(r.list())
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tools = obj["tools"] as? [[String: String]] else {
            return XCTFail("catalog not parseable JSON")
        }
        XCTAssertEqual(tools.count, 107)
        XCTAssertTrue(tools.allSatisfy { $0["name"] != nil && $0["description"] != nil })
        let names = tools.compactMap { $0["name"] }
        XCTAssertEqual(Set(names).count, 107)
    }
    func testHundredStill() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        XCTAssertEqual(r.list().count, 107)
    }
    func testUsageJSON() {
        let body = Console.usageJSON(fp: "deadbeef", tier: .free)
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("usage not parseable JSON")
        }
        XCTAssertEqual(obj["tier"] as? String, "free")
        XCTAssertEqual(obj["quota"] as? String, "1000")
        XCTAssertNotNil(obj["used_today"])
        XCTAssertNotNil(obj["by_tool"])
        let life = Console.usageJSON(fp: "x", tier: .lifetime)
        XCTAssertTrue(life.contains("\"unlimited\""))
    }
}
