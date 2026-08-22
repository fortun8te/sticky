import Foundation

enum StickyPlatform: String, Codable {
    case mac = "mac"
    case win = "win"
}

struct StickyDevice: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let platform: StickyPlatform
    let host: String
    let port: Int
    var lastSeen: Date = .init()
}

enum TransferKind: String, Codable {
    case files
    case clipboard
    case text
}

struct StickyFileMeta: Codable {
    let id: String
    let path: String
    let size: Int64
    let mime: String?
    var previewData: Data?
}

struct TransferRequest: Codable {
    let session: String
    let sender: SenderInfo
    let files: [StickyFileMeta]
    let text: String?
    let kind: TransferKind
}

struct SenderInfo: Codable {
    let id: String
    let name: String
}

struct PrepareResponse: Codable {
    let session: String
    let tokens: [String: String]
}

struct CompleteResponse: Codable {
    let received: [String]
}

enum NotchState: Equatable {
    case idle
    case hover
    case armed(fileCount: Int, previewImage: Data?)
    case transferring(progress: Double, fileName: String?)
    case queued(fileCount: Int, previewImage: Data?)
    case success(fileCount: Int)
    case failure(reason: String?)
    case incomingOffer(senderName: String, fileCount: Int, kind: TransferKind)
}
