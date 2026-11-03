import XCTest

final class MenuBarPopoverUITests: XCTestCase {
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
