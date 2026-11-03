import Foundation
import Security

struct InstalledApplication: Identifiable, Sendable {
    let url: URL
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let logicalSize: Int64
    let sizeIncomplete: Bool
    var id: String { url.path }
}

struct ApplicationInventoryResult: Sendable {
    let applications: [InstalledApplication]
    let inaccessibleLocations: Int
    let wasLimited: Bool
    let wasCancelled: Bool

    var isComplete: Bool { inaccessibleLocations == 0 && !wasLimited && !wasCancelled }
}

struct ApplicationBundleIdentifierInventory: Sendable {
    let identifiers: Set<String>
    let unreadableLocations: Int
    let wasLimited: Bool
    let groupOwners: [String: [ApplicationGroupOwner]]
    let groupOwnershipIncomplete: Bool

    init(
        identifiers: Set<String>,
        unreadableLocations: Int,
        wasLimited: Bool,
        groupOwners: [String: [ApplicationGroupOwner]] = [:],
        groupOwnershipIncomplete: Bool = false
    ) {
        self.identifiers = identifiers
        self.unreadableLocations = unreadableLocations
        self.wasLimited = wasLimited
        self.groupOwners = groupOwners
        self.groupOwnershipIncomplete = groupOwnershipIncomplete
    }

    var isComplete: Bool { unreadableLocations == 0 && !wasLimited }
}

struct ApplicationGroupOwner: Equatable, Hashable, Identifiable, Sendable {
    let bundleIdentifier: String
    let applicationName: String
    let applicationURL: URL

    var id: String { applicationURL.standardizedFileURL.path }
}

struct ApplicationGroupContainer: Identifiable, Sendable {
    let groupIdentifier: String
    let url: URL
    let owners: [ApplicationGroupOwner]

    var id: String { url.standardizedFileURL.path }
}

struct ApplicationGroupContainerScanResult: Sendable {
    let containers: [ApplicationGroupContainer]
    let unreadableLocations: Int
    let wasLimited: Bool
    let ownershipEvidenceIncomplete: Bool
}

enum ApplicationGroupEntitlementReader {
    private static let entitlementKey = "com.apple.security.application-groups"
    private static let signingInformationFlags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
    private static let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)

    static func readGroupIdentifiers(from applicationURL: URL) -> Set<String>? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(applicationURL as CFURL, SecCSFlags(rawValue: 0), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else { return nil }

        var rawInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(staticCode, signingInformationFlags, &rawInformation)
        if informationStatus == errSecCSUnsigned { return [] }
        guard informationStatus == errSecSuccess,
              SecStaticCodeCheckValidity(staticCode, validationFlags, nil) == errSecSuccess,
              let information = rawInformation as? [String: Any] else { return nil }

        if let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            return groupIdentifiers(in: entitlements)
        }

        // Some valid signatures expose entitlements as a property-list blob instead
        // of a standard dictionary. If it cannot be decoded, ownership is unknown.
        if let entitlementData = information[kSecCodeInfoEntitlements as String] as? Data {
            guard let propertyList = try? PropertyListSerialization.propertyList(from: entitlementData, options: [], format: nil),
                  let entitlements = propertyList as? [String: Any] else { return nil }
            return groupIdentifiers(in: entitlements)
        }

        // A successful signing-information query with neither representation means
        // this signed app declares no entitlements in a form macOS returned.
        return []
    }

    static func groupIdentifiers(in entitlements: [String: Any]) -> Set<String>? {
        guard let value = entitlements[entitlementKey] else { return [] }
        guard let identifiers = value as? [String], identifiers.allSatisfy(isValidGroupIdentifier) else { return nil }
        return Set(identifiers)
    }

    private static func isValidGroupIdentifier(_ identifier: String) -> Bool {
        identifier.count <= 255
            && identifier.range(of: "^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)+$", options: .regularExpression) != nil
            && !identifier.contains("..")
    }
}

struct ApplicationInventory {
    func scan(
        roots: [URL],
        includeSizes: Bool = true,
        maximumVisitedEntries: Int = 250_000,
        maximumSizeEntries: Int = 250_000,
        maximumApplications: Int = 20_000,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> ApplicationInventoryResult {
        let fm = FileManager.default
        var apps: [InstalledApplication] = []
        var seen = Set<String>()
        var inaccessible = 0
        var wasLimited = false
        var wasCancelled = false
        let inventoryBudget = InventoryWorkBudget(maximumEntries: maximumVisitedEntries)
        let sizeBudget = InventoryWorkBudget(maximumEntries: maximumSizeEntries)

        inventory: for root in roots {
            guard !isCancelled() else { wasCancelled = true; break }
            if !fm.fileExists(atPath: root.path) { continue }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in inaccessible += 1; return true }) else {
                inaccessible += 1
                continue
            }
            for case let url as URL in enumerator {
                guard !isCancelled() else {
                    wasCancelled = true
                    enumerator.skipDescendants()
                    break inventory
                }
                guard inventoryBudget.consumeEntry() else {
                    wasLimited = true
                    enumerator.skipDescendants()
                    break inventory
                }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard values?.isDirectory == true else { continue }
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted, let bundle = Bundle(url: url), bundle.bundleIdentifier != nil else { continue }
                guard apps.count < max(0, maximumApplications) else {
                    wasLimited = true
                    break inventory
                }
                let info = bundle.infoDictionary ?? [:]
                let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
                let size: (bytes: Int64, incomplete: Bool, wasLimited: Bool, wasCancelled: Bool) = includeSizes
                    ? bundleSize(at: url, budget: sizeBudget, isCancelled: isCancelled)
                    : (0, false, false, false)
                apps.append(InstalledApplication(url: url, name: name, bundleIdentifier: bundle.bundleIdentifier, version: info["CFBundleShortVersionString"] as? String, logicalSize: size.bytes, sizeIncomplete: size.incomplete))
                wasLimited = wasLimited || size.wasLimited
                if size.wasCancelled {
                    wasCancelled = true
                    break inventory
                }
            }
        }
        return ApplicationInventoryResult(
            applications: apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            inaccessibleLocations: inaccessible,
            wasLimited: wasLimited,
            wasCancelled: wasCancelled
        )
    }

    func bundleIdentifiers(
        roots: [URL],
        maximumApplications: Int = 20_000,
        maximumVisitedEntries: Int = 250_000,
        includeSignedGroupOwnership: Bool = true,
        progress: @Sendable (String, Int) -> Void = { _, _ in }
    ) -> ApplicationBundleIdentifierInventory {
        var identifiers = Set<String>()
        var unreadable = 0
        var wasLimited = false
        var groupOwnershipIncomplete = !includeSignedGroupOwnership
        var groupOwners: [String: [ApplicationGroupOwner]] = [:]
        var seenApplicationPaths = Set<String>()
        var visitedEntries = 0
        var visitedApplications = 0
        let fileManager = FileManager.default

        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: { _, _ in unreadable += 1; return true }
            ) else {
                unreadable += 1
                continue
            }

            for case let url as URL in enumerator {
                visitedEntries += 1
                if visitedEntries > maximumVisitedEntries {
                    wasLimited = true
                    break
                }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                    unreadable += 1
                    continue
                }
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard values.isDirectory == true, url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                guard seenApplicationPaths.insert(url.standardizedFileURL.path).inserted else { continue }
                if visitedApplications >= maximumApplications {
                    wasLimited = true
                    break
                }
                visitedApplications += 1

                guard let bundle = Bundle(url: url) else {
                    unreadable += 1
                    groupOwnershipIncomplete = true
                    continue
                }
                let info = bundle.infoDictionary ?? [:]
                let name = (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                progress(name, visitedApplications)
                guard let identifier = bundle.bundleIdentifier else {
                    unreadable += 1
                    groupOwnershipIncomplete = true
                    continue
                }
                let normalizedIdentifier = identifier.lowercased()
                identifiers.insert(normalizedIdentifier)

                guard includeSignedGroupOwnership else { continue }
                guard let declaredGroups = ApplicationGroupEntitlementReader.readGroupIdentifiers(from: url) else {
                    groupOwnershipIncomplete = true
                    continue
                }
                let owner = ApplicationGroupOwner(
                    bundleIdentifier: identifier,
                    applicationName: name,
                    applicationURL: url.standardizedFileURL
                )
                for groupIdentifier in declaredGroups {
                    groupOwners[groupIdentifier, default: []].append(owner)
                }
            }
            if wasLimited { break }
        }

        return ApplicationBundleIdentifierInventory(
            identifiers: identifiers,
            unreadableLocations: unreadable,
            wasLimited: wasLimited,
            groupOwners: groupOwners.mapValues {
                $0.sorted {
                    let nameOrder = $0.applicationName.localizedStandardCompare($1.applicationName)
                    if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                    let identifierOrder = $0.bundleIdentifier.localizedStandardCompare($1.bundleIdentifier)
                    if identifierOrder != .orderedSame { return identifierOrder == .orderedAscending }
                    return $0.applicationURL.path < $1.applicationURL.path
                }
            },
            groupOwnershipIncomplete: groupOwnershipIncomplete || unreadable > 0 || wasLimited
        )
    }

    private func bundleSize(
        at root: URL,
        budget: InventoryWorkBudget,
        isCancelled: @Sendable () -> Bool
    ) -> (bytes: Int64, incomplete: Bool, wasLimited: Bool, wasCancelled: Bool) {
        var incomplete = false
        guard !budget.isExhausted else { return (0, true, true, false) }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [], errorHandler: { _, _ in incomplete = true; return true }) else { return (0, true, false, false) }
        var size: Int64 = 0
        for case let url as URL in enumerator {
            guard !isCancelled() else { return (size, true, false, true) }
            guard budget.consumeEntry() else { return (size, true, true, false) }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { incomplete = true; continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isRegularFile == true { size += Int64(values.fileSize ?? 0) }
        }
        return (size, incomplete, false, false)
    }
}

private final class InventoryWorkBudget {
    private let maximumEntries: Int
    private var visitedEntries = 0
    var isExhausted: Bool { visitedEntries >= maximumEntries }

    init(maximumEntries: Int) {
        self.maximumEntries = max(0, maximumEntries)
    }

    func consumeEntry() -> Bool {
        guard visitedEntries < maximumEntries else { return false }
        visitedEntries += 1
        return true
    }
}
