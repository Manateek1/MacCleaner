import AppKit
import SwiftUI
import XCTest
@testable import MacCleaner

final class PerformanceMenuLayoutTests: XCTestCase {
    @MainActor
    func testMenuBarPanelKeepsAUsableScrollableWindowSize() {
        let panel = SystemMonitorMenuView(monitor: SystemMonitor())
        let host = NSHostingView(rootView: panel)

        XCTAssertEqual(host.fittingSize.width, 330, accuracy: 1)
        XCTAssertEqual(host.fittingSize.height, 560, accuracy: 1)
    }
}
