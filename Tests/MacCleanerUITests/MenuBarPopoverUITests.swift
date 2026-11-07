import XCTest

final class MenuBarPopoverUITests: XCTestCase {
    @MainActor
    func testSidebarNavigationOpensEveryPrimarySection() {
        let app = XCUIApplication(bundleIdentifier: "com.manateek1.MacCleaner")
        app.launchArguments += ["-MacCleaner.scanNoticeAcceptedVersion", "4"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "The main window should be available for navigation.")
        let sidebar = app.outlines["sidebar-navigation"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "The sidebar should be available for navigation.")

        let sections = [
            "overview",
            "smartScan",
            "largeFiles",
            "duplicates",
            "similarPhotos",
            "junk",
            "aiClutter",
            "localModels",
            "privacyCleanup",
            "spaceLens",
            "deviceBackups",
            "performance",
            "maintenance",
            "applications",
            "appUpdates",
            "appSecurity",
            "appLeftovers",
            "startup",
            "tools",
            "permissions",
            "activity",
            "settings"
        ]

        for section in sections {
            let sidebarButton = app.buttons["sidebar-section-\(section)"]
            for _ in 0..<12 {
                if sidebarButton.exists && sidebarButton.isHittable {
                    break
                }
                sidebar.scroll(byDeltaX: 0, deltaY: -80)
            }
            XCTAssertTrue(sidebarButton.exists, "The \(section) sidebar button should exist.")
            if !sidebarButton.isHittable { print(app.debugDescription) }
            XCTAssertTrue(sidebarButton.isHittable, "The \(section) sidebar button should be reachable by scrolling.")
            sidebarButton.click()

            let content = app.descendants(matching: .any)
                .matching(identifier: "section-content-\(section)")
                .firstMatch
            XCTAssertTrue(content.waitForExistence(timeout: 5), "The \(section) screen should open.")
        }
    }

    @MainActor
    func testStatusItemOpensVisibleSystemMonitorPanel() {
        let app = XCUIApplication(bundleIdentifier: "com.manateek1.MacCleaner")
        app.launch()

        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10), "Mac Cleaner should show its menu bar icon.")
        statusItem.click()

        let title = app.staticTexts["System Monitor"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Clicking the menu bar icon should open the system monitor panel.")
        XCTAssertTrue(title.isHittable, "The system monitor title should be visible in the opened panel.")
        XCTAssertTrue(app.staticTexts["CPU"].exists, "The panel should show a live CPU card instead of an empty strip.")
        XCTAssertTrue(app.staticTexts["Storage"].exists, "The panel should show storage information without scrolling.")
    }

    @MainActor
    func testCommandEightOpensPrivacyPermissions() {
        let app = XCUIApplication(bundleIdentifier: "com.manateek1.MacCleaner")
        app.launchArguments += ["-MacCleaner.scanNoticeAcceptedVersion", "4"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "The main window should be available for keyboard navigation.")
        window.typeKey("8", modifierFlags: .command)

        let content = app.descendants(matching: .any)
            .matching(identifier: "section-content-permissions")
            .firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 5), "Command-8 should open Privacy & Permissions.")
    }
}
