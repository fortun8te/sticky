import XCTest

@testable import Sticky

final class NotchStateTests: XCTestCase {
    @MainActor
    func testResetClearsFailureState() {
        let model = NotchViewModel()
        model.state = .failure(reason: "offline")

        model.resetToIdle()

        XCTAssertEqual(model.state, .idle)
    }

    @MainActor
    func testIncomingTransferRemainsVisibleUntilItCompletes() {
        let model = NotchViewModel()
        model.receiveIncomingOffer(senderName: "Sticky PC", fileCount: 2, kind: .files)

        XCTAssertEqual(model.state, .incomingOffer(senderName: "Sticky PC", fileCount: 2, kind: .files))
    }

    @MainActor
    func testShelfAcceptsMultipleFilesAndPreservesOrder() {
        let model = NotchViewModel()
        let urls = [
            URL(fileURLWithPath: "/tmp/a.png"),
            URL(fileURLWithPath: "/tmp/b.pdf")
        ]

        model.addToShelf(urls)

        XCTAssertEqual(model.shelfFiles.map(\.url), urls)
        XCTAssertEqual(model.shelfFiles.map(\.name), ["a.png", "b.pdf"])
        XCTAssertEqual(model.shelfFiles.map(\.isImage), [true, false])
    }

    func testPendingTransferQueuePersistsAcrossLaunch() throws {
        let item = StickyShelfItem(url: URL(fileURLWithPath: "/tmp/staging.pdf"))
        let transfer = PendingTransfer(items: [item], attempts: 2)
        let data = try JSONEncoder().encode([transfer])

        let restored = try JSONDecoder().decode([PendingTransfer].self, from: data)

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].id, transfer.id)
        XCTAssertEqual(restored[0].items.map(\.url), [item.url])
        XCTAssertEqual(restored[0].attempts, 2)
    }

}
