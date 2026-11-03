import SwiftUI
import XCTest
@testable import MacCleaner

final class MacCleanerAppearancePreferenceTests: XCTestCase {
    func testAppearanceOptionsMapToExpectedColorSchemes() {
        XCTAssertNil(MacCleanerAppearancePreference.system.colorScheme)
        XCTAssertEqual(MacCleanerAppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(MacCleanerAppearancePreference.dark.colorScheme, .dark)
    }

    func testUnknownSavedValueFallsBackToLight() {
        XCTAssertEqual(MacCleanerAppearancePreference.resolve("unexpected"), .light)
        XCTAssertEqual(MacCleanerAppearancePreference.resolve("dark"), .dark)
    }

    func testSettingsExposeAllThreeAppearanceChoices() {
        XCTAssertEqual(MacCleanerAppearancePreference.allCases.map(\.rawValue), ["system", "light", "dark"])
    }
}
