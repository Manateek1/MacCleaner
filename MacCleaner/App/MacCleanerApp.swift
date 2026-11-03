import SwiftUI

@main
struct MacCleanerApp: App {
    @StateObject private var model: ScanViewModel
    @StateObject private var systemMonitor: SystemMonitor
    @StateObject private var navigation: AppNavigationModel
    @AppStorage(MacCleanerAppearancePreference.storageKey)
    private var appearance: String?

    init() {
        LegacySandboxDataMigration().migrate()
        _model = StateObject(wrappedValue: ScanViewModel())
        _systemMonitor = StateObject(wrappedValue: SystemMonitor())
        _navigation = StateObject(wrappedValue: AppNavigationModel())
        _appearance = AppStorage(MacCleanerAppearancePreference.storageKey)
    }

    private var preferredColorScheme: ColorScheme? {
        MacCleanerAppearancePreference.resolve(appearance ?? MacCleanerAppearancePreference.defaultValue.rawValue).colorScheme
    }

    var body: some Scene {
        WindowGroup("Mac Cleaner", id: "main") {
            RootView(model: model, monitor: systemMonitor, navigation: navigation)
                .frame(minWidth: 980, minHeight: 680)
                .tint(MacCleanerTheme.accent)
                .preferredColorScheme(preferredColorScheme)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu("Navigate") {
                ForEach(AppSection.navigationShortcutSections) { section in
                    if let key = section.navigationShortcutKey {
                        Button(section.title) {
                            navigation.selectedSection = section
                        }
                        .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
                    }
                }
            }
        }

        MenuBarExtra("Mac Cleaner", systemImage: "gauge.with.dots.needle.67percent") {
            SystemMonitorMenuView(monitor: systemMonitor)
                .tint(MacCleanerTheme.accent)
                .preferredColorScheme(preferredColorScheme)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(width: 560, height: 460)
                .tint(MacCleanerTheme.accent)
                .preferredColorScheme(preferredColorScheme)
        }
    }
}
