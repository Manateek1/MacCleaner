import Foundation

struct InstalledAppVersionSnapshot: Codable, Equatable, Sendable {
    let name: String
    let version: String?
    let buildVersion: String?

    init(name: String, version: String?, buildVersion: String?) {
        self.name = name
        self.version = Self.normalized(version)
        self.buildVersion = Self.normalized(buildVersion)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct InstalledAppVersionChange: Codable, Equatable, Sendable {
    let previous: InstalledAppVersionSnapshot
    let current: InstalledAppVersionSnapshot
    let observedAt: Date

    var summary: String {
        var details: [String] = []
        if ApplicationVersionObservationTracker.valuesDiffer(previous.version, current.version),
           let oldVersion = previous.version, let newVersion = current.version {
            details.append("Version \(oldVersion) → \(newVersion)")
        }
        if ApplicationVersionObservationTracker.valuesDiffer(previous.buildVersion, current.buildVersion),
           let oldBuild = previous.buildVersion, let newBuild = current.buildVersion {
            details.append("build \(oldBuild) → \(newBuild)")
        }
        return "Observed since the prior scan: \(details.joined(separator: "; ")). Mac Cleaner can't tell which updater made the change."
    }
}

struct InstalledAppVersionHistoryEntry: Codable, Equatable, Sendable {
    let lastObserved: InstalledAppVersionSnapshot
    let lastObservedAt: Date
    let latestChange: InstalledAppVersionChange?
}

enum ApplicationVersionObservationTracker {
    static let maximumEntries = 1_000
    static let retentionInterval: TimeInterval = 90 * 24 * 60 * 60

    static func record(
        current: [String: InstalledAppVersionSnapshot],
        previous: [String: InstalledAppVersionHistoryEntry],
        observedAt: Date
    ) -> [String: InstalledAppVersionHistoryEntry] {
        let cutoff = observedAt.addingTimeInterval(-retentionInterval)
        var result: [String: InstalledAppVersionHistoryEntry] = [:]

        for (path, snapshot) in current {
            let prior = previous[path]
            let effectiveDate = max(observedAt, prior?.lastObservedAt ?? observedAt)
            let latestChange: InstalledAppVersionChange?

            if let prior,
               valuesDiffer(prior.lastObserved.version, snapshot.version)
                || valuesDiffer(prior.lastObserved.buildVersion, snapshot.buildVersion) {
                latestChange = InstalledAppVersionChange(
                    previous: prior.lastObserved,
                    current: snapshot,
                    observedAt: effectiveDate
                )
            } else {
                latestChange = prior?.latestChange
            }

            result[path] = InstalledAppVersionHistoryEntry(
                lastObserved: snapshot,
                lastObservedAt: effectiveDate,
                latestChange: latestChange
            )
        }

        for (path, entry) in previous where current[path] == nil && entry.lastObservedAt >= cutoff {
            result[path] = entry
        }

        if result.count > maximumEntries {
            let retained = result.sorted { lhs, rhs in
                if lhs.value.lastObservedAt != rhs.value.lastObservedAt {
                    return lhs.value.lastObservedAt > rhs.value.lastObservedAt
                }
                return lhs.key < rhs.key
            }.prefix(maximumEntries)
            return Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        }
        return result
    }

    static func valuesDiffer(_ previous: String?, _ current: String?) -> Bool {
        guard let previous, let current else { return false }
        if let comparison = ApplicationUpdaterService.compareVersions(previous, current) {
            return comparison != 0
        }
        return previous != current
    }
}
