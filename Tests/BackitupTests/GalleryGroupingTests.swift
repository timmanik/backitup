import Foundation
import XCTest
@testable import Backitup

final class GalleryGroupingTests: XCTestCase {
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
    }
}
