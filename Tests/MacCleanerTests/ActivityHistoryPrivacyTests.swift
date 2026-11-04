import XCTest
@testable import MacCleaner

@MainActor
final class ActivityHistoryPrivacyTests: XCTestCase {
    func testDisabledRecordingKeepsExistingHistoryAndDoesNotPersistNewEntries() {
        let name = "ActivityHistoryPrivacyTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ActivityStore(defaults: defaults)
        store.record(title: "Before", files: 1, bytes: 2, note: "Summary")
        defaults.set(false, forKey: ActivityStore.recordingPreferenceKey)
        store.record(title: "After", files: 3, bytes: 4, note: "Summary")
        XCTAssertEqual(store.entries.map(\.title), ["Before"])
        XCTAssertEqual(ActivityStore(defaults: defaults).entries.map(\.title), ["Before"])
    }

    func testRecordingCanBeEnabledAgain() {
        let name = "ActivityHistoryPrivacyTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: ActivityStore.recordingPreferenceKey)
        let store = ActivityStore(defaults: defaults)
        store.record(title: "Skipped", files: 0, bytes: 0, note: "")
        defaults.set(true, forKey: ActivityStore.recordingPreferenceKey)
        store.record(title: "Saved", files: 0, bytes: 0, note: "")
        XCTAssertEqual(store.entries.map(\.title), ["Saved"])
    }

    func testClearingHistoryPreservesRecordingChoiceAndOtherPreferences() {
        let name = "ActivityHistoryPrivacyTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ActivityStore(defaults: defaults)
        store.record(title: "Saved", files: 0, bytes: 0, note: "")
        defaults.set(false, forKey: ActivityStore.recordingPreferenceKey)
        defaults.set("unchanged", forKey: "other")
        store.clearHistory()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(ActivityStore(defaults: defaults).entries.isEmpty)
        XCTAssertFalse(store.isRecordingEnabled)
        XCTAssertEqual(defaults.string(forKey: "other"), "unchanged")
    }
}
