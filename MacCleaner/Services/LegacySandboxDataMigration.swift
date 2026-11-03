import Darwin
import Foundation

struct LegacySandboxDataMigration {
    static let completedKey = "MacCleaner.legacySandboxMigrationCompleted"

    private let legacyPreferencesURL: URL
    private let defaults: UserDefaults

    init(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        defaults: UserDefaults = .standard
    ) {
        legacyPreferencesURL = homeDirectory
            .appendingPathComponent("Library/Containers/com.manateek1.MacCleaner/Data/Library/Preferences", isDirectory: true)
            .appendingPathComponent("com.manateek1.MacCleaner.plist")
        self.defaults = defaults
    }

    func migrate() {
        guard !defaults.bool(forKey: Self.completedKey) else { return }
        var info = Darwin.stat()
        let result = legacyPreferencesURL.path.withCString { Darwin.lstat($0, &info) }
        guard result == 0 else {
            if errno == ENOENT || errno == ENOTDIR { markCompleted() }
            return
        }
        guard let data = try? Data(contentsOf: legacyPreferencesURL),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }

        for (key, value) in values where key != "MacCleaner.diskBookmark" && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        markCompleted()
    }

    private func markCompleted() {
        defaults.set(true, forKey: Self.completedKey)
        defaults.synchronize()
    }
}
