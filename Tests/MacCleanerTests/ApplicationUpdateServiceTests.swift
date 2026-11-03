import Foundation
import XCTest
@testable import MacCleaner

final class ApplicationUpdateServiceTests: XCTestCase {
    func testSparkleAppcastReadsElementAndEnclosureVersions() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <title>Version 4.2</title>
              <sparkle:version>42</sparkle:version>
              <sparkle:shortVersionString>4.2</sparkle:shortVersionString>
              <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
              <enclosure url="https://updates.example.test/app.zip" sparkle:edSignature="not-used-by-this-reader" />
            </item>
            <item>
              <enclosure url="https://updates.example.test/app-older.zip" sparkle:version="41" sparkle:shortVersionString="4.1" />
            </item>
          </channel>
        </rss>
        """

        let items = try XCTUnwrap(SparkleAppcastParser().parse(Data(xml.utf8)))

        XCTAssertEqual(items, [
            SparkleFeedItem(buildVersion: "42", displayVersion: "4.2", minimumSystemVersion: "14.0"),
            SparkleFeedItem(buildVersion: "41", displayVersion: "4.1", minimumSystemVersion: nil)
        ])
    }

    func testVersionComparisonUsesNumericComponents() {
        XCTAssertEqual(ApplicationUpdaterService.compareVersions("1.10", "1.9"), 1)
        XCTAssertEqual(ApplicationUpdaterService.compareVersions("1.2.0", "1.2"), 0)
        XCTAssertEqual(ApplicationUpdaterService.compareVersions("1.2", "1.2.1"), -1)
        XCTAssertNil(ApplicationUpdaterService.compareVersions("1.2-beta", "1.2"))
    }

    func testVersionTrackerReportsAChangedNumericBuild() throws {
        let change = try XCTUnwrap(ApplicationUpdateVersionTracker.change(from: "42", to: "43"))

        XCTAssertEqual(change, ApplicationUpdateVersionChange(previousBuildVersion: "42", currentBuildVersion: "43"))
    }

    func testVersionTrackerIgnoresUnchangedMissingAndUncomparableBuilds() {
        XCTAssertNil(ApplicationUpdateVersionTracker.change(from: "42", to: "42"))
        XCTAssertNil(ApplicationUpdateVersionTracker.change(from: nil, to: "43"))
        XCTAssertNil(ApplicationUpdateVersionTracker.change(from: "42-beta", to: "43"))
    }

    func testDiscoveryReportsWhenTheApplicationScanReachesItsSafetyLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("item"))

        let result = ApplicationUpdaterService().discover(roots: [root], maximumVisitedEntries: 0)

        XCTAssertTrue(result.wasLimited)
        XCTAssertFalse(result.wasCancelled)
    }

    func testOnlySecureFeedURLsAreEligibleForChecking() throws {
        XCTAssertTrue(ApplicationUpdaterService.isSecureFeedURL(try XCTUnwrap(URL(string: "https://updates.example.test/appcast.xml"))))
        XCTAssertFalse(ApplicationUpdaterService.isSecureFeedURL(try XCTUnwrap(URL(string: "http://updates.example.test/appcast.xml"))))
        XCTAssertFalse(ApplicationUpdaterService.isSecureFeedURL(try XCTUnwrap(URL(string: "https://user:password@updates.example.test/appcast.xml"))))
        XCTAssertFalse(ApplicationUpdaterService.isSecureFeedURL(try XCTUnwrap(URL(string: "https://updates.example.test/appcast.xml?token=private"))))
    }
}
