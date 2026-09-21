import XCTest
@testable import macrix

/// Regression tests from the 2026-09-21 self-audit:
/// case-insensitive secret filter + git refusal.
final class SecurityTests: XCTestCase {
    func testDeniedCaseInsensitive() {
        XCTAssertTrue(Files.denied("~/.ssh/id_rsa"))
        XCTAssertTrue(Files.denied("~/.SSH/id_rsa"))
        XCTAssertTrue(Files.denied("~/.Ssh/ID_RSA"))
        XCTAssertTrue(Files.denied("my_secrets.txt"))
        XCTAssertTrue(Files.denied("a/.ENV/b"))
        XCTAssertTrue(Files.denied("x/Keychain/y"))
        XCTAssertFalse(Files.denied("/tmp/notes.txt"))
        XCTAssertFalse(Files.denied("~/Documents/PROJETOS/macrix/README.md"))
    }
    func testGitRefusesSecrets() {
        XCTAssertTrue(Git.status("~/.ssh").contains("refused"))
        XCTAssertTrue(Git.log("~/.SSH", n: 5).contains("refused"))
        XCTAssertTrue(Git.diffstat("creds.env").contains("refused"))
    }
    func testHundredStill() {
        let r = ToolRegistry()
        registerAllTools(into: r)
        XCTAssertEqual(r.list().count, 107)
    }
}
