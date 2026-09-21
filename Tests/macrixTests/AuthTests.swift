import XCTest
@testable import macrix

final class AuthTests: XCTestCase {
    func testTokenExtraction() {
        XCTAssertEqual(Auth.token(from: "Bearer abc123"), "abc123")
        XCTAssertNil(Auth.token(from: nil))
        XCTAssertNil(Auth.token(from: "Basic abc"))
        XCTAssertNil(Auth.token(from: "Bearer "))
    }
    func testAuthorize() {
        let keys: Set<String> = ["k1", "k2"]
        XCTAssertTrue(Auth.isAuthorized(headerValue: "Bearer k1", keys: keys))
        XCTAssertTrue(Auth.isAuthorized(headerValue: "Bearer k2", keys: keys))
        XCTAssertFalse(Auth.isAuthorized(headerValue: "Bearer k3", keys: keys))
        XCTAssertFalse(Auth.isAuthorized(headerValue: nil, keys: keys))
    }
}
