import SwiftUI

enum MacCleanerAppearancePreference: String, CaseIterable, Equatable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "MacCleaner.appearance"
    static let defaultValue = Self.light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static func resolve(_ rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? defaultValue
    }
}
