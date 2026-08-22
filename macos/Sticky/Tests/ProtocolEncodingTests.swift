import Foundation
import XCTest

@testable import Sticky

final class ProtocolEncodingTests: XCTestCase {
    func testTransferRequestUsesProtocolV1FieldNames() throws {
        let request = TransferRequest(
            session: "session-1",
            sender: SenderInfo(id: "device-1", name: "Michael's MacBook"),
            files: [
                StickyFileMeta(
                    id: "f1",
                    path: "Reports/Q3/report.png",
                    size: 12345,
                    mime: "image/png",
                    previewData: nil
                )
            ],
            text: nil,
            kind: .files
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(data: try encoder.encode(request), encoding: .utf8)

        XCTAssertEqual(
            json,
            """
            {"files":[{"id":"f1","mime":"image/png","path":"Reports/Q3/report.png","size":12345}],"kind":"files","sender":{"id":"device-1","name":"Michael's MacBook"},"session":"session-1"}
            """
        )
    }

    func testPrepareAndCompleteResponsesRoundTrip() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let prepareData = Data(#"{"session":"session-1","tokens":{"f1":"token-1"}}"#.utf8)
        let prepare = try decoder.decode(PrepareResponse.self, from: prepareData)
        XCTAssertEqual(prepare.session, "session-1")
        XCTAssertEqual(prepare.tokens["f1"], "token-1")
        XCTAssertEqual(
            String(data: try encoder.encode(prepare), encoding: .utf8),
            #"{"session":"session-1","tokens":{"f1":"token-1"}}"#
        )

        let completeData = Data(#"{"received":["Reports/Q3/report.png"]}"#.utf8)
        let complete = try decoder.decode(CompleteResponse.self, from: completeData)
        XCTAssertEqual(complete.received, ["Reports/Q3/report.png"])
    }

    func testRelativeFolderPathIsPreservedByManifestEncoding() throws {
        let request = TransferRequest(
            session: "session-2",
            sender: SenderInfo(id: "device-2", name: "Sender"),
            files: [
                StickyFileMeta(id: "folder-root", path: "Photos", size: 0, mime: nil, previewData: nil),
                StickyFileMeta(id: "folder-child", path: "Photos/2026/cat.jpg", size: 42, mime: "image/jpeg", previewData: nil)
            ],
            text: nil,
            kind: .files
        )

        let decoded = try JSONDecoder().decode(TransferRequest.self, from: JSONEncoder().encode(request))

        XCTAssertEqual(decoded.files.map(\.path), ["Photos", "Photos/2026/cat.jpg"])
    }

    func testMimeTypesMatchSupportedProtocolExtensions() {
        XCTAssertEqual(mimeType(for: "PNG"), "image/png")
        XCTAssertEqual(mimeType(for: "jpeg"), "image/jpeg")
        XCTAssertEqual(mimeType(for: "txt"), "text/plain")
        XCTAssertEqual(mimeType(for: "unknown"), nil)
    }
}
