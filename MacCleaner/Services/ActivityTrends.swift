import Foundation

enum ActivityTrendRange: String, CaseIterable, Equatable, Identifiable, Sendable {
    case sevenDays
    case thirtyDays
    case ninetyDays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sevenDays: "Last 7 days"
        case .thirtyDays: "Last 30 days"
        case .ninetyDays: "Last 90 days"
        }
    }

    var dayCount: Int {
        switch self {
        case .sevenDays: 7
        case .thirtyDays: 30
        case .ninetyDays: 90
        }
    }

    var usesWeeklyBuckets: Bool { self == .ninetyDays }

    var periodCount: Int {
        usesWeeklyBuckets ? (dayCount + 6) / 7 : dayCount
    }
}

struct ActivityTrendPeriod: Identifiable, Equatable, Sendable {
    let date: Date
    var scans = 0
    var cleanupActions = 0
    var updateChecks = 0
    var securityChecks = 0

    var id: Date { date }
}

struct ActivityTrendSummary: Equatable, Sendable {
    let periods: [ActivityTrendPeriod]

    var scanCount: Int { periods.reduce(0) { $0 + $1.scans } }
    var cleanupCount: Int { periods.reduce(0) { $0 + $1.cleanupActions } }
    var updateCheckCount: Int { periods.reduce(0) { $0 + $1.updateChecks } }
    var securityCheckCount: Int { periods.reduce(0) { $0 + $1.securityChecks } }

    static func recent(
        entries: [ActivityEntry],
        endingAt now: Date = .now,
        range: ActivityTrendRange = .sevenDays,
        calendar: Calendar = .current
    ) -> ActivityTrendSummary {
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -(range.dayCount - 1), to: today) ?? today
        var periods = (0..<range.periodCount).compactMap { offset -> ActivityTrendPeriod? in
            let dayOffset = range.usesWeeklyBuckets ? offset * 7 : offset
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: firstDay) else { return nil }
            return ActivityTrendPeriod(date: date)
        }

        for entry in entries {
            let date = calendar.startOfDay(for: entry.date)
            guard let dayOffset = calendar.dateComponents([.day], from: firstDay, to: date).day,
                  (0..<range.dayCount).contains(dayOffset) else { continue }
            let periodIndex = range.usesWeeklyBuckets ? dayOffset / 7 : dayOffset
            guard periods.indices.contains(periodIndex) else { continue }
            switch entry.kind {
            case .scan:
                periods[periodIndex].scans += 1
            case .cleanup:
                periods[periodIndex].cleanupActions += 1
            case .updateCheck:
                periods[periodIndex].updateChecks += 1
            case .securityCheck:
                periods[periodIndex].securityChecks += 1
            case .other:
                break
            }
        }

        return ActivityTrendSummary(periods: periods)
    }
}
