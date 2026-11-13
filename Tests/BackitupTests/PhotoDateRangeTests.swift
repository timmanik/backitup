import Foundation
import XCTest
@testable import Backitup

final class PhotoDateRangeTests: XCTestCase {
    func testFromAndThroughIncludeEntireBoundaryDays() {
        let calendar = Calendar.current
        func date(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2025, month: 10, day: day, hour: hour))!
        }
        let range = PhotoDateRange(from: date(25, 12), through: date(26, 8))

        XCTAssertFalse(range.contains(date(24, 23), calendar: calendar))
        XCTAssertTrue(range.contains(date(25, 0), calendar: calendar))
        XCTAssertTrue(range.contains(date(26, 23), calendar: calendar))
        XCTAssertFalse(range.contains(date(27, 0), calendar: calendar))
        XCTAssertFalse(range.contains(.distantPast, calendar: calendar))
    }

    func testOpenEndedAndClearedFilters() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(PhotoDateRange(from: start, through: nil).contains(start))
        XCTAssertTrue(PhotoDateRange(from: nil, through: nil).contains(.distantPast))
    }
}
