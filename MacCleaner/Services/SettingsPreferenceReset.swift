import Foundation

struct SettingsPreferenceReset {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func restoreDefaults() {
        defaults.set(500.0, forKey: "MacCleaner.minimumSizeMB")
        defaults.set(180, forKey: "MacCleaner.oldAgeDays")
        defaults.set(SimilarPhotosPreference.defaultValue, forKey: SimilarPhotosPreference.storageKey)
        defaults.set(DuplicateKeepPreference.oldest.rawValue, forKey: DuplicateKeepPreference.storageKey)
        defaults.set("smartScan,largeFiles,similarPhotos", forKey: "MacCleaner.favoriteToolSections")
        defaults.set(MacCleanerAppearancePreference.defaultValue.rawValue, forKey: MacCleanerAppearancePreference.storageKey)
        defaults.set(true, forKey: MenuBarPreferenceKey.cpu)
        defaults.set(true, forKey: MenuBarPreferenceKey.memory)
        defaults.set(true, forKey: MenuBarPreferenceKey.storage)
        defaults.set(true, forKey: MenuBarPreferenceKey.battery)
        defaults.set(false, forKey: MenuBarPreferenceKey.network)
        defaults.set(false, forKey: MenuBarPreferenceKey.uptime)
        defaults.set(ProcessActivityDisplayLimit.defaultValue.rawValue, forKey: ProcessActivityDisplayLimit.storageKey)
        defaults.set(false, forKey: ActivityNotificationKind.scanCompleted.preferenceKey)
        defaults.set(false, forKey: ActivityNotificationKind.cleanupCompleted.preferenceKey)
        defaults.set(false, forKey: ActivityNotificationKind.appUpdateSourceCheckCompleted.preferenceKey)
        defaults.set(false, forKey: ActivityNotificationKind.appSecurityCheckCompleted.preferenceKey)
        defaults.set(false, forKey: ActivityNotificationKind.macHealthCheckCompleted.preferenceKey)
    }
}
