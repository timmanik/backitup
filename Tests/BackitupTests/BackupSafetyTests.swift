import CryptoKit
import Foundation
import XCTest
@testable import Backitup

final class BackupSafetyTests: XCTestCase {
    func testPartialPrimaryIsRetainedButCannotVerifyForDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged")
        try Data("hello".utf8).write(to: staged)
        let source = asset()
        let service = BackupService()
        let record = try service.savePartialPrimary(staged, asset: source, folder: root, root: root)
        let manifest = BackupManifest(records: [source.sourceKey: record])
        XCTAssertEqual(service.verify(source, at: root, manifest: manifest), .partial)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(record.relativePath)), Data("hello".utf8))
        try Data("other".utf8).write(to: root.appendingPathComponent(record.relativePath))
        XCTAssertEqual(service.verify(source, at: root, manifest: manifest), .changed)
        try Data("bad".utf8).write(to: staged)
        XCTAssertThrowsError(try service.savePartialPrimary(staged, asset: source, folder: root, root: root))
    }
    func testMomentFoldersUseYearAndSelectedName() {
        let root = URL(fileURLWithPath: "/backup", isDirectory: true)
        let source = asset()
        let service = BackupService()
        var options = ExportOptions()
        let date = DateFormatter()
        date.calendar = Calendar(identifier: .gregorian)
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd"
        let stamp = date.string(from: source.date)
        options.momentFolderName = .dateOnly
        XCTAssertEqual(service.destinationFolder(for: source, location: "Place", root: root, options: options).path, "/backup/\(stamp.prefix(4))/\(stamp)")
        options.momentFolderName = .locationDate
        XCTAssertEqual(service.destinationFolder(for: source, location: "Place", root: root, options: options).lastPathComponent, "Place - \(stamp)")
        options.momentFolderName = .dateLocation
        XCTAssertEqual(service.destinationFolder(for: source, location: "Place", root: root, options: options).lastPathComponent, "\(stamp) - Place")
        options.moments = false
        XCTAssertEqual(service.destinationFolder(for: source, location: "Place", root: root, options: options), root)
    }

    func testRelatedDownloadSizeValidation() {
        XCTAssertTrue(BackupService.relatedSizeIsComplete(expected: 100, actual: 100))
        XCTAssertFalse(BackupService.relatedSizeIsComplete(expected: 100, actual: 99))
        XCTAssertFalse(BackupService.relatedSizeIsComplete(expected: 100, actual: nil))
        XCTAssertTrue(BackupService.relatedSizeIsComplete(expected: 0, actual: 100))
        XCTAssertFalse(BackupService.relatedSizeIsComplete(expected: 0, actual: 0))
    }
    private func asset() -> PhotoAsset {
        PhotoAsset(id: "42-IMG_0001.HEIC", deviceID: "iphone-a", name: "IMG_0001.HEIC",
                   date: Date(timeIntervalSince1970: 1_700_000_000), bytes: 5,
                   kind: .photo, groupID: nil, width: 100, height: 100)
    }

    func testVerificationDetectsMissingAndChangedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("IMG_0001.HEIC")
        let bytes = Data("hello".utf8)
        try bytes.write(to: file)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let source = asset()
        let record = BackupRecord(sourceKey: source.sourceKey, relativePath: file.lastPathComponent,
                                  sha256: digest, bytes: 5, backedUpAt: .now, relatedFiles: [], deletionSafe: true)
        let manifest = BackupManifest(records: [source.sourceKey: record])
        let service = BackupService()
        XCTAssertEqual(service.verify(source, at: root, manifest: manifest), .verified)
        try Data("jello".utf8).write(to: file)
        XCTAssertEqual(service.verify(source, at: root, manifest: manifest), .changed)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(service.verify(source, at: root, manifest: manifest), .changed)
    }

    func testManifestCannotVerifyFileOutsideBackupFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = asset()
        let record = BackupRecord(sourceKey: source.sourceKey, relativePath: "../outside.HEIC",
                                  sha256: "", bytes: 0, backedUpAt: .now, relatedFiles: [], deletionSafe: true)
        XCTAssertEqual(BackupService().verify(source, at: root, manifest: BackupManifest(records: [source.sourceKey: record])), .changed)
    }

    func testSourceKeyIsDeviceSpecific() {
        let source = asset()
        let other = PhotoAsset(id: source.id, deviceID: "iphone-b", name: source.name, date: source.date,
                               bytes: source.bytes, kind: source.kind, groupID: source.groupID,
                               width: source.width, height: source.height)
        XCTAssertNotEqual(source.sourceKey, other.sourceKey)
    }

    func testRelatedFileMustExistAndConvertedCopyIsNotDeletionSafe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("still.HEIC")
        let video = root.appendingPathComponent("motion.MOV")
        let stillData = Data("still".utf8)
        let videoData = Data("video".utf8)
        try stillData.write(to: primary)
        try videoData.write(to: video)
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let source = asset()
        let sidecar = BackupFileRecord(relativePath: "motion.MOV", sha256: digest(videoData), bytes: 5)
        let record = BackupRecord(sourceKey: source.sourceKey, relativePath: "still.HEIC",
                                  sha256: digest(stillData), bytes: 5, backedUpAt: .now,
                                  relatedFiles: [sidecar], deletionSafe: true)
        let service = BackupService()
        XCTAssertEqual(service.verify(source, at: root, manifest: BackupManifest(records: [source.sourceKey: record])), .verified)
        try FileManager.default.removeItem(at: video)
        XCTAssertEqual(service.verify(source, at: root, manifest: BackupManifest(records: [source.sourceKey: record])), .changed)
        let converted = BackupRecord(sourceKey: source.sourceKey, relativePath: "still.HEIC",
                                     sha256: digest(stillData), bytes: 5, backedUpAt: .now,
                                     relatedFiles: [], deletionSafe: false)
        XCTAssertEqual(service.verify(source, at: root, manifest: BackupManifest(records: [source.sourceKey: converted])), .partial)
    }
}
