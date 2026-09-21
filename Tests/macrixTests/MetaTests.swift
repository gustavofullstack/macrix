import XCTest
@testable import macrix

final class MetaTests: XCTestCase {
    func testMetaDeniesSecrets() {
        XCTAssertTrue(Meta.read("~/.ssh/id_rsa").contains("refused"))
    }
    func testMetaReadSelf() {
        // Project file itself must yield mdls metadata
        let r = Meta.read("~/Documents/PROJETOS/macrix/README.md")
        XCTAssertTrue(r.contains("kMDItem") || r.contains("no metadata"))
    }
    func testStdinPassthrough() {
        let (code, out) = runProcess("/usr/bin/tr", ["a-z", "A-Z"], timeoutSeconds: 10, stdin: "hello")
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "HELLO")
    }
    func testRegistryCount() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        XCTAssertGreaterThanOrEqual(r.list().count, 52)
    }
}
