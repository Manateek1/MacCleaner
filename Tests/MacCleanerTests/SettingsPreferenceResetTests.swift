import XCTest
@testable import MacCleaner

final class SettingsPreferenceResetTests: XCTestCase {
    func testRestoresPreferencesAndPreservesAccessAndUserData() throws {
        let suiteName = "MacCleanerSettingsResetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(1_250.0, forKey: "MacCleaner.minimumSizeMB")
        defaults.set(365, forKey: "MacCleaner.oldAgeDays")
        defaults.set(11.0, forKey: SimilarPhotosPreference.storageKey)
        defaults.set(DuplicateKeepPreference.newest.rawValue, forKey: DuplicateKeepPreference.storageKey)
        defaults.set("permissions", forKey: "MacCleaner.favoriteToolSections")
        defaults.set("dark", forKey: MacCleanerAppearancePreference.storageKey)
        defaults.set(false, forKey: MenuBarPreferenceKey.cpu)
        defaults.set(true, forKey: MenuBarPreferenceKey.network)
        defaults.set(true, forKey: ActivityNotificationKind.scanCompleted.preferenceKey)
        defaults.set(true, forKey: ActivityNotificationKind.cleanupCompleted.preferenceKey)
        defaults.set(true, forKey: ActivityNotificationKind.appUpdateSourceCheckCompleted.preferenceKey)
        defaults.set(true, forKey: ActivityNotificationKind.appSecurityCheckCompleted.preferenceKey)
        defaults.set(true, forKey: ActivityNotificationKind.macHealthCheckCompleted.preferenceKey)
        defaults.set(ProcessActivityDisplayLimit.twelve.rawValue, forKey: ProcessActivityDisplayLimit.storageKey)

        let diskBookmark = Data("saved disk access".utf8)
        let savedFolders = ["/Users/example/Documents": "bookmark-data"]
        let scanExclusions = ["/Users/example/Private"]
        let activityHistory = Data("local history".utf8)
        defaults.set(diskBookmark, forKey: "MacCleaner.diskBookmark")
        defaults.set(savedFolders, forKey: "MacCleaner.savedScanFolders.v1")
        defaults.set(scanExclusions, forKey: "MacCleaner.scanExclusions.v1")
        defaults.set(activityHistory, forKey: "MacCleaner.activity.v1")

        SettingsPreferenceReset(defaults: defaults).restoreDefaults()

        XCTAssertEqual(defaults.double(forKey: "MacCleaner.minimumSizeMB"), 500)
        XCTAssertEqual(defaults.integer(forKey: "MacCleaner.oldAgeDays"), 180)
        XCTAssertEqual(defaults.double(forKey: SimilarPhotosPreference.storageKey), SimilarPhotosPreference.defaultValue)
        XCTAssertEqual(defaults.string(forKey: DuplicateKeepPreference.storageKey), DuplicateKeepPreference.oldest.rawValue)
        XCTAssertEqual(defaults.string(forKey: "MacCleaner.favoriteToolSections"), "smartScan,largeFiles,similarPhotos")
        XCTAssertEqual(defaults.string(forKey: MacCleanerAppearancePreference.storageKey), "light")
        XCTAssertTrue(defaults.bool(forKey: MenuBarPreferenceKey.cpu))
        XCTAssertFalse(defaults.bool(forKey: MenuBarPreferenceKey.network))
        XCTAssertFalse(defaults.bool(forKey: ActivityNotificationKind.scanCompleted.preferenceKey))
        XCTAssertFalse(defaults.bool(forKey: ActivityNotificationKind.cleanupCompleted.preferenceKey))
        XCTAssertFalse(defaults.bool(forKey: ActivityNotificationKind.appUpdateSourceCheckCompleted.preferenceKey))
        XCTAssertFalse(defaults.bool(forKey: ActivityNotificationKind.appSecurityCheckCompleted.preferenceKey))
        XCTAssertFalse(defaults.bool(forKey: ActivityNotificationKind.macHealthCheckCompleted.preferenceKey))
        XCTAssertEqual(defaults.integer(forKey: ProcessActivityDisplayLimit.storageKey), ProcessActivityDisplayLimit.defaultValue.rawValue)
        XCTAssertEqual(defaults.data(forKey: "MacCleaner.diskBookmark"), diskBookmark)
        XCTAssertEqual(defaults.dictionary(forKey: "MacCleaner.savedScanFolders.v1") as? [String: String], savedFolders)
        XCTAssertEqual(defaults.stringArray(forKey: "MacCleaner.scanExclusions.v1"), scanExclusions)
        XCTAssertEqual(defaults.data(forKey: "MacCleaner.activity.v1"), activityHistory)
    }
}
