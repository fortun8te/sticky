import XCTest

@testable import Sticky

final class PairingTokenTests: XCTestCase {
    func testPairingTokenPersistsAndUnpairs() throws {
        let pairing = PairingService.shared
        let deviceID = "test-\(UUID().uuidString)"
        let fingerprint = String(repeating: "a", count: 64)

        defer { try? pairing.unpair(deviceID: deviceID) }

        try pairing.pinPeer(deviceID: deviceID, fingerprint: fingerprint)
        let token = try pairing.createAuthorizationToken(for: deviceID)

        XCTAssertEqual(token.count, 64)
        XCTAssertEqual(pairing.authorizationToken(for: deviceID), token)
        XCTAssertTrue(token.allSatisfy(\.isHexDigit))

        try pairing.unpair(deviceID: deviceID)
        XCTAssertNil(pairing.authorizationToken(for: deviceID))
    }
}
