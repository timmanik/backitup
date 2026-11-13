import Foundation

struct PhotoDayGroup: Identifiable {
    let day: Date
    let assets: [PhotoAsset]

    var id: Date { day }
    var title: String {
        day == .distantPast ? "Unknown date" : day.formatted(.dateTime.month(.wide).day().year())
    }

    static func make(from assets: [PhotoAsset], newestFirst: Bool = true,
                     calendar: Calendar = .current) -> [PhotoDayGroup] {
        let byDay = Dictionary(grouping: assets) { asset in
            asset.date == .distantPast ? Date.distantPast : calendar.startOfDay(for: asset.date)
        }
        return byDay.keys.sorted { left, right in
            if left == .distantPast { return false }
            if right == .distantPast { return true }
            return newestFirst ? left > right : left < right
        }.map { day in
            PhotoDayGroup(day: day, assets: byDay[day] ?? [])
        }
    }
}
