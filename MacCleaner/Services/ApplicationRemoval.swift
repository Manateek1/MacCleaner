import Darwin
import Foundation

struct ApplicationPathIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let mode: UInt32
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

enum ApplicationDataLocation: String, CaseIterable, Sendable {
    case applicationSupport
    case caches
    case preferences
    case sandboxContainer
    case logs
    case savedApplicationState
    case applicationScripts
    case loginAgent

    var title: String {
        switch self {
        case .applicationSupport: "Application Support"
        case .caches: "App Cache"
        case .preferences: "Preferences"
        case .sandboxContainer: "App Container"
        case .logs: "App Logs"
        case .savedApplicationState: "Saved App State"
        case .applicationScripts: "App Scripts"
        case .loginAgent: "Login helper"
        }
    }

    fileprivate func url(bundleIdentifier: String, library: URL) -> URL {
        switch self {
        case .applicationSupport:
            library.appendingPathComponent("Application Support", isDirectory: true).appendingPathComponent(bundleIdentifier, isDirectory: true)
        case .caches:
            library.appendingPathComponent("Caches", isDirectory: true).appendingPathComponent(bundleIdentifier, isDirectory: true)
        case .preferences:
            library.appendingPathComponent("Preferences", isDirectory: true).appendingPathComponent("\(bundleIdentifier).plist")
        case .sandboxContainer:
            library.appendingPathComponent("Containers", isDirectory: true).appendingPathComponent(bundleIdentifier, isDirectory: true)
        case .logs:
            library.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent(bundleIdentifier, isDirectory: true)
        case .savedApplicationState:
            library.appendingPathComponent("Saved Application State", isDirectory: true).appendingPathComponent("\(bundleIdentifier).savedState", isDirectory: true)
        case .applicationScripts:
            library.appendingPathComponent("Application Scripts", isDirectory: true).appendingPathComponent(bundleIdentifier, isDirectory: true)
        case .loginAgent:
            library.appendingPathComponent("LaunchAgents", isDirectory: true).appendingPathComponent("\(bundleIdentifier).plist")
        }
    }

    fileprivate func dataRoot(library: URL) -> URL {
        switch self {
        case .applicationSupport: library.appendingPathComponent("Application Support", isDirectory: true)
        case .caches: library.appendingPathComponent("Caches", isDirectory: true)
        case .preferences: library.appendingPathComponent("Preferences", isDirectory: true)
        case .sandboxContainer: library.appendingPathComponent("Containers", isDirectory: true)
        case .logs: library.appendingPathComponent("Logs", isDirectory: true)
        case .savedApplicationState: library.appendingPathComponent("Saved Application State", isDirectory: true)
        case .applicationScripts: library.appendingPathComponent("Application Scripts", isDirectory: true)
        case .loginAgent: library.appendingPathComponent("LaunchAgents", isDirectory: true)
        }
    }
}

enum ApplicationLeftoverMatch: Sendable {
    case exactBundleIdentifier
    case recognizedSuffix(
        baseIdentifier: String,
        anchorPath: String,
        anchorIdentity: ApplicationPathIdentity,
        anchorLocation: ApplicationDataLocation,
        suffix: String
    )

    var isRecognizedSuffix: Bool {
        if case .recognizedSuffix = self { return true }
        return false
    }
}

struct ApplicationDataCandidate: Identifiable, Sendable {
    let bundleIdentifier: String
    let locationIdentifier: String?
    let location: ApplicationDataLocation
    let url: URL
    let identity: ApplicationPathIdentity
    let logicalSize: Int64
    let sizeIncomplete: Bool
    let isDirectory: Bool
    let safeToMove: Bool
    let safetyNote: String
    var match: ApplicationLeftoverMatch = .exactBundleIdentifier

    var id: String { url.standardizedFileURL.path }
}

struct ApplicationRemovalPlan: Sendable, Identifiable {
    let app: InstalledApplication
    let root: URL
    let directoryIdentity: ApplicationPathIdentity
    let infoIdentity: ApplicationPathIdentity
    let relatedData: [ApplicationDataCandidate]
    var relatedPaths: [URL] { relatedData.map(\.url) }
    var id: String { app.id }
}

struct ApplicationDataMoveResult: Sendable {
    let movedPaths: [String]
    let failures: [TrashFailure]
    let bytesMoved: Int64
}

struct ApplicationRemovalOutcome: Sendable {
    let appMoved: Bool
    let appFailure: String?
    let relatedData: ApplicationDataMoveResult
}

struct ApplicationRemovalPreparationFailure: Identifiable, Sendable {
    let appID: String
    let appName: String
    let reason: String
    var id: String { appID }
}

struct ApplicationRemovalBatchPlan: Sendable {
    let plans: [ApplicationRemovalPlan]
    let skipped: [ApplicationRemovalPreparationFailure]
}

struct ApplicationLeftoverScanResult: Sendable {
    let candidates: [ApplicationDataCandidate]
    let groupContainers: ApplicationGroupContainerScanResult
    let unreadableLocations: Int
    let wasLimited: Bool
    let installedAppInventoryIncomplete: Bool
}

enum ApplicationRemovalError: LocalizedError {
    case outsideApplications, protectedApp, invalidBundle, changed, running, inaccessible, invalidSelection, incompleteAppInventory
    var errorDescription: String? {
        switch self {
        case .outsideApplications: "Only apps in the standard Applications folders can be moved."
        case .protectedApp: "Apple apps and Mac Cleaner cannot be removed here."
        case .invalidBundle: "The application is not a readable, valid app bundle."
        case .changed: "The application changed after the review was opened. Refresh and review it again."
        case .running: "This app is running. Quit it before moving it to Trash."
        case .inaccessible: "macOS could not access the app or its enclosing folder. Check disk access."
        case .invalidSelection: "One of the selected data locations is not part of this app review. Refresh and review it again."
        case .incompleteAppInventory: "Mac Cleaner could not check all standard Applications folders. Refresh the app list before reviewing these possible leftovers."
        }
    }
}

struct ApplicationRemovalService: Sendable {
    let allowedRoots: [URL]
    let home: URL
    private let trashOperation: @Sendable (URL) throws -> Void

    init(allowedRoots: [URL]? = nil, home: URL = SafeFilePolicy.accountHome, trashOperation: @escaping @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) {
        self.home = home
        self.allowedRoots = allowedRoots ?? [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)]
        self.trashOperation = trashOperation
    }

    func prepare(_ app: InstalledApplication, runningBundleIDs: Set<String>) throws -> ApplicationRemovalPlan {
        let verified = try inspectApp(app, runningBundleIDs: runningBundleIDs)
        return ApplicationRemovalPlan(
            app: app,
            root: verified.root,
            directoryIdentity: verified.directory,
            infoIdentity: verified.info,
            relatedData: relatedData(identifier: app.bundleIdentifier ?? "", appURL: app.url)
        )
    }

    func prepareBatch(_ apps: [InstalledApplication], runningBundleIDsByAppID: [String: Set<String>]) -> ApplicationRemovalBatchPlan {
        var plans: [ApplicationRemovalPlan] = []
        var skipped: [ApplicationRemovalPreparationFailure] = []
        for app in apps {
            do {
                plans.append(try prepare(app, runningBundleIDs: runningBundleIDsByAppID[app.id] ?? []))
            } catch {
                skipped.append(ApplicationRemovalPreparationFailure(appID: app.id, appName: app.name, reason: error.localizedDescription))
            }
        }
        return ApplicationRemovalBatchPlan(plans: plans, skipped: skipped)
    }

    func scanLeftovers(
        installedApps: ApplicationBundleIdentifierInventory,
        runningBundleIDs: Set<String>,
        maximumCandidates: Int = 2_000,
        maximumInspectionEntries: Int = 250_000,
        maximumEntriesPerCandidate: Int = 20_000,
        progress: @Sendable (ApplicationDataLocation, Int, Int) -> Void = { _, _, _ in }
    ) -> ApplicationLeftoverScanResult {
        let library = home.appendingPathComponent("Library", isDirectory: true).standardizedFileURL
        let roots: [(ApplicationDataLocation, URL)] = [
            (.applicationSupport, library.appendingPathComponent("Application Support", isDirectory: true)),
            (.caches, library.appendingPathComponent("Caches", isDirectory: true)),
            (.preferences, library.appendingPathComponent("Preferences", isDirectory: true)),
            (.sandboxContainer, library.appendingPathComponent("Containers", isDirectory: true)),
            (.logs, library.appendingPathComponent("Logs", isDirectory: true)),
            (.savedApplicationState, library.appendingPathComponent("Saved Application State", isDirectory: true)),
            (.applicationScripts, library.appendingPathComponent("Application Scripts", isDirectory: true))
        ]
        let installedIDs = installedApps.identifiers
        let runningIDs = Set(runningBundleIDs.map { $0.lowercased() })
        var candidates: [ApplicationDataCandidate] = []
        var unreadable = 0
        var wasLimited = false
        var inspectionEntriesRemaining = max(0, maximumInspectionEntries)

        for (location, root) in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard SafeFilePolicy.hasNoSymlinkedParent(path: root.standardizedFileURL.path, root: library.path),
                  let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                unreadable += 1
                continue
            }

            for (childIndex, child) in children.enumerated() {
                progress(location, childIndex + 1, children.count)
                guard candidates.count < maximumCandidates else { wasLimited = true; break }
                let identifier = bundleIdentifier(for: child, in: location)
                let validIdentifier = identifier.map(isBundleIdentifier) ?? false
                let notApple = !(identifier?.lowercased().hasPrefix("com.apple.") ?? true)
                let notInstalled = !(identifier.map { installedIDs.contains($0.lowercased()) } ?? true)
                let associatedSuffix = recognizedAssociatedSuffix(for: child, in: location)
                let baseNotInstalled = associatedSuffix.map { !installedIDs.contains($0.baseIdentifier.lowercased()) } ?? true
                let insideLibrary = SafeFilePolicy.isInside(child.standardizedFileURL.path, root: library.path)
                let normalizedPath = child.standardizedFileURL.path
                let hasSafePath = SafeFilePolicy.hasNoSymlinkedParent(path: normalizedPath, root: library.path)
                let itemIdentity = identity(normalizedPath)
                guard let identifier, validIdentifier, notApple, notInstalled, baseNotInstalled, insideLibrary, hasSafePath, let itemIdentity else { continue }
                let kind = itemIdentity.mode & UInt32(S_IFMT)
                let isDirectory = kind == UInt32(S_IFDIR)
                guard isDirectory || kind == UInt32(S_IFREG), itemIdentity.size <= 1_000_000_000 else { continue }

                let isRunning = runningIDs.contains(identifier.lowercased())
                    || associatedSuffix.map { runningIDs.contains($0.baseIdentifier.lowercased()) } == true
                let sensitiveName = isSensitiveDataName(child)
                let inspection: (bytes: Int64, incomplete: Bool, containsSensitiveData: Bool, entriesInspected: Int)
                if inspectionEntriesRemaining == 0 {
                    inspection = (0, true, false, 0)
                } else {
                    inspection = inspectData(
                        child,
                        isDirectory: isDirectory,
                        maximumEntries: min(max(1, maximumEntriesPerCandidate), inspectionEntriesRemaining)
                    )
                    inspectionEntriesRemaining = max(0, inspectionEntriesRemaining - inspection.entriesInspected)
                }
                let changedDuringInspection = identity(normalizedPath) != itemIdentity
                let inspectionIncomplete = inspection.incomplete || changedDuringInspection
                let containsSensitiveData = sensitiveName || inspection.containsSensitiveData
                let note: String
                if installedApps.isComplete == false {
                    note = "Kept unavailable because the installed-app scan was incomplete."
                } else if isRunning {
                    note = "Kept unavailable because an app with this identifier is running."
                } else if containsSensitiveData {
                    note = "Kept unavailable because the location name or something inside it suggests credentials, history, or personal data."
                } else if inspectionIncomplete {
                    note = "Kept unavailable because Mac Cleaner could not check the entire location."
                } else {
                    note = "A name match is only a clue. Review the contents in Finder; this location may still hold app settings or personal data."
                }
                candidates.append(ApplicationDataCandidate(
                    bundleIdentifier: identifier,
                    locationIdentifier: nil,
                    location: location,
                    url: child.standardizedFileURL,
                    identity: itemIdentity,
                    logicalSize: inspection.bytes,
                    sizeIncomplete: inspectionIncomplete,
                    isDirectory: isDirectory,
                    safeToMove: installedApps.isComplete && !isRunning && !containsSensitiveData && !inspectionIncomplete,
                    safetyNote: note
                ))
            }
            if wasLimited { break }
        }

        candidates = addRecognizedSuffixMatches(to: candidates, runningIDs: runningIDs)

        return ApplicationLeftoverScanResult(
            candidates: candidates.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending },
            groupContainers: scanGroupContainers(installedApps: installedApps, maximumContainers: maximumCandidates),
            unreadableLocations: unreadable,
            wasLimited: wasLimited,
            installedAppInventoryIncomplete: !installedApps.isComplete
        )
    }

    private func scanGroupContainers(
        installedApps: ApplicationBundleIdentifierInventory,
        maximumContainers: Int
    ) -> ApplicationGroupContainerScanResult {
        let library = home.appendingPathComponent("Library", isDirectory: true).standardizedFileURL
        let root = library.appendingPathComponent("Group Containers", isDirectory: true).standardizedFileURL
        var ownershipEvidenceIncomplete = installedApps.groupOwnershipIncomplete || !installedApps.isComplete

        var rootInfo = Darwin.stat()
        let rootStatus = root.path.withCString { Darwin.lstat($0, &rootInfo) }
        guard rootStatus == 0 else {
            let isMissing = errno == ENOENT
            return ApplicationGroupContainerScanResult(
                containers: [],
                unreadableLocations: isMissing ? 0 : 1,
                wasLimited: false,
                ownershipEvidenceIncomplete: ownershipEvidenceIncomplete || !isMissing
            )
        }
        guard SafeFilePolicy.hasNoSymlinkedParent(path: root.path, root: library.path),
              rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              let children = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else {
            return ApplicationGroupContainerScanResult(
                containers: [],
                unreadableLocations: 1,
                wasLimited: false,
                ownershipEvidenceIncomplete: true
            )
        }

        var containers: [ApplicationGroupContainer] = []
        var unreadable = 0
        var wasLimited = false
        var entriesInspected = 0
        let resolvedRootPath = root.resolvingSymlinksInPath().path
        for child in children {
            guard entriesInspected < max(0, maximumContainers) else {
                wasLimited = true
                ownershipEvidenceIncomplete = true
                break
            }
            entriesInspected += 1
            let childParentPath = child.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            guard childParentPath == resolvedRootPath,
                  let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                unreadable += 1
                ownershipEvidenceIncomplete = true
                continue
            }
            guard values.isSymbolicLink != true else {
                unreadable += 1
                ownershipEvidenceIncomplete = true
                continue
            }
            guard values.isDirectory == true else { continue }
            guard let childIdentity = identity(child.path),
                  childIdentity.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) else {
                unreadable += 1
                ownershipEvidenceIncomplete = true
                continue
            }

            containers.append(ApplicationGroupContainer(
                groupIdentifier: child.lastPathComponent,
                url: child.standardizedFileURL,
                owners: installedApps.groupOwners[child.lastPathComponent] ?? []
            ))
        }

        return ApplicationGroupContainerScanResult(
            containers: containers.sorted { $0.groupIdentifier.localizedStandardCompare($1.groupIdentifier) == .orderedAscending },
            unreadableLocations: unreadable,
            wasLimited: wasLimited,
            ownershipEvidenceIncomplete: ownershipEvidenceIncomplete
        )
    }

    func moveLeftoversToTrash(
        _ scan: ApplicationLeftoverScanResult,
        selectedPaths: Set<String>,
        installedApps: ApplicationBundleIdentifierInventory,
        runningBundleIDs: Set<String>,
        reviewedPaths: Set<String>
    ) throws -> ApplicationDataMoveResult {
        guard !scan.installedAppInventoryIncomplete, installedApps.isComplete else { throw ApplicationRemovalError.incompleteAppInventory }
        let selected = scan.candidates.filter { selectedPaths.contains($0.id) }
        guard selected.count == selectedPaths.count,
              selected.allSatisfy(\.safeToMove),
              selectedPaths.isSubset(of: reviewedPaths) else { throw ApplicationRemovalError.invalidSelection }
        for candidate in selected { try verifyLeftover(candidate, installedApps: installedApps, runningBundleIDs: runningBundleIDs) }

        var moved: [String] = []
        var failures: [TrashFailure] = []
        var bytesMoved: Int64 = 0
        for candidate in selected {
            do {
                try verifyLeftover(candidate, installedApps: installedApps, runningBundleIDs: runningBundleIDs, alreadyMovedPaths: Set(moved))
                try trashOperation(candidate.url)
                moved.append(candidate.id)
                bytesMoved += candidate.logicalSize
            } catch {
                failures.append(TrashFailure(path: candidate.id, reason: error.localizedDescription))
            }
        }
        return ApplicationDataMoveResult(movedPaths: moved, failures: failures, bytesMoved: bytesMoved)
    }

    func verify(_ plan: ApplicationRemovalPlan, runningBundleIDs: Set<String>) throws {
        let current = try inspectApp(plan.app, runningBundleIDs: runningBundleIDs)
        guard current.root == plan.root, current.directory == plan.directoryIdentity, current.info == plan.infoIdentity else { throw ApplicationRemovalError.changed }
    }

    private func inspectApp(_ app: InstalledApplication, runningBundleIDs: Set<String>) throws -> (root: URL, directory: ApplicationPathIdentity, info: ApplicationPathIdentity) {
        let path = app.url.standardizedFileURL.path
        guard let root = allowedRoots.map(\.standardizedFileURL).first(where: { SafeFilePolicy.isInside(path, root: $0.path) }) else { throw ApplicationRemovalError.outsideApplications }
        var parent = app.url.deletingLastPathComponent().standardizedFileURL
        while parent.path != root.path {
            guard parent.pathExtension.lowercased() != "app", parent.path != "/" else { throw ApplicationRemovalError.outsideApplications }
            parent.deleteLastPathComponent()
        }
        guard app.url.pathExtension.lowercased() == "app", let identifier = app.bundleIdentifier, !identifier.isEmpty else { throw ApplicationRemovalError.invalidBundle }
        let lowered = identifier.lowercased()
        guard !lowered.hasPrefix("com.apple."), lowered != "com.manateek1.maccleaner" else { throw ApplicationRemovalError.protectedApp }
        guard !runningBundleIDs.contains(where: { $0.caseInsensitiveCompare(identifier) == .orderedSame }) else { throw ApplicationRemovalError.running }
        guard !SafeFilePolicy.containsProtectedPathComponent(path), !SafeFilePolicy.isInsideDevelopmentRepository(path),
              SafeFilePolicy.hasNoSymlinkedParent(path: app.url.path, root: "/") else { throw ApplicationRemovalError.inaccessible }
        let plist = app.url.appendingPathComponent("Contents/Info.plist")
        guard SafeFilePolicy.hasNoSymlinkedParent(path: plist.path, root: "/"),
              let directory = identity(path), directory.mode & UInt32(S_IFMT) == UInt32(S_IFDIR),
              let info = identity(plist.path), info.mode & UInt32(S_IFMT) == UInt32(S_IFREG), info.size <= 1_000_000,
              let actualIdentifier = bundleIdentifier(at: plist), actualIdentifier == identifier else { throw ApplicationRemovalError.invalidBundle }
        return (root, directory, info)
    }

    private func verifyLeftover(
        _ candidate: ApplicationDataCandidate,
        installedApps: ApplicationBundleIdentifierInventory,
        runningBundleIDs: Set<String>,
        alreadyMovedPaths: Set<String> = []
    ) throws {
        let identifier = candidate.bundleIdentifier
        let loweredIdentifier = identifier.lowercased()
        let library = home.appendingPathComponent("Library", isDirectory: true).standardizedFileURL
        let currentPathIdentifier = bundleIdentifier(for: candidate.url, in: candidate.location)?.lowercased()
        let exactExpected = candidate.location.url(bundleIdentifier: identifier, library: library).standardizedFileURL
        let expectedRoot = candidate.location.dataRoot(library: library).standardizedFileURL
        let runningIDs = Set(runningBundleIDs.map { $0.lowercased() })
        let pathIsExpected: Bool
        let associationIsCurrent: Bool
        switch candidate.match {
        case .exactBundleIdentifier:
            pathIsExpected = exactExpected == candidate.url.standardizedFileURL
            associationIsCurrent = true
        case let .recognizedSuffix(baseIdentifier, anchorPath, anchorIdentity, anchorLocation, suffix):
            let suffixMatch = recognizedAssociatedSuffix(for: candidate.url, in: candidate.location)
            let anchorURL = URL(fileURLWithPath: anchorPath).standardizedFileURL
            let anchorIsExpected = anchorLocation.dataRoot(library: library).standardizedFileURL == anchorURL.deletingLastPathComponent()
                && bundleIdentifier(for: anchorURL, in: anchorLocation) == baseIdentifier
            pathIsExpected = candidate.url.deletingLastPathComponent().standardizedFileURL == expectedRoot
                && suffixMatch?.baseIdentifier == baseIdentifier
                && suffixMatch?.suffix == suffix
                && candidate.bundleIdentifier == baseIdentifier
            associationIsCurrent = alreadyMovedPaths.contains(anchorPath)
                || (anchorIsExpected
                    && SafeFilePolicy.isInside(anchorPath, root: library.path)
                    && SafeFilePolicy.hasNoSymlinkedParent(path: anchorPath, root: library.path)
                    && identity(anchorPath) == anchorIdentity)
        }
        guard candidate.safeToMove,
              isBundleIdentifier(identifier),
              !identifier.lowercased().hasPrefix("com.apple."),
              !isSensitiveDataName(candidate.url),
              !installedApps.identifiers.contains(loweredIdentifier),
              currentPathIdentifier.map({ !installedApps.identifiers.contains($0) }) == true,
              !runningIDs.contains(loweredIdentifier),
              currentPathIdentifier.map({ !runningIDs.contains($0) }) == true,
              pathIsExpected,
              associationIsCurrent,
              SafeFilePolicy.isInside(candidate.id, root: library.path),
              SafeFilePolicy.hasNoSymlinkedParent(path: candidate.id, root: library.path),
              identity(candidate.id) == candidate.identity else { throw ApplicationRemovalError.changed }
    }

    private func bundleIdentifier(for url: URL, in location: ApplicationDataLocation) -> String? {
        if location == .preferences {
            guard url.pathExtension.lowercased() == "plist" else { return nil }
            return url.deletingPathExtension().lastPathComponent
        }
        if location == .savedApplicationState {
            guard url.pathExtension.lowercased() == "savedstate" else { return nil }
            return url.deletingPathExtension().lastPathComponent
        }
        return url.lastPathComponent
    }

    private func isBundleIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)+$", options: .regularExpression) != nil
            && !value.contains("..")
    }

    private func recognizedAssociatedSuffix(for url: URL, in location: ApplicationDataLocation) -> (baseIdentifier: String, suffix: String)? {
        guard let identifier = bundleIdentifier(for: url, in: location),
              let separator = identifier.lastIndex(of: ".") else { return nil }
        let baseIdentifier = String(identifier[..<separator])
        let suffix = String(identifier[identifier.index(after: separator)...]).lowercased()
        let recognizedSuffixes: Set<String> = [
            "backup", "backups", "cache", "caches", "data", "database", "db",
            "log", "logs", "metadata", "preference", "preferences", "prefs",
            "savedstate", "settings", "state", "temp", "tmp", "support"
        ]
        let componentCount = baseIdentifier.split(separator: ".").count
        guard recognizedSuffixes.contains(suffix), isBundleIdentifier(baseIdentifier),
              componentCount >= 3, baseIdentifier.filter({ $0.isLetter || $0.isNumber }).count >= 12 else { return nil }
        return (baseIdentifier, suffix)
    }

    private func addRecognizedSuffixMatches(
        to candidates: [ApplicationDataCandidate],
        runningIDs: Set<String>
    ) -> [ApplicationDataCandidate] {
        let possibleAnchors = candidates.filter { candidate in
            guard let suffix = recognizedAssociatedSuffix(for: candidate.url, in: candidate.location) else { return true }
            return !candidates.contains { other in
                other.id != candidate.id
                    && other.bundleIdentifier.caseInsensitiveCompare(suffix.baseIdentifier) == .orderedSame
            }
        }
        let anchorsByIdentifier = Dictionary(grouping: possibleAnchors, by: { $0.bundleIdentifier.lowercased() })
        guard !anchorsByIdentifier.isEmpty else { return candidates }

        var result: [ApplicationDataCandidate] = []
        result.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard candidate.match.isRecognizedSuffix == false,
                  let suffix = recognizedAssociatedSuffix(for: candidate.url, in: candidate.location),
                  let anchors = anchorsByIdentifier[suffix.baseIdentifier.lowercased()],
                  let anchor = anchors.sorted(by: {
                      if $0.safeToMove != $1.safeToMove { return $0.safeToMove }
                      return $0.id.localizedStandardCompare($1.id) == .orderedAscending
                  }).first else {
                result.append(candidate)
                continue
            }
            let isBaseRunning = runningIDs.contains(suffix.baseIdentifier.lowercased())
            let safeToMove = candidate.safeToMove && anchor.safeToMove && !isBaseRunning
            let evidence = "Possible match: this name adds the “\(suffix.suffix)” suffix to an unused app identifier also found in \(anchor.location.title). The connection is not confirmed. Review this exact path in Finder before moving it to Trash."
            let blockedNote: String
            if isBaseRunning {
                blockedNote = "Kept unavailable because an app with this identifier is running."
            } else if !anchor.safeToMove {
                blockedNote = "Kept unavailable because the exact matching location could not be checked safely."
            } else {
                blockedNote = candidate.safetyNote
            }
            let note = safeToMove ? evidence : "\(blockedNote) \(evidence)"
            result.append(ApplicationDataCandidate(
                bundleIdentifier: suffix.baseIdentifier,
                locationIdentifier: candidate.locationIdentifier,
                location: candidate.location,
                url: candidate.url,
                identity: candidate.identity,
                logicalSize: candidate.logicalSize,
                sizeIncomplete: candidate.sizeIncomplete,
                isDirectory: candidate.isDirectory,
                safeToMove: safeToMove,
                safetyNote: note,
                match: .recognizedSuffix(
                    baseIdentifier: suffix.baseIdentifier,
                    anchorPath: anchor.id,
                    anchorIdentity: anchor.identity,
                    anchorLocation: anchor.location,
                    suffix: suffix.suffix
                )
            ))
        }
        return result
    }

    func resetData(_ plan: ApplicationRemovalPlan, selectedPaths: Set<String>, runningBundleIDs: Set<String>) throws -> ApplicationDataMoveResult {
        try verify(plan, runningBundleIDs: runningBundleIDs)
        return try moveRelatedData(plan, selectedPaths: selectedPaths, runningBundleIDs: runningBundleIDs)
    }

    func moveToTrash(_ plan: ApplicationRemovalPlan, selectedRelatedPaths: Set<String> = [], runningBundleIDs: Set<String>) throws -> ApplicationRemovalOutcome {
        try verify(plan, runningBundleIDs: runningBundleIDs)
        let related = try moveRelatedData(plan, selectedPaths: selectedRelatedPaths, runningBundleIDs: runningBundleIDs)
        do {
            try verify(plan, runningBundleIDs: runningBundleIDs)
            try trashOperation(plan.app.url)
            return ApplicationRemovalOutcome(appMoved: true, appFailure: nil, relatedData: related)
        } catch {
            return ApplicationRemovalOutcome(appMoved: false, appFailure: error.localizedDescription, relatedData: related)
        }
    }

    private func moveRelatedData(_ plan: ApplicationRemovalPlan, selectedPaths: Set<String>, runningBundleIDs: Set<String>) throws -> ApplicationDataMoveResult {
        let selected = plan.relatedData.filter { selectedPaths.contains($0.id) }
        guard selected.count == selectedPaths.count, selected.allSatisfy(\.safeToMove) else { throw ApplicationRemovalError.invalidSelection }
        for candidate in selected { try verify(candidate, for: plan.app) }

        var moved: [String] = []
        var failures: [TrashFailure] = []
        var bytes: Int64 = 0
        for candidate in selected {
            do {
                try verify(plan, runningBundleIDs: runningBundleIDs)
                try verify(candidate, for: plan.app)
                try trashOperation(candidate.url)
                moved.append(candidate.id)
                bytes += candidate.logicalSize
            } catch {
                failures.append(TrashFailure(path: candidate.id, reason: error.localizedDescription))
            }
        }
        return ApplicationDataMoveResult(movedPaths: moved, failures: failures, bytesMoved: bytes)
    }

    private func verify(_ candidate: ApplicationDataCandidate, for app: InstalledApplication) throws {
        guard let identifier = app.bundleIdentifier,
              candidate.bundleIdentifier == identifier,
              identifier.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
              !identifier.contains("..") else { throw ApplicationRemovalError.changed }
        let library = home.appendingPathComponent("Library", isDirectory: true).standardizedFileURL
        let pathIdentifier = candidate.locationIdentifier ?? identifier
        guard pathIdentifier.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
              !pathIdentifier.contains("..") else { throw ApplicationRemovalError.changed }
        let expected = candidate.location.url(bundleIdentifier: pathIdentifier, library: library).standardizedFileURL
        let helperStillPointsIntoApp = candidate.location != .loginAgent || loginAgentPointsIntoApp(candidate.url, app: app)
        guard expected == candidate.url.standardizedFileURL,
              helperStillPointsIntoApp,
              SafeFilePolicy.isInside(candidate.id, root: library.path),
              SafeFilePolicy.hasNoSymlinkedParent(path: candidate.id, root: library.path),
              identity(candidate.id) == candidate.identity else { throw ApplicationRemovalError.changed }
    }

    private func relatedData(identifier: String, appURL: URL) -> [ApplicationDataCandidate] {
        guard identifier.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil, !identifier.contains("..") else { return [] }
        let library = home.appendingPathComponent("Library", isDirectory: true).standardizedFileURL
        let exactData: [ApplicationDataCandidate] = ApplicationDataLocation.allCases
            .filter { $0 != .loginAgent }
            .compactMap { location -> ApplicationDataCandidate? in
            let url = location.url(bundleIdentifier: identifier, library: library).standardizedFileURL
            guard SafeFilePolicy.isInside(url.path, root: library.path),
                  SafeFilePolicy.hasNoSymlinkedParent(path: url.path, root: library.path),
                  let itemIdentity = identity(url.path) else { return nil }
            let kind = itemIdentity.mode & UInt32(S_IFMT)
            let isDirectory = kind == UInt32(S_IFDIR)
            guard isDirectory || kind == UInt32(S_IFREG), itemIdentity.size <= 1_000_000_000 else { return nil }
            let inspection = inspectData(url, isDirectory: isDirectory)
            let changedDuringInspection = identity(url.path) != itemIdentity
            let incomplete = inspection.incomplete || changedDuringInspection
            let note: String
            if inspection.containsSensitiveData {
                note = "Kept in place because this location contains credentials, personal history, models, or development data."
            } else if incomplete {
                note = "Kept in place because Mac Cleaner could not inspect the full location."
            } else {
                note = "Exact bundle-ID path; ownership is not proven. It may contain settings or personal data, so inspect it before choosing."
            }
            return ApplicationDataCandidate(
                bundleIdentifier: identifier,
                locationIdentifier: nil,
                location: location,
                url: url,
                identity: itemIdentity,
                logicalSize: inspection.bytes,
                sizeIncomplete: incomplete,
                isDirectory: isDirectory,
                safeToMove: !inspection.containsSensitiveData && !incomplete,
                safetyNote: note
            )
        }
        return exactData + relatedLoginAgents(appIdentifier: identifier, appURL: appURL)
    }

    private func relatedLoginAgents(appIdentifier: String, appURL: URL) -> [ApplicationDataCandidate] {
        let library = home.appendingPathComponent("Library", isDirectory: true).standardizedFileURL
        let root = library.appendingPathComponent("LaunchAgents", isDirectory: true)
        guard SafeFilePolicy.hasNoSymlinkedParent(path: root.path, root: library.path),
              let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }

        return children.compactMap { url in
            guard url.pathExtension.lowercased() == "plist",
                  SafeFilePolicy.hasNoSymlinkedParent(path: url.standardizedFileURL.path, root: root.path),
                  let itemIdentity = identity(url.path),
                  itemIdentity.mode & UInt32(S_IFMT) == UInt32(S_IFREG),
                  itemIdentity.size <= 1_000_000,
                  let dictionary = launchAgentDictionary(at: url),
                  let program = launchAgentProgram(in: dictionary),
                  SafeFilePolicy.hasNoSymlinkedParent(path: program, root: appURL.standardizedFileURL.path),
                  SafeFilePolicy.isInside(program, root: appURL.standardizedFileURL.path) else { return nil }
            guard let label = dictionary["Label"] as? String else { return nil }
            let locationIdentifier = url.deletingPathExtension().lastPathComponent
            guard label.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
                  !label.contains(".."),
                  locationIdentifier.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
                  !locationIdentifier.contains("..") else { return nil }

            let inspection = inspectData(url, isDirectory: false)
            let hasSensitiveSettings = containsSensitiveLaunchSettings(dictionary)
            let incomplete = inspection.incomplete || hasSensitiveSettings || identity(url.path) != itemIdentity
            let note: String
            if hasSensitiveSettings {
                note = "Kept unavailable because this helper stores environment or sign-in settings."
            } else if incomplete {
                note = "Kept unavailable because Mac Cleaner could not fully inspect the helper."
            } else {
                note = "This login helper points into the app bundle. Moving it may disable an automatic background feature."
            }
            return ApplicationDataCandidate(
                bundleIdentifier: appIdentifier,
                locationIdentifier: locationIdentifier,
                location: .loginAgent,
                url: url.standardizedFileURL,
                identity: itemIdentity,
                logicalSize: inspection.bytes,
                sizeIncomplete: incomplete,
                isDirectory: false,
                safeToMove: !incomplete,
                safetyNote: note
            )
        }
    }

    private func launchAgentDictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), data.count <= 1_000_000,
              let dictionary = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else { return nil }
        return dictionary
    }

    private func launchAgentProgram(in dictionary: [String: Any]) -> String? {
        let candidate = (dictionary["Program"] as? String) ?? (dictionary["ProgramArguments"] as? [String])?.first
        guard let candidate, candidate.hasPrefix("/"), !candidate.contains("\0") else { return nil }
        return URL(fileURLWithPath: candidate).standardizedFileURL.path
    }

    private func containsSensitiveLaunchSettings(_ dictionary: [String: Any]) -> Bool {
        let sensitiveKeys = ["environmentvariables", "password", "token", "secret", "credential", "authorization", "cookie", "privatekey"]
        for (key, value) in dictionary {
            let lowered = key.lowercased()
            if sensitiveKeys.contains(where: lowered.contains) { return true }
            if let nested = value as? [String: Any], containsSensitiveLaunchSettings(nested) { return true }
            if let values = value as? [[String: Any]], values.contains(where: containsSensitiveLaunchSettings) { return true }
        }
        return false
    }

    private func loginAgentPointsIntoApp(_ url: URL, app: InstalledApplication) -> Bool {
        let library = home.appendingPathComponent("Library", isDirectory: true).standardizedFileURL
        let root = library.appendingPathComponent("LaunchAgents", isDirectory: true)
        guard let dictionary = launchAgentDictionary(at: url),
              let program = launchAgentProgram(in: dictionary),
              let label = dictionary["Label"] as? String,
              label.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
              !label.contains(".."),
              url.pathExtension.lowercased() == "plist",
              SafeFilePolicy.isInside(url.standardizedFileURL.path, root: root.path),
              SafeFilePolicy.hasNoSymlinkedParent(path: url.standardizedFileURL.path, root: root.path),
              SafeFilePolicy.hasNoSymlinkedParent(path: program, root: app.url.standardizedFileURL.path),
              SafeFilePolicy.isInside(program, root: app.url.standardizedFileURL.path) else { return false }
        return true
    }

    private func inspectData(_ root: URL, isDirectory: Bool, maximumEntries: Int = 100_000) -> (bytes: Int64, incomplete: Bool, containsSensitiveData: Bool, entriesInspected: Int) {
        let packageExtensions: Set<String> = ["app", "appex", "bundle", "framework", "plugin", "xpc", "pkg", "photoslibrary", "sparsebundle"]
        var containsSensitiveData = isSensitiveDataName(root)
        if isDirectory && containsSensitiveData { return (0, true, true, 0) }
        guard isDirectory else { return (identity(root.path)?.size ?? 0, identity(root.path) == nil, containsSensitiveData, 1) }
        var incomplete = false
        var bytes: Int64 = 0
        var visited = 0
        var pendingDirectories = [root]
        while let directory = pendingDirectories.popLast() {
            let handle: UnsafeMutablePointer<DIR>?
            switch FileScanner.directoryOpener.open(directory.path, timeout: 2) {
            case .opened(let descriptor):
                handle = Darwin.fdopendir(descriptor)
                if handle == nil { _ = Darwin.close(descriptor) }
            case .failed(_), .timedOut, .busy:
                handle = nil
                incomplete = true
            }
            guard let handle else { continue }
            defer { Darwin.closedir(handle) }

            while true {
                errno = 0
                guard let entry = Darwin.readdir(handle) else {
                    if errno != 0 { incomplete = true }
                    break
                }
                let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                        String(cString: $0)
                    }
                }
                guard !name.isEmpty, name != ".", name != ".." else { continue }
                visited += 1
                guard visited <= maximumEntries else { incomplete = true; return (bytes, true, containsSensitiveData, visited) }
                let child = directory.appendingPathComponent(name)
                if isSensitiveDataName(child) {
                    containsSensitiveData = true
                    return (bytes, true, true, visited)
                }
                var info = Darwin.stat()
                guard child.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { incomplete = true; continue }
                let kind = info.st_mode & S_IFMT
                if kind == S_IFLNK { continue }
                if kind == S_IFDIR {
                    if packageExtensions.contains(child.pathExtension.lowercased()) {
                        incomplete = true
                    } else {
                        pendingDirectories.append(child)
                    }
                } else if kind == S_IFREG {
                    bytes += Int64(info.st_size)
                }
            }
        }
        return (bytes, incomplete, containsSensitiveData, visited)
    }

    private func isSensitiveDataName(_ url: URL) -> Bool {
        let protectedMarkers = [".git", ".hg", ".svn", ".ssh", ".aws", ".azure", ".kube", ".codex", ".claude", ".cursor", ".gemini", "credential", "password", "keychain", "cookie", "login data", "web data", "token", "auth", "session", "history", "conversation", "message", "mail", "project", "document", "download", "photo", "model", "weight", "memory", "secret", "cloud", "icloud", "sync", "mobile documents", "dropbox", "onedrive", "google drive"]
        let name = url.lastPathComponent.lowercased()
        let fileExtension = url.pathExtension.lowercased()
        return protectedMarkers.contains(where: name.contains)
            || ["pem", "key", "p12", "pfx", "mobileprovision"].contains(fileExtension)
            || name == ".env"
            || name.hasPrefix(".env.")
    }

    private func bundleIdentifier(at plist: URL) -> String? {
        guard let data = try? Data(contentsOf: plist), data.count <= 1_000_000,
              let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }

    private func identity(_ path: String) -> ApplicationPathIdentity? {
        var info = Darwin.stat()
        guard path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return nil }
        return ApplicationPathIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size), mode: UInt32(info.st_mode), modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec), changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
}
