import XCTest
@testable import Sticky

final class FileMetricsTests: XCTestCase {
    func testTotalSizeMeasuresRealFiles() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("sample.txt")
        try Data(repeating: 0x41, count: 2048).write(to: file)

        let bytes = await FileMetrics.shared.totalSize(of: [file])
        XCTAssertEqual(bytes, 2048)
        XCTAssertFalse(FileMetrics.format(2048).isEmpty)
    }

    func testKindNamesTheFileNotTheExtension() {
        let png = URL(fileURLWithPath: "/tmp/x.png")
        XCTAssertFalse(FileMetrics.kind(of: png).isEmpty)
        // A file with no extension still gets an answer.
        XCTAssertFalse(FileMetrics.kind(of: URL(fileURLWithPath: "/tmp/noext")).isEmpty)
    }
}
