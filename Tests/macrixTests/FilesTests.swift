import XCTest
@testable import macrix

final class FilesTests: XCTestCase {
    func testDenials() {
        XCTAssertTrue(Files.denied("~/.ssh/id_rsa"))
        XCTAssertTrue(Files.denied("/x/credenciais.env"))
        XCTAssertTrue(Files.read("~/.ssh/id_rsa").contains("refused"))
        XCTAssertTrue(Files.write(name: "../evil", content: "x").contains("refused"))
        XCTAssertTrue(Files.write(name: ".env", content: "x").contains("refused"))
        XCTAssertTrue(Files.list("/etc").contains("refused"))
    }
    func testRoundTrip() throws {
        let name = "macrix-test-\(Int(Date().timeIntervalSince1970)).txt"
        XCTAssertTrue(Files.write(name: name, content: "hello").contains("wrote"))
        XCTAssertEqual(Files.read("/tmp/" + name), "hello")
        try FileManager.default.removeItem(atPath: "/tmp/" + name)
        XCTAssertTrue(Files.list("/tmp").contains("macrix-test-") == false)
    }
    func testRegistryCount() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        XCTAssertGreaterThanOrEqual(r.list().count, 45)
    }
}
