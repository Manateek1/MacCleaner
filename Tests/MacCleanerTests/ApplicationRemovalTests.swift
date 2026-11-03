import Foundation
import XCTest
@testable import MacCleaner

final class ApplicationRemovalTests: XCTestCase {
    private func fixture(identifier: String = "example.testing.app") throws -> (URL, URL, InstalledApplication, ApplicationRemovalService) {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("MacCleanerAppTest-\(UUID())", isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let bundle = applications.appendingPathComponent("Example.app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleName": "Example"], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let app = InstalledApplication(url: bundle, name: "Example", bundleIdentifier: identifier, version: "1", logicalSize: Int64(plist.count), sizeIncomplete: false)
        return (root, applications, app, ApplicationRemovalService(allowedRoots: [applications], home: root))
    }

    func testPreparesOnlyExactRelatedLocationsWithoutMovingData() throws {
        let (root, _, app, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let related = library.appendingPathComponent("example.testing.app", isDirectory: true)
        try FileManager.default.createDirectory(at: related, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library.appendingPathComponent("example.testing.app.other"), withIntermediateDirectories: true)
        let plan = try service.prepare(app, runningBundleIDs: [])
        XCTAssertEqual(plan.relatedPaths.map { $0.standardizedFileURL.path }, [related.standardizedFileURL.path])
        try service.verify(plan, runningBundleIDs: [])
        XCTAssertThrowsError(try service.verify(plan, runningBundleIDs: ["example.testing.app"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: related.path))
    }

    func testBatchPreparationKeepsEligibleAppsWhenAnotherAppIsRunning() throws {
        let (root, applications, app, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let secondBundle = applications.appendingPathComponent("Second.app", isDirectory: true)
        let secondContents = secondBundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: secondContents, withIntermediateDirectories: true)
        let secondPlist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "example.running.app", "CFBundleName": "Second"], format: .xml, options: 0)
        try secondPlist.write(to: secondContents.appendingPathComponent("Info.plist"))
        let second = InstalledApplication(url: secondBundle, name: "Second", bundleIdentifier: "example.running.app", version: "1", logicalSize: Int64(secondPlist.count), sizeIncomplete: false)

        let batch = service.prepareBatch(
            [app, second],
            runningBundleIDsByAppID: [app.id: [], second.id: ["example.running.app"]]
        )

        XCTAssertEqual(batch.plans.map(\.id), [app.id])
        XCTAssertEqual(batch.skipped.map(\.appID), [second.id])
        XCTAssertTrue(batch.skipped[0].reason.localizedCaseInsensitiveContains("running"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondBundle.path))
    }

    func testLeftoverScanFindsOnlyUninstalledExactBundleIDPaths() throws {
        let (root, _, _, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let caches = root.appendingPathComponent("Library/Caches", isDirectory: true)
        let leftover = caches.appendingPathComponent("com.vendor.removed", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 18).write(to: leftover.appendingPathComponent("rebuildable.bin"))
        let logs = root.appendingPathComponent("Library/Logs/com.vendor.removed", isDirectory: true)
        let savedState = root.appendingPathComponent("Library/Saved Application State/com.vendor.removed.savedState", isDirectory: true)
        let scripts = root.appendingPathComponent("Library/Application Scripts/com.vendor.removed", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: savedState, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data(repeating: 8, count: 11).write(to: logs.appendingPathComponent("app.log"))
        try Data(repeating: 9, count: 13).write(to: savedState.appendingPathComponent("windows.data"))
        try Data(repeating: 10, count: 17).write(to: scripts.appendingPathComponent("extension.js"))
        try FileManager.default.createDirectory(at: caches.appendingPathComponent("example.testing.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches.appendingPathComponent("com.apple.notes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs.deletingLastPathComponent().appendingPathComponent("com.vendor.removed.other!"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: savedState.deletingLastPathComponent().appendingPathComponent("com.vendor.removed.savedState.extra"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scripts.deletingLastPathComponent().appendingPathComponent("com.vendor.removed.other!"), withIntermediateDirectories: true)
        let inventory = ApplicationBundleIdentifierInventory(identifiers: ["example.testing.app"], unreadableLocations: 0, wasLimited: false)

        let result = service.scanLeftovers(installedApps: inventory, runningBundleIDs: [])

        XCTAssertEqual(result.unreadableLocations, 0)
        XCTAssertEqual(result.candidates.count, 4)
        XCTAssertTrue(result.candidates.allSatisfy { $0.bundleIdentifier == "com.vendor.removed" })
        XCTAssertEqual(Set(result.candidates.map(\.location)), Set([.caches, .logs, .savedApplicationState, .applicationScripts]))
        XCTAssertEqual(result.candidates.reduce(Int64(0)) { $0 + $1.logicalSize }, 59)
        XCTAssertTrue(result.candidates.allSatisfy { !$0.sizeIncomplete && $0.safeToMove })

        let capped = service.scanLeftovers(
            installedApps: inventory,
            runningBundleIDs: [],
            maximumInspectionEntries: 0
        )
        XCTAssertTrue(capped.candidates.first?.sizeIncomplete == true)
        XCTAssertFalse(capped.candidates.first?.safeToMove == true)
    }

    func testRecognizedSuffixMatchesRequireAnExactUnusedIdentifierAndExplainTheClue() throws {
        let (root, _, _, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = "com.vendor.removed"
        let support = root.appendingPathComponent("Library/Application Support/\(identifier)", isDirectory: true)
        let caches = root.appendingPathComponent("Library/Caches", isDirectory: true)
        let cacheVariant = caches.appendingPathComponent("\(identifier).cache", isDirectory: true)
        let helperLikeName = caches.appendingPathComponent("\(identifier).helper", isDirectory: true)
        let installedLikeName = caches.appendingPathComponent("\(identifier).backup", isDirectory: true)
        let preferences = root.appendingPathComponent("Library/Preferences/\(identifier).settings.plist")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheVariant, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helperLikeName, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installedLikeName, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: preferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: support.appendingPathComponent("prefs.dat"))
        try Data(repeating: 2, count: 12).write(to: cacheVariant.appendingPathComponent("cache.bin"))
        try Data(repeating: 3, count: 13).write(to: helperLikeName.appendingPathComponent("helper.bin"))
        try Data(repeating: 4, count: 14).write(to: installedLikeName.appendingPathComponent("backup.bin"))
        try Data(repeating: 5, count: 15).write(to: preferences)
        let inventory = ApplicationBundleIdentifierInventory(
            identifiers: ["example.testing.app", "\(identifier).backup"],
            unreadableLocations: 0,
            wasLimited: false
        )

        let result = service.scanLeftovers(installedApps: inventory, runningBundleIDs: [])
        let candidatePaths = result.candidates.map { $0.url.path }.joined(separator: ", ")
        let cache = try XCTUnwrap(result.candidates.first { $0.id == cacheVariant.standardizedFileURL.path }, "Candidates: \(candidatePaths)")
        let preference = try XCTUnwrap(result.candidates.first { $0.id == preferences.standardizedFileURL.path }, "Candidates: \(candidatePaths)")

        XCTAssertEqual(cache.bundleIdentifier, identifier)
        XCTAssertTrue(cache.match.isRecognizedSuffix)
        XCTAssertTrue(cache.safeToMove)
        XCTAssertTrue(cache.safetyNote.contains("not confirmed"))
        XCTAssertEqual(preference.bundleIdentifier, identifier)
        XCTAssertTrue(preference.match.isRecognizedSuffix)
        XCTAssertFalse(result.candidates.contains { $0.id == installedLikeName.standardizedFileURL.path })
        XCTAssertFalse(try XCTUnwrap(result.candidates.first { $0.id == helperLikeName.standardizedFileURL.path }).match.isRecognizedSuffix)

        let runningResult = service.scanLeftovers(installedApps: inventory, runningBundleIDs: [identifier])
        let runningVariant = try XCTUnwrap(runningResult.candidates.first { $0.id == cacheVariant.standardizedFileURL.path })
        XCTAssertTrue(runningVariant.match.isRecognizedSuffix)
        XCTAssertFalse(runningVariant.safeToMove)

        let installedBase = ApplicationBundleIdentifierInventory(
            identifiers: ["example.testing.app", identifier],
            unreadableLocations: 0,
            wasLimited: false
        )
        let installedResult = service.scanLeftovers(installedApps: installedBase, runningBundleIDs: [])
        XCTAssertFalse(installedResult.candidates.contains { $0.id == cacheVariant.standardizedFileURL.path })
    }

    func testAssociatedSuffixMoveRequiresUnchangedAnchorAndMovesOnlyReviewedPathToTrash() throws {
        let (root, _, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = "com.vendor.removed"
        let support = root.appendingPathComponent("Library/Application Support/\(identifier)", isDirectory: true)
        let cache = root.appendingPathComponent("Library/Caches/\(identifier).cache", isDirectory: true)
        let unrelated = root.appendingPathComponent("Library/Caches/com.vendor.unrelated", isDirectory: true)
        let trash = root.appendingPathComponent("TestTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: support.appendingPathComponent("prefs.dat"))
        try Data(repeating: 2, count: 12).write(to: cache.appendingPathComponent("cache.bin"))
        try Data(repeating: 3, count: 14).write(to: unrelated.appendingPathComponent("keep.bin"))
        let service = ApplicationRemovalService(home: root, trashOperation: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        })
        let inventory = ApplicationBundleIdentifierInventory(identifiers: [], unreadableLocations: 0, wasLimited: false)
        let scan = service.scanLeftovers(installedApps: inventory, runningBundleIDs: [])
        let candidatePaths = scan.candidates.map { $0.url.path }.joined(separator: ", ")
        let candidate = try XCTUnwrap(scan.candidates.first { $0.id == cache.standardizedFileURL.path }, "Candidates: \(candidatePaths)")
        XCTAssertTrue(candidate.match.isRecognizedSuffix)

        try Data("changed after review".utf8).write(to: support.appendingPathComponent("new-file"))
        XCTAssertThrowsError(try service.moveLeftoversToTrash(
            scan,
            selectedPaths: [candidate.id],
            installedApps: inventory,
            runningBundleIDs: [],
            reviewedPaths: [candidate.id]
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))

        let refreshed = service.scanLeftovers(installedApps: inventory, runningBundleIDs: [])
        let refreshedCandidate = try XCTUnwrap(refreshed.candidates.first { $0.id == cache.standardizedFileURL.path })
        let anchorCandidate = try XCTUnwrap(refreshed.candidates.first { $0.id == support.standardizedFileURL.path })
        let reinstalledSuffixApp = ApplicationBundleIdentifierInventory(
            identifiers: ["\(identifier).cache"],
            unreadableLocations: 0,
            wasLimited: false
        )
        XCTAssertThrowsError(try service.moveLeftoversToTrash(
            refreshed,
            selectedPaths: [refreshedCandidate.id],
            installedApps: reinstalledSuffixApp,
            runningBundleIDs: [],
            reviewedPaths: [refreshedCandidate.id]
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))

        let selected = Set([refreshedCandidate.id, anchorCandidate.id])
        let result = try service.moveLeftoversToTrash(
            refreshed,
            selectedPaths: selected,
            installedApps: inventory,
            runningBundleIDs: [],
            reviewedPaths: selected
        )
        XCTAssertEqual(Set(result.movedPaths), selected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 2)
    }

    func testGroupContainerScanShowsDeclaredOwnersAndUnknownFoldersReadOnly() throws {
        let (root, _, _, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let groupRoot = root.appendingPathComponent("Library/Group Containers", isDirectory: true)
        let declaredID = "ABCDE12345.com.vendor.shared"
        let unknownID = "ABCDE12345.com.vendor.unknown"
        let declaredURL = groupRoot.appendingPathComponent(declaredID, isDirectory: true)
        let unknownURL = groupRoot.appendingPathComponent(unknownID, isDirectory: true)
        try FileManager.default.createDirectory(at: declaredURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unknownURL, withIntermediateDirectories: true)
        try Data("container data is not read".utf8).write(to: declaredURL.appendingPathComponent("private-state.dat"))
        let owner = ApplicationGroupOwner(
            bundleIdentifier: "com.vendor.editor",
            applicationName: "Editor",
            applicationURL: root.appendingPathComponent("Applications/Editor.app", isDirectory: true)
        )
        let secondOwner = ApplicationGroupOwner(
            bundleIdentifier: "com.vendor.share-extension",
            applicationName: "Editor Share Extension",
            applicationURL: root.appendingPathComponent("Applications/Editor Share Extension.app", isDirectory: true)
        )
        let inventory = ApplicationBundleIdentifierInventory(
            identifiers: ["com.vendor.editor"],
            unreadableLocations: 0,
            wasLimited: false,
            groupOwners: [declaredID: [owner, secondOwner]],
            groupOwnershipIncomplete: false
        )

        let result = service.scanLeftovers(installedApps: inventory, runningBundleIDs: [])

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertFalse(result.groupContainers.ownershipEvidenceIncomplete)
        XCTAssertEqual(result.groupContainers.containers.count, 2)
        XCTAssertEqual(Set(try XCTUnwrap(result.groupContainers.containers.first { $0.groupIdentifier == declaredID }).owners), [owner, secondOwner])
        XCTAssertTrue(try XCTUnwrap(result.groupContainers.containers.first { $0.groupIdentifier == unknownID }).owners.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: declaredURL.appendingPathComponent("private-state.dat").path))
    }

    func testGroupContainerScanLabelsPartialInventoriesAndSafetyLimits() throws {
        let (root, _, _, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let groupRoot = root.appendingPathComponent("Library/Group Containers", isDirectory: true)
        try FileManager.default.createDirectory(at: groupRoot.appendingPathComponent("ABCDE.com.vendor.one", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: groupRoot.appendingPathComponent("ABCDE.com.vendor.two", isDirectory: true), withIntermediateDirectories: true)
        let external = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: groupRoot.appendingPathComponent("ABCDE.com.vendor.link", isDirectory: true),
            withDestinationURL: external
        )
        let incomplete = ApplicationBundleIdentifierInventory(
            identifiers: [],
            unreadableLocations: 0,
            wasLimited: false,
            groupOwnershipIncomplete: true
        )

        let partial = service.scanLeftovers(installedApps: incomplete, runningBundleIDs: [])
        XCTAssertTrue(partial.groupContainers.ownershipEvidenceIncomplete)
        XCTAssertEqual(partial.groupContainers.unreadableLocations, 1)
        XCTAssertFalse(partial.groupContainers.containers.contains { $0.groupIdentifier == "ABCDE.com.vendor.link" })

        let limited = service.scanLeftovers(
            installedApps: incomplete,
            runningBundleIDs: [],
            maximumCandidates: 1
        )
        XCTAssertTrue(limited.groupContainers.wasLimited)
        XCTAssertEqual(limited.groupContainers.containers.count, 1)
    }

    func testAppGroupEntitlementParserAcceptsOnlyWellFormedStringIdentifiers() {
        XCTAssertEqual(
            ApplicationGroupEntitlementReader.groupIdentifiers(in: [
                "com.apple.security.application-groups": ["ABCDE12345.com.vendor.shared", "group.vendor.widget"]
            ]),
            ["ABCDE12345.com.vendor.shared", "group.vendor.widget"]
        )
        XCTAssertEqual(ApplicationGroupEntitlementReader.groupIdentifiers(in: [:]), [])
        XCTAssertNil(ApplicationGroupEntitlementReader.groupIdentifiers(in: [
            "com.apple.security.application-groups": ["ABCDE12345.com.vendor.shared", "../not-a-group"]
        ]))
        XCTAssertNil(ApplicationGroupEntitlementReader.groupIdentifiers(in: [
            "com.apple.security.application-groups": "ABCDE12345.com.vendor.shared"
        ]))
    }

    func testSensitiveRunningAndIncompleteInventoryLeftoversStayUnavailable() throws {
        let (root, _, _, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let caches = root.appendingPathComponent("Library/Caches", isDirectory: true)
        let sensitive = caches.appendingPathComponent("com.vendor.history", isDirectory: true)
        let running = caches.appendingPathComponent("com.vendor.running", isDirectory: true)
        let packaged = caches.appendingPathComponent("com.vendor.package", isDirectory: true)
        try FileManager.default.createDirectory(at: sensitive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: running, withIntermediateDirectories: true)
        let packageContents = packaged.appendingPathComponent("embedded.app/Contents/Resources/History", isDirectory: true)
        try FileManager.default.createDirectory(at: packageContents, withIntermediateDirectories: true)
        try Data("private history".utf8).write(to: packageContents.appendingPathComponent("session.db"))
        let complete = ApplicationBundleIdentifierInventory(identifiers: [], unreadableLocations: 0, wasLimited: false)

        let result = service.scanLeftovers(installedApps: complete, runningBundleIDs: ["com.vendor.running"])
        XCTAssertEqual(result.candidates.count, 3)
        XCTAssertFalse(try XCTUnwrap(result.candidates.first { $0.bundleIdentifier == "com.vendor.history" }).safeToMove)
        XCTAssertFalse(try XCTUnwrap(result.candidates.first { $0.bundleIdentifier == "com.vendor.running" }).safeToMove)
        let packageCandidate = try XCTUnwrap(result.candidates.first { $0.bundleIdentifier == "com.vendor.package" })
        XCTAssertFalse(packageCandidate.safeToMove)
        XCTAssertTrue(packageCandidate.sizeIncomplete)

        let nestedSensitive = caches.appendingPathComponent("com.vendor.private", isDirectory: true)
        let secrets = nestedSensitive.appendingPathComponent("Passwords", isDirectory: true)
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        try Data("private data".utf8).write(to: secrets.appendingPathComponent("vault.db"))
        let sensitiveResult = service.scanLeftovers(installedApps: complete, runningBundleIDs: [])
        let sensitiveCandidate = try XCTUnwrap(sensitiveResult.candidates.first { $0.bundleIdentifier == "com.vendor.private" })
        XCTAssertFalse(sensitiveCandidate.safeToMove)
        XCTAssertTrue(sensitiveCandidate.sizeIncomplete)
        XCTAssertTrue(sensitiveCandidate.safetyNote.localizedCaseInsensitiveContains("inside"))

        let incomplete = ApplicationBundleIdentifierInventory(identifiers: [], unreadableLocations: 1, wasLimited: false)
        let incompleteResult = service.scanLeftovers(installedApps: incomplete, runningBundleIDs: [])
        XCTAssertTrue(incompleteResult.installedAppInventoryIncomplete)
        XCTAssertTrue(incompleteResult.candidates.allSatisfy { !$0.safeToMove })
    }

    func testLeftoverMoveUsesDisposableTrashAndRejectsChangedOrReinstalledData() throws {
        let (root, applications, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let caches = root.appendingPathComponent("Library/Caches", isDirectory: true)
        let selected = caches.appendingPathComponent("com.vendor.selected", isDirectory: true)
        let unselected = caches.appendingPathComponent("com.vendor.unselected", isDirectory: true)
        let trash = root.appendingPathComponent("TestTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unselected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 12).write(to: selected.appendingPathComponent("cache.bin"))
        try Data(repeating: 2, count: 10).write(to: unselected.appendingPathComponent("cache.bin"))
        let service = ApplicationRemovalService(allowedRoots: [applications], home: root, trashOperation: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        })
        let inventory = ApplicationBundleIdentifierInventory(identifiers: ["example.testing.app"], unreadableLocations: 0, wasLimited: false)
        let scan = service.scanLeftovers(installedApps: inventory, runningBundleIDs: [])
        let selectedCandidate = try XCTUnwrap(scan.candidates.first { $0.bundleIdentifier == "com.vendor.selected" })
        let unselectedCandidate = try XCTUnwrap(scan.candidates.first { $0.bundleIdentifier == "com.vendor.unselected" })

        XCTAssertThrowsError(try service.moveLeftoversToTrash(
            scan,
            selectedPaths: [selectedCandidate.id],
            installedApps: inventory,
            runningBundleIDs: [],
            reviewedPaths: []
        ))
        let result = try service.moveLeftoversToTrash(
            scan,
            selectedPaths: [selectedCandidate.id],
            installedApps: inventory,
            runningBundleIDs: [],
            reviewedPaths: [selectedCandidate.id]
        )
        XCTAssertEqual(result.movedPaths, [selectedCandidate.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unselectedCandidate.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: selectedCandidate.url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 1)

        let changedScan = service.scanLeftovers(installedApps: inventory, runningBundleIDs: [])
        let changedCandidate = try XCTUnwrap(changedScan.candidates.first { $0.bundleIdentifier == "com.vendor.unselected" })
        try Data("changed after review".utf8).write(to: unselected.appendingPathComponent("new-file"))
        XCTAssertThrowsError(try service.moveLeftoversToTrash(
            changedScan,
            selectedPaths: [changedCandidate.id],
            installedApps: inventory,
            runningBundleIDs: [],
            reviewedPaths: [changedCandidate.id]
        ))
        XCTAssertThrowsError(try service.moveLeftoversToTrash(
            changedScan,
            selectedPaths: [changedCandidate.id],
            installedApps: ApplicationBundleIdentifierInventory(identifiers: ["com.vendor.unselected"], unreadableLocations: 0, wasLimited: false),
            runningBundleIDs: [],
            reviewedPaths: [changedCandidate.id]
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unselected.path))
    }

    func testDataLocationsAreListedIndividuallyAndSensitiveTreesStayUnavailable() throws {
        let (root, _, app, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support/example.testing.app", isDirectory: true)
        let cache = library.appendingPathComponent("Caches/example.testing.app", isDirectory: true)
        let container = library.appendingPathComponent("Containers/example.testing.app", isDirectory: true)
        let preferences = library.appendingPathComponent("Preferences/example.testing.app.plist")
        let logs = library.appendingPathComponent("Logs/example.testing.app", isDirectory: true)
        let savedState = library.appendingPathComponent("Saved Application State/example.testing.app.savedState", isDirectory: true)
        let scripts = library.appendingPathComponent("Application Scripts/example.testing.app", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: preferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: savedState, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8).write(to: support.appendingPathComponent("settings.json"))
        try Data(repeating: 2, count: 12).write(to: cache.appendingPathComponent("rebuildable.bin"))
        try Data(repeating: 3, count: 6).write(to: preferences)
        try Data(repeating: 4, count: 14).write(to: logs.appendingPathComponent("app.log"))
        try Data(repeating: 5, count: 16).write(to: savedState.appendingPathComponent("windows.data"))
        try Data(repeating: 6, count: 18).write(to: scripts.appendingPathComponent("extension.js"))

        let plan = try service.prepare(app, runningBundleIDs: [])
        let candidates = Dictionary(uniqueKeysWithValues: plan.relatedData.map { ($0.location, $0) })
        XCTAssertEqual(Set(candidates.keys), Set([
            .applicationSupport, .caches, .preferences, .sandboxContainer,
            .logs, .savedApplicationState, .applicationScripts
        ]))
        XCTAssertTrue(candidates[.caches]?.safeToMove == true)
        XCTAssertTrue(candidates[.applicationSupport]?.safeToMove == true)
        XCTAssertEqual(candidates[.preferences]?.logicalSize, 6)
        XCTAssertEqual(candidates[.caches]?.logicalSize, 12)
        XCTAssertEqual(candidates[.logs]?.logicalSize, 14)
        XCTAssertEqual(candidates[.savedApplicationState]?.logicalSize, 16)
        XCTAssertEqual(candidates[.applicationScripts]?.logicalSize, 18)
    }

    func testUninstallerFindsOnlyLoginHelpersThatPointIntoTheAppBundle() throws {
        let (root, _, app, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = app.url.appendingPathComponent("Contents/MacOS/Example")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("executable".utf8).write(to: executable)
        let agents = root.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let matching = agents.appendingPathComponent("example.testing.app.helper.plist")
        let customFilename = agents.appendingPathComponent("example.testing.app.background.plist")
        let unrelated = agents.appendingPathComponent("com.vendor.other.plist")
        let labelOnly = agents.appendingPathComponent("example.testing.app.label-only.plist")
        let sensitive = agents.appendingPathComponent("example.testing.app.sensitive.plist")
        for (url, label, program) in [
            (matching, "example.testing.app.helper", executable.path),
            (customFilename, "example.testing.app.custom-label", executable.path),
            (unrelated, "com.vendor.other", "/usr/bin/true"),
            (labelOnly, "example.testing.app.label-only", "/usr/bin/true")
        ] {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["Label": label, "Program": program],
                format: .xml,
                options: 0
            )
            try data.write(to: url)
        }
        let sensitiveData = try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "example.testing.app.sensitive",
                "Program": executable.path,
                "EnvironmentVariables": ["SERVICE_TOKEN": "fixture-only"]
            ],
            format: .xml,
            options: 0
        )
        try sensitiveData.write(to: sensitive)

        let plan = try service.prepare(app, runningBundleIDs: [])
        let helpers = plan.relatedData.filter { $0.location == .loginAgent }

        XCTAssertEqual(Set(helpers.map(\.url.lastPathComponent)), Set([matching.lastPathComponent, customFilename.lastPathComponent, sensitive.lastPathComponent]))
        let ordinaryHelper = try XCTUnwrap(helpers.first { $0.url.lastPathComponent == matching.lastPathComponent })
        let customFilenameHelper = try XCTUnwrap(helpers.first { $0.url.lastPathComponent == customFilename.lastPathComponent })
        let sensitiveHelper = try XCTUnwrap(helpers.first { $0.url.lastPathComponent == sensitive.lastPathComponent })
        XCTAssertTrue(ordinaryHelper.safeToMove)
        XCTAssertTrue(ordinaryHelper.safetyNote.contains("background feature"))
        XCTAssertTrue(customFilenameHelper.safeToMove)
        XCTAssertFalse(sensitiveHelper.safeToMove)
        XCTAssertTrue(sensitiveHelper.safetyNote.contains("sign-in settings"))
    }

    func testChangedLoginHelperIsRejectedBeforeReset() throws {
        let (root, _, app, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = app.url.appendingPathComponent("Contents/MacOS/Example")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("executable".utf8).write(to: executable)
        let agents = root.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let helper = agents.appendingPathComponent("example.testing.app.helper.plist")
        let original = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "example.testing.app.helper", "Program": executable.path],
            format: .xml,
            options: 0
        )
        try original.write(to: helper)
        let plan = try service.prepare(app, runningBundleIDs: [])
        let candidate = try XCTUnwrap(plan.relatedData.first { $0.location == .loginAgent })
        let changed = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "example.testing.app.helper", "Program": "/usr/bin/true"],
            format: .xml,
            options: 0
        )
        try changed.write(to: helper)

        XCTAssertThrowsError(try service.resetData(plan, selectedPaths: [candidate.id], runningBundleIDs: []))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path))
    }

    func testSensitiveAndDevelopmentFilesMakeRelatedDataUnselectable() throws {
        let (root, _, app, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Library/Application Support/example.testing.app", isDirectory: true)
        let cache = root.appendingPathComponent("Library/Caches/example.testing.app", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: support.appendingPathComponent("session-token.json"))
        try FileManager.default.createDirectory(at: cache.appendingPathComponent(".git"), withIntermediateDirectories: true)

        let plan = try service.prepare(app, runningBundleIDs: [])
        XCTAssertFalse(try XCTUnwrap(plan.relatedData.first { $0.location == .applicationSupport }).safeToMove)
        XCTAssertFalse(try XCTUnwrap(plan.relatedData.first { $0.location == .caches }).safeToMove)
    }

    func testAppDataSelectionMustMatchAnUnchangedReviewedCandidate() throws {
        let (root, _, app, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("Library/Caches/example.testing.app", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let plan = try service.prepare(app, runningBundleIDs: [])
        let candidate = try XCTUnwrap(plan.relatedData.first { $0.location == .caches })

        XCTAssertThrowsError(try service.resetData(plan, selectedPaths: [root.appendingPathComponent("elsewhere").path], runningBundleIDs: []))
        try Data("changed after review".utf8).write(to: cache.appendingPathComponent("new-file"))
        XCTAssertThrowsError(try service.resetData(plan, selectedPaths: [candidate.id], runningBundleIDs: []))
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.url.path))
    }

    func testResetMovesOnlySelectedFixtureToDisposableTrashAndKeepsApp() throws {
        let (root, applications, app, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library/Caches", isDirectory: true)
        let cache = library.appendingPathComponent("example.testing.app", isDirectory: true)
        let trash = root.appendingPathComponent("TestTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let fixtureFile = cache.appendingPathComponent("rebuildable.bin")
        try Data(repeating: 1, count: 64).write(to: fixtureFile)
        let service = ApplicationRemovalService(allowedRoots: [applications], home: root, trashOperation: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        })
        let plan = try service.prepare(app, runningBundleIDs: [])
        let candidate = try XCTUnwrap(plan.relatedData.first { $0.location == .caches })

        let result = try service.resetData(plan, selectedPaths: [candidate.id], runningBundleIDs: [])

        XCTAssertEqual(result.movedPaths, [candidate.id])
        XCTAssertEqual(result.bytesMoved, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 1)
    }

    func testRefusesRunningAppleAndOwnApps() throws {
        for (identifier, running) in [("example.testing.app", Set(["example.testing.app"])), ("com.apple.finder", Set<String>()), ("com.manateek1.MacCleaner", Set<String>())] {
            let (root, _, app, service) = try fixture(identifier: identifier)
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertThrowsError(try service.prepare(app, runningBundleIDs: running))
        }
    }

    func testRefusesOutsideRootAndSymlinkedApp() throws {
        let (root, applications, app, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = ApplicationRemovalService(allowedRoots: [root.appendingPathComponent("Elsewhere")], home: root)
        XCTAssertThrowsError(try other.prepare(app, runningBundleIDs: []))
        let link = applications.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app.url)
        let linked = InstalledApplication(url: link, name: "Link", bundleIdentifier: app.bundleIdentifier, version: nil, logicalSize: 0, sizeIncomplete: false)
        XCTAssertThrowsError(try service.prepare(linked, runningBundleIDs: []))
    }

    func testChangedPlistOrReplacedBundleInvalidatesReview() throws {
        let (root, _, app, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try service.prepare(app, runningBundleIDs: [])
        let plist = app.url.appendingPathComponent("Contents/Info.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "example.testing.app", "CFBundleName": "Changed"], format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        XCTAssertThrowsError(try service.verify(plan, runningBundleIDs: []))
        let next = try service.prepare(app, runningBundleIDs: [])
        let moved = root.appendingPathComponent("old.app")
        try FileManager.default.moveItem(at: app.url, to: moved)
        try FileManager.default.copyItem(at: moved, to: app.url)
        XCTAssertThrowsError(try service.verify(next, runningBundleIDs: []))
    }
}
