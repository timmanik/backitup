import Foundation
import XCTest
@testable import Backitup

final class GalleryGroupingTests: XCTestCase {
    func testVerifiedSelectionMatchesEachExpandedDeletionGroup() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let assets = (0..<120).map { i in
            PhotoAsset(id: "\(i)", deviceID: "phone", name: i.isMultiple(of: 2) ? "FullSizeRender.jpg" : "IMG_\(i).JPG",
                       date: date, bytes: 1, kind: .photo, groupID: "group-\(i / 2)", width: 1, height: 1)
        }
        let gallery = DeviceLibrary.groupedGallery(assets)
        let selected = Set(gallery.map(\.id))
        let states = Dictionary(uniqueKeysWithValues: assets.enumerated().map { (index, asset) in
            (asset.id, index.isMultiple(of: 7) ? BackupState.missing : .verified)
        })
        let expected = Set(selected.filter { id in
            DeviceLibrary.allTargetsVerified(DeviceLibrary.deletionTargetIDs(for: [id], assets: assets, galleryAssets: gallery), states: states)
        })
        XCTAssertEqual(DeviceLibrary.verifiedGalleryIDs(selected, assets: assets, galleryAssets: gallery, states: states), expected)
    }
    func testEditedOriginalAppearsAsOneGalleryItem() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let edited = PhotoAsset(id: "1", deviceID: "phone", name: "FullSizeRender.heic",
                                date: date, bytes: 100, kind: .photo, groupID: "pair",
                                width: 100, height: 100)
        let original = PhotoAsset(id: "2", deviceID: "phone", name: "IMG_1234.HEIC",
                                  date: date, bytes: 120, kind: .photo, groupID: "pair",
                                  width: 100, height: 100)
        let unrelated = PhotoAsset(id: "3", deviceID: "phone", name: "IMG_5678.HEIC",
                                   date: date, bytes: 80, kind: .photo, groupID: "other",
                                   width: 100, height: 100)
        XCTAssertEqual(DeviceLibrary.groupedGallery([edited, original, unrelated]).map(\.id), ["1", "3"])
        XCTAssertEqual(DeviceLibrary.deletionTargetIDs(for: ["1"], assets: [edited, original, unrelated],
                                                       galleryAssets: [edited, unrelated]), ["1", "2"])
        let targets: Set<String> = ["1", "2"]
        XCTAssertFalse(DeviceLibrary.allTargetsVerified(targets, states: ["1": .verified]))
        XCTAssertFalse(DeviceLibrary.allTargetsVerified(targets, states: ["1": .verified, "2": .changed]))
        XCTAssertTrue(DeviceLibrary.allTargetsVerified(targets, states: ["1": .verified, "2": .verified]))
        let selected: Set<String> = ["1", "3"]
        XCTAssertEqual(DeviceLibrary.verifiedGalleryIDs(selected, assets: [edited, original, unrelated],
                                                       galleryAssets: [edited, unrelated],
                                                       states: ["1": .verified, "2": .missing, "3": .verified]), ["3"])
        XCTAssertEqual(DeviceLibrary.verifiedGalleryIDs(selected, assets: [edited, original, unrelated],
                                                       galleryAssets: [edited, unrelated],
                                                       states: ["1": .verified, "2": .verified, "3": .verified]), selected)
    }
}
