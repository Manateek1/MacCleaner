import Foundation
import XCTest
@testable import MacCleaner

final class ActivityTrendTests: XCTestCase {
    func testSevenDaySummaryGroupsRecordedActionsByCalendarDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-10-29T12:00:00Z")
        let entries = [
            entry("2026-10-22T18:00:00Z", .scan), // outside the seven-day window
            entry("2026-10-23T02:00:00Z", .scan),
            entry("2026-10-23T20:00:00Z", .scan),
            entry("2026-10-25T14:00:00Z", .cleanup),
            entry("2026-10-29T09:00:00Z", .updateCheck),
            entry("2026-10-29T09:30:00Z", .securityCheck),
            entry("2026-10-29T10:00:00Z", .other)
        ]

        let summary = ActivityTrendSummary.recent(entries: entries, endingAt: now, calendar: calendar)

        XCTAssertEqual(summary.periods.count, 7)
        XCTAssertEqual(summary.scanCount, 2)
        XCTAssertEqual(summary.cleanupCount, 1)
        XCTAssertEqual(summary.securityCheckCount, 1)
        XCTAssertEqual(summary.updateCheckCount, 1)
        XCTAssertEqual(summary.periods[0].scans, 2)
        XCTAssertEqual(summary.periods[2].cleanupActions, 1)
        XCTAssertEqual(summary.periods[6].updateChecks, 1)
        XCTAssertEqual(summary.periods[6].securityChecks, 1)
    }

    func testThirtyDaySummaryKeepsDailyPeriodsAndExcludesOlderEntries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-10-29T12:00:00Z")
        let entries = [
            entry("2026-09-28T12:00:00Z", .scan),
            entry("2026-09-30T12:00:00Z", .cleanup),
            entry("2026-10-29T09:00:00Z", .updateCheck),
            entry("2026-10-29T09:30:00Z", .securityCheck)
        ]

        let summary = ActivityTrendSummary.recent(entries: entries, endingAt: now, range: .thirtyDays, calendar: calendar)

        XCTAssertEqual(summary.periods.count, 30)
        XCTAssertEqual(summary.scanCount, 0)
        XCTAssertEqual(summary.cleanupCount, 1)
        XCTAssertEqual(summary.updateCheckCount, 1)
        XCTAssertEqual(summary.securityCheckCount, 1)
    }

    func testNinetyDaySummaryGroupsActionsIntoThirteenWeeklyPeriods() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-10-29T12:00:00Z")
        let entries = [
            entry("2026-08-01T12:00:00Z", .scan),
            entry("2026-10-28T12:00:00Z", .cleanup),
            entry("2026-10-28T13:00:00Z", .securityCheck),
            entry("2026-07-31T12:00:00Z", .updateCheck)
        ]

        let summary = ActivityTrendSummary.recent(entries: entries, endingAt: now, range: .ninetyDays, calendar: calendar)

        XCTAssertEqual(summary.periods.count, 13)
        XCTAssertEqual(summary.scanCount, 1)
        XCTAssertEqual(summary.cleanupCount, 1)
        XCTAssertEqual(summary.securityCheckCount, 1)
        XCTAssertEqual(summary.updateCheckCount, 0)
        XCTAssertEqual(summary.periods.last?.cleanupActions, 1)
        XCTAssertEqual(summary.periods.last?.securityChecks, 1)
    }

    @MainActor
    func testActivityHistoryRetainsAtMostFiveHundredNewestSummaries() throws {
        let suiteName = "MacCleanerActivityStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ActivityStore(defaults: defaults)

        for index in 0...ActivityStore.maximumEntries {
            store.record(title: "Action \(index)", files: 1, bytes: 1, note: "Local summary", kind: .scan)
        }

        XCTAssertEqual(store.entries.count, ActivityStore.maximumEntries)
        XCTAssertEqual(store.entries.first?.title, "Action \(ActivityStore.maximumEntries)")
        XCTAssertEqual(store.entries.last?.title, "Action 1")
    }

    func testOldActivityRecordsInferKnownKindsWithoutChangingTheirDetails() throws {
        let legacy = """
        [{"id":"00000000-0000-0000-0000-000000000001","date":1790000000,"title":"Similar Photos scan completed","filesReviewed":42,"bytesAffected":0,"note":"Local scan"},
         {"id":"00000000-0000-0000-0000-000000000002","date":1790000001,"title":"Application moved to Trash","filesReviewed":1,"bytesAffected":128,"note":"Confirmed"},
         {"id":"00000000-0000-0000-0000-000000000003","date":1790000002,"title":"Unrecognized historical record","filesReviewed":3,"bytesAffected":7,"note":"Kept in history"}]
        """.data(using: .utf8)!

        let entries = try JSONDecoder().decode([ActivityEntry].self, from: legacy)

        XCTAssertEqual(entries.map(\.kind), [.scan, .cleanup, .other])
        XCTAssertEqual(entries[0].filesReviewed, 42)
        XCTAssertEqual(entries[1].bytesAffected, 128)
        XCTAssertEqual(entries[2].note, "Kept in history")
    }

    func testActivityKindPersistsInNewRecords() throws {
        let original = entry("2026-10-29T11:00:00Z", .cleanup)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(ActivityEntry.self, from: data)

        XCTAssertEqual(restored.kind, .cleanup)
        XCTAssertEqual(restored.title, original.title)
        XCTAssertEqual(restored.itemCountLabel, "1 item")
    }

    func testOldActivityRecordsInferSecurityCheckKindFromItsTitle() throws {
        let oldRecord = """
        [{"id":"00000000-0000-0000-0000-000000000004","date":1790000003,"title":"App Security check completed","filesReviewed":12,"bytesAffected":0,"note":"Local summary"}]
        """.data(using: .utf8)!

        let entries = try JSONDecoder().decode([ActivityEntry].self, from: oldRecord)

        XCTAssertEqual(entries.first?.kind, .securityCheck)
    }

    func testActivityItemCountUsesPluralForMultipleItems() {
        let original = ActivityEntry(
            id: UUID(),
            date: .now,
            title: "Cleanup reviewed",
            filesReviewed: 2,
            bytesAffected: 0,
            note: "Synthetic test entry",
            kind: .cleanup
        )

        XCTAssertEqual(original.itemCountLabel, "2 items")
    }

    func testSecurityActivityCountUsesAppsInsteadOfGenericItems() {
        let original = ActivityEntry(
            id: UUID(),
            date: .now,
            title: "App Security check completed",
            filesReviewed: 42,
            bytesAffected: 0,
            note: "Aggregate summary",
            kind: .securityCheck
        )

        XCTAssertEqual(original.itemCountLabel, "42 apps checked")
    }

    private func entry(_ timestamp: String, _ kind: ActivityKind) -> ActivityEntry {
        ActivityEntry(
            id: UUID(),
            date: date(timestamp),
            title: "Test \(kind.rawValue)",
            filesReviewed: 1,
            bytesAffected: 1,
            note: "Synthetic test entry",
            kind: kind
        )
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)!
    }
}
