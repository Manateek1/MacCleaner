import Foundation
import XCTest
@testable import MacCleaner

final class HomebrewCaskUpdateServiceTests: XCTestCase {
    func testParsesAndSortsOutdatedCasksWithoutInspectingFormulae() throws {
        let data = Data(
            #"{"formulae":[{"token":"ignored-formula"}],"casks":[{"token":"zulu-app","name":["Zulu App"],"installed_versions":["1.2.0"],"current_version":"1.4.0"},{"token":"alpha-app","name":"Alpha App","installed_versions":["2.0","2.1"],"current_version":"3.0"}]}"#.utf8
        )
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let report = try HomebrewCaskUpdateService.parse(data, checkedAt: checkedAt)

        XCTAssertEqual(report.checkedAt, checkedAt)
        XCTAssertEqual(report.updates.map(\.token), ["alpha-app", "zulu-app"])
        XCTAssertEqual(report.updates[0].name, "Alpha App")
        XCTAssertEqual(report.updates[0].installedVersions, ["2.0", "2.1"])
        XCTAssertEqual(report.updates[0].currentVersion, "3.0")
        XCTAssertEqual(report.updates[1].updateCommand, "brew upgrade --cask zulu-app")
    }

    func testEmptyCaskArrayIsAValidNoUpdatesResult() throws {
        let report = try HomebrewCaskUpdateService.parse(Data(#"{"formulae":[],"casks":[]}"#.utf8))

        XCTAssertTrue(report.updates.isEmpty)
    }

    func testMalformedOrIncompleteHomebrewOutputIsNotTreatedAsNoUpdates() {
        XCTAssertThrowsError(try HomebrewCaskUpdateService.parse(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? HomebrewCaskUpdateError, .invalidOutput)
        }

        let malformedCask = Data(#"{"casks":[{"token":"bad;command","installed_versions":["1"],"current_version":"2"}]}"#.utf8)
        XCTAssertThrowsError(try HomebrewCaskUpdateService.parse(malformedCask)) { error in
            XCTAssertEqual(error as? HomebrewCaskUpdateError, .invalidOutput)
        }
    }

    func testCaskEntriesRequireAnInstalledAndCurrentVersion() {
        let missingVersion = Data(#"{"casks":[{"token":"safe-token","installed_versions":[],"current_version":"2"}]}"#.utf8)

        XCTAssertThrowsError(try HomebrewCaskUpdateService.parse(missingVersion)) { error in
            XCTAssertEqual(error as? HomebrewCaskUpdateError, .invalidOutput)
        }
    }

    func testBrewExecutableDiscoveryUsesOnlyConfiguredStandardLocations() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomebrewCaskUpdateServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("brew")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        XCTAssertEqual(HomebrewCaskUpdateService.brewExecutable(searchPaths: [executable.path]), executable)
        XCTAssertNil(HomebrewCaskUpdateService.brewExecutable(searchPaths: [directory.appendingPathComponent("missing").path]))
    }

    func testCheckInvokesOnlyReadOnlyCaskCommandAndDisablesBackgroundCatalogWork() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomebrewCaskCheckIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("brew")
        let script = #"""
        #!/bin/sh
        printf '{"casks":[{"token":"sample-app","name":"%s|%s|%s","installed_versions":["1"],"current_version":"2"}]}' "$*" "$HOMEBREW_NO_AUTO_UPDATE" "$HOMEBREW_NO_ANALYTICS"
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let report = try HomebrewCaskUpdateService(executableOverride: executable).check()

        XCTAssertEqual(report.updates.count, 1)
        XCTAssertEqual(report.updates[0].name, "outdated --cask --json=v2|1|1")
        XCTAssertEqual(report.updates[0].updateCommand, "brew upgrade --cask sample-app")
    }
}
