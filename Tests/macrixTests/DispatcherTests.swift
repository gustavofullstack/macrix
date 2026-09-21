import XCTest
@testable import macrix

final class DispatcherTests: XCTestCase {
    func makeRegistry() -> ToolRegistry {
        let r = ToolRegistry()
        registerAllTools(into: r)
        return r
    }
    func testInitialize() async {
        let req: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1),
                                      "method": .string("initialize"), "params": .object([:])])
        let resp = await MCPDispatcher.handle(request: req, registry: makeRegistry())
        XCTAssertEqual(resp?["result"]?["serverInfo"]?["name"]?.string, "macrix")
    }
    func testToolsListContainsCore() async {
        let req: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(2),
                                      "method": .string("tools/list")])
        let resp = await MCPDispatcher.handle(request: req, registry: makeRegistry())
        guard case .array(let tools) = resp?["result"]?["tools"] else {
            return XCTFail("tools/list missing")
        }
        let names = Set(tools.compactMap { $0["name"]?.string })
        for want in ["health", "calendar_search_events", "reminders_search",
                     "notes_search_notes", "shortcuts_list", "shortcuts_run", "jev_rerank",
                     "mail_search", "messages_search", "contacts_search", "screen_capture",
                     "cu_click", "cu_type", "cu_key", "cu_scroll", "cu_windows",
                     "cu_front_app", "cu_ax_query", "cu_shot", "usage_status"] {
            XCTAssertTrue(names.contains(want), "missing \(want)")
        }
    }
    func testUnknownMethod() async {
        let req: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(3),
                                      "method": .string("nope/nothing")])
        let resp = await MCPDispatcher.handle(request: req, registry: makeRegistry())
        XCTAssertEqual(resp?["error"]?["code"]?.int, -32601)
    }
    func testNotificationReturnsNil() async {
        let req: JSONValue = .object(["method": .string("notifications/initialized")])
        let resp = await MCPDispatcher.handle(request: req, registry: makeRegistry())
        XCTAssertNil(resp)
    }
    func testJSONRoundTrip() throws {
        let v: JSONValue = .object(["a": .number(1), "b": .array([.string("x"), .null])])
        let data = try JSONEncoder().encode(v)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), v)
    }
}
