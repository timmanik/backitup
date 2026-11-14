import Foundation
import ImageCaptureCore

enum MediaKind: String, CaseIterable, Identifiable, Codable {
    case photo = "Photos"
    case live = "Live Photos"
    case portrait = "Portrait"
    case panorama = "Panoramas"
    case burst = "Bursts"
    case screenshot = "Screenshots"
    case video = "Videos"
    case slowMotion = "Slo-mo"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .photo: "photo"
        case .live: "livephoto"
        case .portrait: "person.crop.rectangle"
        case .panorama: "pano"
        case .burst: "square.stack.3d.up"
        case .screenshot: "iphone"
        case .video: "video"
        case .slowMotion: "slowmo"
        }
    }
}

struct PhotoAsset: Identifiable, Hashable, Codable {
    let id: String
    let deviceID: String
    let name: String
    let date: Date
    let bytes: Int64
    var kind: MediaKind
    let groupID: String?
    let width: Int
    let height: Int

    var isVideo: Bool { kind == .video || kind == .slowMotion }
    var sourceKey: String {
        "\(deviceID)|\(id)|\(name)|\(bytes)|\(Int(date.timeIntervalSince1970))|\(groupID ?? "")"
    }
    var cacheKey: String {
        "\(deviceID)|\(name)|\(bytes)|\(Int(date.timeIntervalSince1970))|\(groupID ?? "")"
    }
}

enum MomentFolderName: String, CaseIterable {
    case dateOnly, dateLocation, locationDate
}

struct ExportOptions {
    var kinds = Set(MediaKind.allCases)
    var includeLiveVideos = true
    var includePortraitOriginals = true
    var includeBurstFrames = true
    var includeEditedOriginals = true
    var moments = true
    var momentFolderName: MomentFolderName = .dateLocation
    var mediaFolders = false
    var originalFilenames = true
    var convertHEIC = false
    var jpegQuality = 0.95
    var convertHEVC = false
}

struct BackupRecord: Codable {
    let sourceKey: String
    let relativePath: String
    let sha256: String
    let bytes: Int64
    let backedUpAt: Date
    let relatedFiles: [BackupFileRecord]
    let deletionSafe: Bool
}

struct BackupFileRecord: Codable {
    let relativePath: String
    let sha256: String
    let bytes: Int64
}

struct BackupManifest: Codable {
    var records: [String: BackupRecord] = [:]
}

enum BackupState: Equatable {
    case unknown
    case checking
    case verified
    case partial
    case missing
    case changed

    var label: String {
        switch self {
        case .unknown: "Not checked"
        case .checking: "Checking"
        case .verified: "Verified backup"
        case .partial: "Copy saved; original needed for deletion"
        case .missing: "No backup"
        case .changed: "Backup changed"
        }
    }
}

func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
