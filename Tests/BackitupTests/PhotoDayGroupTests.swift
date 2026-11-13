import Foundation
import XCTest
@testable import Backitup

final class PhotoDayGroupTests: XCTestCase {
    func testGroupsByCalendarDayInNewestFirstOrder() {
        let calendar = Calendar.current

        func asset(_ id: String, _ day: Int, _ hour: Int) -> PhotoAsset {
            let date = calendar.date(from: DateComponents(year: 2025, month: 10, day: day, hour: hour))!
            return PhotoAsset(id: id, deviceID: "phone", name: "IMG_\(id).HEIC",
                              date: date, bytes: 100, kind: .photo, groupID: nil,
                              width: 100, height: 100)
        }

        let groups = PhotoDayGroup.make(from: [asset("1", 25, 12), asset("2", 26, 18),
                                              asset("3", 26, 9)], calendar: calendar)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.assets.count), [2, 1])
        XCTAssertEqual(groups[0].assets.map(\.id), ["2", "3"])
        XCTAssertEqual(groups[0].title, "October 26, 2025")
    }

    func testUnknownDatesAppearLast() {
        let known = PhotoAsset(id: "known", deviceID: "phone", name: "IMG_1.HEIC",
                               date: Date(timeIntervalSince1970: 1_700_000_000), bytes: 100,
                               kind: .photo, groupID: nil, width: 100, height: 100)
        let unknown = PhotoAsset(id: "unknown", deviceID: "phone", name: "IMG_2.HEIC",
                                 date: .distantPast, bytes: 100, kind: .photo,
                                 groupID: nil, width: 100, height: 100)

        let groups = PhotoDayGroup.make(from: [unknown, known])

        XCTAssertEqual(groups.map(\.assets.first?.id), ["known", "unknown"])
        XCTAssertEqual(groups.last?.title, "Unknown date")
    }

    func testOldestFirstOrdersDaysAndKeepsUnknownLast() {
        let early = PhotoAsset(id: "early", deviceID: "phone", name: "1.heic",
                               date: Date(timeIntervalSince1970: 1_700_000_000), bytes: 1,
                               kind: .photo, groupID: nil, width: 1, height: 1)
        let late = PhotoAsset(id: "late", deviceID: "phone", name: "2.heic",
                              date: Date(timeIntervalSince1970: 1_800_000_000), bytes: 1,
                              kind: .photo, groupID: nil, width: 1, height: 1)
        let unknown = PhotoAsset(id: "unknown", deviceID: "phone", name: "3.heic",
                                 date: .distantPast, bytes: 1, kind: .photo,
                                 groupID: nil, width: 1, height: 1)

        let groups = PhotoDayGroup.make(from: [late, unknown, early], newestFirst: false)

        XCTAssertEqual(groups.compactMap { $0.assets.first?.id }, ["early", "late", "unknown"])
    }
}
