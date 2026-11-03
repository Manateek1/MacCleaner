import XCTest

final class MenuBarPopoverUITests: XCTestCase {
    @MainActor
    func testSidebarNavigationOpensEveryPrimarySection() {
        let app = XCUIApplication(bundleIdentifier: "com.manateek1.MacCleaner")
        app.launchArguments += ["-MacCleaner.scanNoticeAcceptedVersion", "4"]
        app.launch()

        let sidebar = app.outlines["sidebar-navigation"]
        let sidebarScrollViews = app.scrollViews.allElementsBoundByIndex
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "The sidebar should be available for navigation.")
        guard let sidebarScrollView = sidebarScrollViews.first(where: { $0.frame.minX < 320 }) else {
            XCTFail("A scrollable view should be available in the sidebar column.")
            return
        }

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
            for _ in 0..<8 {
                if sidebarButton.exists && sidebarButton.isHittable {
                    break
                }
                sidebarScrollView.swipeUp()
            }
            XCTAssertTrue(sidebarButton.exists, "The \(section) sidebar button should exist.")
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
}
