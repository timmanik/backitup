import Foundation
import XCTest
@testable import Backitup

final class CatalogCacheTests: XCTestCase {
    func testShrinkingCatalogPreservesLargestPreviousSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = (0..<3).map { index in
            PhotoAsset(id: "\(index)-IMG.HEIC", deviceID: "phone-a", name: "IMG.HEIC",
                       date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)), bytes: 123,
                       kind: .photo, groupID: nil, width: 100, height: 100)
        }
        let cache = CatalogCache(root: root)
        try cache.save(CachedCatalog(deviceID: "phone-a", deviceName: "My iPhone", savedAt: .now, assets: assets))
        try cache.save(CachedCatalog(deviceID: "phone-a", deviceName: "My iPhone", savedAt: .now, assets: [assets[0]]))
        let previous = try JSONDecoder().decode(CachedCatalog.self, from: Data(contentsOf: root.appendingPathComponent("catalog-previous.json")))
        XCTAssertEqual(previous.assets, assets)
        XCTAssertEqual(cache.loadLast()?.assets, [assets[0]])
    }

    func testCatalogAndThumbnailSurviveNewCacheInstance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = PhotoAsset(id: "17-IMG_0001.HEIC", deviceID: "phone-a", name: "IMG_0001.HEIC",
                               date: Date(timeIntervalSince1970: 1_700_000_000), bytes: 123,
                               kind: .photo, groupID: nil, width: 100, height: 100)
        let snapshot = CachedCatalog(deviceID: "phone-a", deviceName: "My iPhone", savedAt: .now, assets: [asset])
        let thumbnail = Data([0xFF, 0xD8, 0xFF])
        try CatalogCache(root: root).save(snapshot)
        try CatalogCache(root: root).saveThumbnail(thumbnail, for: asset)

        let reopened = CatalogCache(root: root)
        XCTAssertEqual(reopened.loadLast()?.assets, [asset])
        XCTAssertEqual(reopened.loadLast()?.deviceName, "My iPhone")
        XCTAssertEqual(reopened.thumbnail(for: asset), thumbnail)
    }
}
