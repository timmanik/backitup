import Foundation

struct PhotoDateRange {
    var from: Date?
    var through: Date?

    var isActive: Bool { from != nil || through != nil }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        if !isActive { return true }
        if date == .distantPast { return false }

        let day = calendar.startOfDay(for: date)
        if let from, day < calendar.startOfDay(for: from) { return false }
        if let through, day > calendar.startOfDay(for: through) { return false }
        return true
    }
}
