import Foundation
import XCTest
@testable import MacCleaner

final class ApplicationVersionObservationTrackerTests: XCTestCase {
    func testFirstScanCreatesBaselineWithoutClaimingAnUpdate() {
        let history = ApplicationVersionObservationTracker.record(
            current: ["/Applications/Example.app": snapshot(version: "1.0", build: "10")],
            previous: [:],
            observedAt: date("2026-10-31T12:00:00Z")
        )

        XCTAssertNil(history["/Applications/Example.app"]?.latestChange)
        XCTAssertEqual(history["/Applications/Example.app"]?.lastObserved.version, "1.0")
    }

    func testLaterScanRecordsVersionAndBuildChangeForThatAppPath() throws {
        let path = "/Applications/Example.app"
        let priorDate = date("2026-10-30T12:00:00Z")
        let currentDate = date("2026-10-31T12:00:00Z")
        let baseline = ApplicationVersionObservationTracker.record(
            current: [path: snapshot(version: "1.0", build: "10")],
            previous: [:],
            observedAt: priorDate
        )

        let updated = ApplicationVersionObservationTracker.record(
            current: [path: snapshot(version: "1.1", build: "11")],
            previous: baseline,
            observedAt: currentDate
        )

        let change = try XCTUnwrap(updated[path]?.latestChange)
        XCTAssertEqual(change.previous.version, "1.0")
        XCTAssertEqual(change.current.version, "1.1")
        XCTAssertEqual(change.previous.buildVersion, "10")
        XCTAssertEqual(change.current.buildVersion, "11")
        XCTAssertEqual(change.observedAt, currentDate)
        XCTAssertTrue(change.summary.contains("can't tell which updater"))
    }

    func testNonnumericChangesUseExactTextAndNumericEquivalentVersionsStayUnchanged() {
        XCTAssertTrue(ApplicationVersionObservationTracker.valuesDiffer("2026.10-beta", "2026.11-beta"))
        XCTAssertFalse(ApplicationVersionObservationTracker.valuesDiffer("1.2", "1.2.0"))
        XCTAssertFalse(ApplicationVersionObservationTracker.valuesDiffer(nil, "3"))
    }

    func testHistoryIsIsolatedByApplicationPathAndKeepsLatestChange() {
        let now = date("2026-10-31T12:00:00Z")
        let firstPath = "/Applications/Example.app"
        let secondPath = "/Users/test/Applications/Example.app"
        let baseline = ApplicationVersionObservationTracker.record(
            current: [
                firstPath: snapshot(version: "1.0", build: "10"),
                secondPath: snapshot(version: "2.0", build: "20")
            ],
            previous: [:],
            observedAt: now
        )
        let changed = ApplicationVersionObservationTracker.record(
            current: [
                firstPath: snapshot(version: "1.1", build: "11"),
                secondPath: snapshot(version: "2.0", build: "20")
            ],
            previous: baseline,
            observedAt: now.addingTimeInterval(60)
        )
        let unchanged = ApplicationVersionObservationTracker.record(
            current: [
                firstPath: snapshot(version: "1.1", build: "11"),
                secondPath: snapshot(version: "2.0", build: "20")
            ],
            previous: changed,
            observedAt: now.addingTimeInterval(120)
        )

        XCTAssertNotNil(unchanged[firstPath]?.latestChange)
        XCTAssertNil(unchanged[secondPath]?.latestChange)
    }

    func testOldMissingAppsExpireAndHistoryIsBounded() {
        let now = date("2026-10-31T12:00:00Z")
        let expiredDate = now.addingTimeInterval(-ApplicationVersionObservationTracker.retentionInterval - 1)
        let retainedDate = now.addingTimeInterval(-ApplicationVersionObservationTracker.retentionInterval + 1)
        let previous: [String: InstalledAppVersionHistoryEntry] = [
            "/Applications/Expired.app": .init(lastObserved: snapshot(version: "1", build: nil), lastObservedAt: expiredDate, latestChange: nil),
            "/Applications/Recent.app": .init(lastObserved: snapshot(version: "1", build: nil), lastObservedAt: retainedDate, latestChange: nil)
        ]

        let retained = ApplicationVersionObservationTracker.record(current: [:], previous: previous, observedAt: now)
        XCTAssertNil(retained["/Applications/Expired.app"])
        XCTAssertNotNil(retained["/Applications/Recent.app"])

        let oversized = Dictionary(uniqueKeysWithValues: (0...ApplicationVersionObservationTracker.maximumEntries).map { index in
            ("/Applications/\(index).app", InstalledAppVersionHistoryEntry(
                lastObserved: snapshot(version: "1", build: nil),
                lastObservedAt: now.addingTimeInterval(TimeInterval(index)),
                latestChange: nil
            ))
        })
        let bounded = ApplicationVersionObservationTracker.record(current: oversized.mapValues(\.lastObserved), previous: oversized, observedAt: now)
        XCTAssertEqual(bounded.count, ApplicationVersionObservationTracker.maximumEntries)
    }

    private func snapshot(version: String?, build: String?) -> InstalledAppVersionSnapshot {
        InstalledAppVersionSnapshot(name: "Example", version: version, buildVersion: build)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
