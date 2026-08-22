import XCTest

@testable import Sticky

final class ClipboardLogicTests: XCTestCase {
    @MainActor
    func testPersistedEntryFormatRoundTripsStableFields() throws {
        let entry = makeEntry(text: "from Windows", sender: "Sticky PC")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let data = try encoder.encode([entry])
        let decoded = try decoder.decode([StickyClipEntry].self, from: data).first

        XCTAssertEqual(decoded?.id, entry.id)
        XCTAssertEqual(decoded?.text, entry.text)
        XCTAssertEqual(decoded?.timestamp, entry.timestamp)
        XCTAssertEqual(decoded?.sender, entry.sender)
        XCTAssertTrue(
            String(data: try encoder.encode(entry), encoding: .utf8)!.contains(#""sender":"Sticky PC""#)
        )
    }

    @MainActor
    func testStartAndStopDoNotEmitWhileTestRuns() {
        let service = ClipboardService()
        var pushedTexts: [String] = []

        service.start { pushedTexts.append($0) }
        service.stop()
        service.stop()

        XCTAssertTrue(pushedTexts.isEmpty)
    }

    @MainActor
    private func makeEntry(text: String, sender: String? = nil) -> StickyClipEntry {
        StickyClipEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, text: text, timestamp: Date(timeIntervalSince1970: 1_234_567_890), sender: sender)
    }
}
