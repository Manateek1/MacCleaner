import Foundation
import XCTest
@testable import MacCleaner

final class LegacySandboxDataMigrationTests: XCTestCase {
    func testMigratesMissingPreferenceValuesWithoutOverwritingNewValues() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyPreferences = root
            .appendingPathComponent("Library/Containers/com.manateek1.MacCleaner/Data/Library/Preferences", isDirectory: true)
            .appendingPathComponent("com.manateek1.MacCleaner.plist")
        try FileManager.default.createDirectory(at: legacyPreferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldValues: [String: Any] = [
            "MacCleaner.minimumSizeMB": 750,
            "MacCleaner.scanNoticeAcceptedVersion": 3,
            "MacCleaner.activity.v1": Data("prior activity".utf8),
            "MacCleaner.diskBookmark": Data("obsolete root scope".utf8)
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: oldValues, format: .binary, options: 0)
        try data.write(to: legacyPreferences)

        let suiteName = "MacCleanerTests.LegacyMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(250, forKey: "MacCleaner.minimumSizeMB")
        LegacySandboxDataMigration(homeDirectory: root, defaults: defaults).migrate()

        XCTAssertEqual(defaults.integer(forKey: "MacCleaner.minimumSizeMB"), 250)
        XCTAssertEqual(defaults.integer(forKey: "MacCleaner.scanNoticeAcceptedVersion"), 3)
        XCTAssertEqual(defaults.data(forKey: "MacCleaner.activity.v1"), Data("prior activity".utf8))
        XCTAssertNil(defaults.data(forKey: "MacCleaner.diskBookmark"))
        XCTAssertTrue(defaults.bool(forKey: LegacySandboxDataMigration.completedKey))
    }

    func testMigrationWithoutLegacyPreferencesIsSafe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "MacCleanerTests.LegacyMigrationMissing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        LegacySandboxDataMigration(homeDirectory: root, defaults: defaults).migrate()

        XCTAssertTrue(defaults.bool(forKey: LegacySandboxDataMigration.completedKey))
    }
}
