import Foundation
import XCTest
@testable import MacCleaner

final class StartupInventoryTests: XCTestCase {
    func testStandardLocationsCoverUserSharedAndAppleLaunchDefinitions() {
        let home = URL(fileURLWithPath: "/tmp/example-home", isDirectory: true)

        let locations = StartupInventory.standardLocations(homeDirectory: home)

        XCTAssertEqual(Set(locations.map { $0.url.path }), Set([
            "/tmp/example-home/Library/LaunchAgents",
            "/tmp/example-home/Library/LaunchDaemons",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
            "/System/Library/LaunchAgents",
            "/System/Library/LaunchDaemons"
        ]))
        XCTAssertTrue(locations.contains { $0.mechanism == "Apple launch agent" && $0.url.path == "/System/Library/LaunchAgents" })
        XCTAssertTrue(locations.contains { $0.mechanism == "Apple launch daemon" && $0.url.path == "/System/Library/LaunchDaemons" })
    }

    func testStandardApplicationRootsCoverUserInstalledAndAppleApps() {
        let home = URL(fileURLWithPath: "/tmp/example-home", isDirectory: true)

        let roots = StartupInventory.standardApplicationRoots(homeDirectory: home)

        XCTAssertEqual(Set(roots.map(\.path)), Set([
            "/Applications",
            "/tmp/example-home/Applications",
            "/System/Applications",
            "/System/Library/CoreServices"
        ]))
    }

    func testReadsDefinitionsAndSkipsSymlinksAndInvalidPlists() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("MacCleanerStartupTest-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let value: [String: Any] = [
            "Label": "example.helper",
            "ProgramArguments": ["/Applications/Example.app/Contents/MacOS/helper", "sensitive argument"],
            "Description": "Synchronizes\n a local\tindex in the background.",
            "RunAtLoad": true,
            "KeepAlive": true
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        let file = root.appendingPathComponent("helper.plist")
        try data.write(to: file)
        try Data("invalid".utf8).write(to: root.appendingPathComponent("broken.plist"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("alias.plist"), withDestinationURL: file)
        let result = StartupInventory().scan(locations: [(root, "User launch agent")])
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.skipped, 2)
        XCTAssertEqual(result.items[0].label, "example.helper")
        XCTAssertEqual(result.items[0].associatedApp, "Example")
        XCTAssertEqual(result.items[0].program, "/Applications/Example.app/Contents/MacOS/helper")
        XCTAssertEqual(result.items[0].purpose, "Synchronizes a local index in the background.")
        XCTAssertEqual(result.items[0].configuration, "No disabled flag in file")
        XCTAssertEqual(result.items[0].launchConditions, ["When you sign in", "Keeps running while its launch conditions are met"])
        XCTAssertFalse(result.items[0].program?.contains("sensitive argument") ?? true)
    }

    func testExplainsDisabledScheduleAndWatchedPathsWithoutClaimingRuntimeState() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("MacCleanerStartupTest-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let value: [String: Any] = [
            "Label": "example.scheduled",
            "Disabled": true,
            "StartInterval": 300,
            "WatchPaths": ["/tmp/inbox"]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        try data.write(to: root.appendingPathComponent("scheduled.plist"))

        let result = StartupInventory().scan(locations: [(root, "User launch agent")])

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].configuration, "Disabled in file")
        XCTAssertEqual(result.items[0].launchConditions, ["Roughly every 5 minutes", "When a watched file changes"])
        XCTAssertEqual(result.items[0].purpose, "Purpose is not described in this definition.")
    }

    func testReportsOnDemandWhenNoLaunchConditionsAreDeclared() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("MacCleanerStartupTest-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": "example.on-demand"], format: .xml, options: 0)
        try data.write(to: root.appendingPathComponent("on-demand.plist"))

        let result = StartupInventory().scan(locations: [(root, "Shared launch agent")])

        XCTAssertEqual(result.items.first?.launchConditions, ["Started on demand by macOS"])
        XCTAssertEqual(result.items.first?.configuration, "No disabled flag in file")
    }

    func testFindsBundledLaunchDefinitionsAndLoginItemsWithHonestRegistrationStatus() throws {
        let root = try temporaryFolder()
        let parentApp = try makeApplicationBundle(
            at: root.appendingPathComponent("Example.app"),
            name: "Example App",
            identifier: "test.example.parent",
            executable: "Example"
        )
        let launchAgentFolder = parentApp.appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgentFolder, withIntermediateDirectories: true)
        let executableFolder = parentApp.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executableFolder, withIntermediateDirectories: true)
        let helperExecutable = executableFolder.appendingPathComponent("background-helper")
        try Data("fixture helper".utf8).write(to: helperExecutable)
        let definition: [String: Any] = [
            "Label": "test.example.background",
            "ProgramArguments": [helperExecutable.path],
            "RunAtLoad": true
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
        try plistData.write(to: launchAgentFolder.appendingPathComponent("background.plist"))

        let loginItemsFolder = parentApp.appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
        let loginItem = try makeApplicationBundle(
            at: loginItemsFolder.appendingPathComponent("ExampleHelper.app"),
            name: "Example Helper",
            identifier: "test.example.helper",
            executable: "ExampleHelper"
        )
        _ = loginItem
        XCTAssertTrue(SafeFilePolicy.hasNoSymlinkedParent(path: parentApp.path, root: "/"), parentApp.path)
        XCTAssertEqual(Bundle(url: parentApp)?.bundleIdentifier, "test.example.parent", parentApp.path)
        XCTAssertTrue(SafeFilePolicy.hasNoSymlinkedParent(path: launchAgentFolder.path, root: "/"), launchAgentFolder.path)
        XCTAssertTrue(SafeFilePolicy.hasNoSymlinkedParent(path: loginItemsFolder.path, root: "/"), loginItemsFolder.path)
        XCTAssertEqual(Bundle(url: loginItem)?.bundleIdentifier, "test.example.helper", loginItem.path)
        XCTAssertTrue(SafeFilePolicy.hasNoSymlinkedParent(path: helperExecutable.path, root: "/"), helperExecutable.path)
        XCTAssertTrue(SafeFilePolicy.hasNoSymlinkedParent(path: loginItem.path, root: "/"), loginItem.path)
        XCTAssertEqual(Bundle(url: loginItem)?.bundleIdentifier, "test.example.helper")
        let launchAgentPlist = launchAgentFolder.appendingPathComponent("background.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: launchAgentPlist.path))
        XCTAssertTrue(SafeFilePolicy.hasNoSymlinkedParent(path: launchAgentPlist.path, root: "/"), launchAgentPlist.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: loginItemsFolder.appendingPathComponent("ExampleHelper.app").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: launchAgentFolder, includingPropertiesForKeys: nil).count, 1)
        XCTAssertEqual(StartupInventory().scan(locations: [(launchAgentFolder, "User launch agent")]).items.count, 1)

        let result = StartupInventory().scan(locations: [], applicationBundles: [parentApp])

        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(result.items.count, 2, "Skipped entries: \(result.skipped)")
        XCTAssertEqual(result.skipped, 0)
        let bundledAgent = try XCTUnwrap(result.items.first { $0.label == "test.example.background" })
        XCTAssertEqual(bundledAgent.mechanism, "App-bundled launch agent")
        XCTAssertEqual(bundledAgent.associatedApp, "Example App")
        XCTAssertEqual(bundledAgent.authorization, "Registration status unavailable for another app")
        XCTAssertEqual(bundledAgent.launchConditions, ["When you sign in"])
        XCTAssertEqual(bundledAgent.locationURL.lastPathComponent, "background.plist")

        let bundledLoginItem = try XCTUnwrap(result.items.first { $0.label == "test.example.helper" })
        XCTAssertEqual(bundledLoginItem.mechanism, "App-bundled login item")
        XCTAssertEqual(bundledLoginItem.associatedApp, "Example App")
        XCTAssertEqual(bundledLoginItem.authorization, "Registration status unavailable for another app")
        XCTAssertEqual(bundledLoginItem.launchConditions, ["May launch when you sign in if registered"])
        XCTAssertEqual(bundledLoginItem.program?.hasSuffix("/Contents/MacOS/ExampleHelper"), true)
        XCTAssertEqual(bundledLoginItem.locationURL.lastPathComponent, "ExampleHelper.app")
        XCTAssertNotEqual(bundledLoginItem.signatureAssessment?.status, .verified)
    }

    func testSkipsSymlinkedBundledLoginItem() throws {
        let root = try temporaryFolder()
        let parentApp = try makeApplicationBundle(
            at: root.appendingPathComponent("Example.app"),
            name: "Example App",
            identifier: "test.example.parent",
            executable: "Example"
        )
        let loginItemsFolder = parentApp.appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
        try FileManager.default.createDirectory(at: loginItemsFolder, withIntermediateDirectories: true)
        let outsideHelper = try makeApplicationBundle(
            at: root.appendingPathComponent("OutsideHelper.app"),
            name: "Outside Helper",
            identifier: "test.example.outside",
            executable: "OutsideHelper"
        )
        try FileManager.default.createSymbolicLink(
            at: loginItemsFolder.appendingPathComponent("LinkedHelper.app"),
            withDestinationURL: outsideHelper
        )

        let result = StartupInventory().scan(locations: [], applicationBundles: [parentApp])

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.skipped, 1)
    }

    func testCancellationStopsBeforeReadingStartupLocations() {
        let result = StartupInventory().scan(
            locations: [(URL(fileURLWithPath: "/tmp/not-read"), "User launch agent")],
            isCancelled: { true }
        )

        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.items.isEmpty)
    }

    private func makeApplicationBundle(
        at url: URL,
        name: String,
        identifier: String,
        executable: String? = nil
    ) throws -> URL {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1"
        ]
        if let executable {
            info["CFBundleExecutable"] = executable
            let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try Data("unsigned fixture".utf8).write(to: macOS.appendingPathComponent(executable))
        }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }

    private func temporaryFolder() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("MacCleanerStartupTest-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
