import CoreFoundation
import Foundation
import Security

enum ApplicationSignatureStatus: String, CaseIterable, Sendable {
    case signatureMatches
    case signatureMatchesWithoutTeamID
    case noSignature
    case couldNotValidate
    case couldNotInspect

    var requiresReview: Bool {
        switch self {
        case .noSignature, .couldNotValidate, .couldNotInspect: true
        case .signatureMatches, .signatureMatchesWithoutTeamID: false
        }
    }

    var title: String {
        switch self {
        case .signatureMatches: "Bundle integrity verified"
        case .signatureMatchesWithoutTeamID: "Bundle verified · no Team ID"
        case .noSignature: "No code signature"
        case .couldNotValidate: "Bundle integrity could not be verified"
        case .couldNotInspect: "Could not inspect app bundle"
        }
    }

    var explanation: String {
        switch self {
        case .signatureMatches:
            "macOS verified the app signature, sealed resources, and embedded code. This does not establish that the app is trustworthy or free of malware."
        case .signatureMatchesWithoutTeamID:
            "macOS verified the app signature, sealed resources, and embedded code, but there is no developer Team ID. Local development builds can look this way."
        case .noSignature:
            "No code signature was found for this app. This alone does not mean the app is harmful."
        case .couldNotValidate:
            "macOS could not verify the app signature and its sealed contents. The app may be incomplete, changed, or unreadable."
        case .couldNotInspect:
            "macOS did not provide enough information to check this app bundle."
        }
    }
}

struct ApplicationSignatureFinding: Identifiable, Sendable {
    let application: InstalledApplication
    let status: ApplicationSignatureStatus
    let teamIdentifier: String?

    var id: String { application.id }
}

struct StartupSecurityReviewFinding: Identifiable, Sendable {
    let item: StartupItem
    let reasons: [String]

    var id: String { item.id }
}

enum StartupSecurityReviewPolicy {
    static func findings(for items: [StartupItem]) -> [StartupSecurityReviewFinding] {
        items.compactMap { item in
            let reasons = reasons(for: item)
            return reasons.isEmpty ? nil : StartupSecurityReviewFinding(item: item, reasons: reasons)
        }
    }

    static func reasons(
        for item: StartupItem,
        homeDirectory: URL = SafeFilePolicy.accountHome
    ) -> [String] {
        var reasons: [String] = []
        if item.authorization == "Needs approval" {
            reasons.append("macOS says this startup item needs your approval.")
        }

        // Apple launch definitions and helpers are maintained by macOS and can
        // use signing arrangements that do not map cleanly to a third-party
        // review. They are included only when approval is explicitly needed.
        guard !item.mechanism.localizedCaseInsensitiveContains("Apple") else { return reasons }

        guard let assessment = item.signatureAssessment else {
            reasons.append("This definition has no direct program path, so its code signature could not be checked. This is not a malware verdict.")
            return reasons
        }
        switch assessment.status {
        case .verified:
            break
        case .unsigned:
            reasons.append("No code signature was found. This alone does not mean the item is harmful.")
        case .invalid:
            reasons.append("macOS could not verify the listed program. Review its path; this is not a malware verdict.")
        case .unavailable:
            reasons.append("The listed program could not be checked. This is not a malware verdict.")
        }
        if let program = item.program,
           let locationReason = launchLocationReason(for: program, homeDirectory: homeDirectory) {
            reasons.append(locationReason)
        }
        return reasons
    }

    private static func launchLocationReason(for program: String, homeDirectory: URL) -> String? {
        let programURL = URL(fileURLWithPath: program)
        let programPaths = pathCandidates(for: programURL)
        let temporaryRoots = [
            "/tmp",
            "/private/tmp",
            "/var/tmp",
            NSTemporaryDirectory()
        ].flatMap { pathCandidates(for: URL(fileURLWithPath: $0, isDirectory: true)) }
        if programPaths.contains(where: { path in
            temporaryRoots.contains(where: { isAtOrBelow(path, root: $0) })
        }) {
            return "This startup item runs code from a temporary folder. Check that the path is intentional; this location alone is not a malware verdict."
        }

        let downloadsRoot = homeDirectory.appendingPathComponent("Downloads", isDirectory: true)
        let downloadsRoots = pathCandidates(for: downloadsRoot)
        if programPaths.contains(where: { path in
            downloadsRoots.contains(where: { isAtOrBelow(path, root: $0) })
        }) {
            return "This startup item runs code from Downloads. Confirm you meant to keep it there; this location alone is not a malware verdict."
        }
        return nil
    }

    private static func pathCandidates(for url: URL) -> [String] {
        let original = url.path
        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        return Array(Set([original, standardized.path, resolved.path].map(trimTrailingSlash)))
    }

    private static func trimTrailingSlash(_ path: String) -> String {
        guard path.count > 1 else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func isAtOrBelow(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

struct ApplicationSecurityAuditReport: Sendable {
    let findings: [ApplicationSignatureFinding]
    let startupFindings: [StartupSecurityReviewFinding]
    let skippedStartupItems: Int
    let inaccessibleLocations: Int
    let wasLimited: Bool
    let wasCancelled: Bool

    var matchingSignatures: Int {
        findings.filter { $0.status == .signatureMatches || $0.status == .signatureMatchesWithoutTeamID }.count
    }

    var missingSignatures: Int {
        findings.filter { $0.status == .noSignature }.count
    }

    var couldNotVerify: Int {
        findings.filter { $0.status == .couldNotValidate || $0.status == .couldNotInspect }.count
    }
}

struct ApplicationSecurityActivitySummary: Equatable, Sendable {
    let checkedApps: Int
    let verifiedSignatures: Int
    let missingSignatures: Int
    let appsNotVerified: Int
    let startupItemsForReview: Int
    let skippedStartupItems: Int
    let inaccessibleLocations: Int
    let wasLimited: Bool
    let wasCancelled: Bool

    init(report: ApplicationSecurityAuditReport) {
        checkedApps = report.findings.count
        verifiedSignatures = report.matchingSignatures
        missingSignatures = report.missingSignatures
        appsNotVerified = report.couldNotVerify
        startupItemsForReview = report.startupFindings.count
        skippedStartupItems = report.skippedStartupItems
        inaccessibleLocations = report.inaccessibleLocations
        wasLimited = report.wasLimited
        wasCancelled = report.wasCancelled
    }

    var title: String {
        isIncomplete ? (wasCancelled ? "App Security check stopped" : "App Security results incomplete") : "App Security check completed"
    }

    var note: String {
        let prefix = isIncomplete ? "Partial results. " : ""
        let signatures = "\(verifiedSignatures) \(verifiedSignatures == 1 ? "signature" : "signatures") verified"
        let unsignedApps = "\(missingSignatures) \(missingSignatures == 1 ? "app has" : "apps have") no signature"
        let unverifiableApps = "\(appsNotVerified) \(appsNotVerified == 1 ? "app could" : "apps could") not be verified"
        let startupItems = "\(startupItemsForReview) \(startupItemsForReview == 1 ? "startup item" : "startup items") flagged for review"
        return "\(prefix)\(signatures); \(unsignedApps); \(unverifiableApps); \(startupItems). No files were changed."
    }

    private var isIncomplete: Bool {
        wasCancelled || wasLimited || skippedStartupItems > 0 || inaccessibleLocations > 0
    }
}

struct ApplicationSecurityAuditProgress: Sendable {
    enum Phase: Equatable, Sendable {
        case applications
        case startupDefinitions
    }

    let completed: Int
    let total: Int
    let applicationName: String
    let phase: Phase

    init(completed: Int, total: Int, applicationName: String, phase: Phase = .applications) {
        self.completed = completed
        self.total = total
        self.applicationName = applicationName
        self.phase = phase
    }
}

struct ApplicationSecurityAuditService: Sendable {
    static var standardApplicationRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            SafeFilePolicy.accountHome.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true)
        ]
    }

    static func standardStartupLocations() -> [(url: URL, mechanism: String)] {
        StartupInventory.standardLocations().filter {
            !$0.mechanism.localizedCaseInsensitiveContains("Apple")
        }
    }

    static var validationFlags: SecCSFlags {
        SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    }

    func scan(
        roots: [URL],
        startupLocations: [(url: URL, mechanism: String)] = [],
        maximumVisitedEntries: Int = 250_000,
        maximumApplications: Int = 20_000,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled },
        progress: @Sendable (ApplicationSecurityAuditProgress) -> Void = { _ in }
    ) -> ApplicationSecurityAuditReport {
        let inventory = ApplicationInventory().scan(
            roots: roots,
            includeSizes: false,
            maximumVisitedEntries: maximumVisitedEntries,
            maximumApplications: maximumApplications,
            isCancelled: isCancelled
        )
        let startupApplicationBundles = inventory.applications.map(\.url)
        guard !inventory.wasCancelled, !isCancelled() else {
            return ApplicationSecurityAuditReport(
                findings: [],
                startupFindings: [],
                skippedStartupItems: 0,
                inaccessibleLocations: inventory.inaccessibleLocations,
                wasLimited: inventory.wasLimited,
                wasCancelled: true
            )
        }
        var findings: [ApplicationSignatureFinding] = []
        for (index, application) in inventory.applications.enumerated() {
            guard !isCancelled() else {
                return ApplicationSecurityAuditReport(
                    findings: findings,
                    startupFindings: [],
                    skippedStartupItems: 0,
                    inaccessibleLocations: inventory.inaccessibleLocations,
                    wasLimited: inventory.wasLimited,
                    wasCancelled: true
                )
            }
            progress(ApplicationSecurityAuditProgress(
                completed: index + 1,
                total: inventory.applications.count,
                applicationName: application.name,
                phase: .applications
            ))
            findings.append(inspect(application))
        }

        guard !isCancelled() else {
            return ApplicationSecurityAuditReport(
                findings: findings,
                startupFindings: [],
                skippedStartupItems: 0,
                inaccessibleLocations: inventory.inaccessibleLocations,
                wasLimited: inventory.wasLimited,
                wasCancelled: true
            )
        }

        let startupResult: StartupInventoryResult
        if startupLocations.isEmpty && startupApplicationBundles.isEmpty {
            startupResult = StartupInventoryResult(items: [], skipped: 0, wasCancelled: false)
        } else {
            progress(ApplicationSecurityAuditProgress(
                completed: 0,
                total: startupLocations.count + startupApplicationBundles.count,
                applicationName: "startup items",
                phase: .startupDefinitions
            ))
            startupResult = StartupInventory().scan(
                locations: startupLocations,
                applicationBundles: startupApplicationBundles,
                isCancelled: isCancelled,
                progress: { startupProgress in
                    progress(ApplicationSecurityAuditProgress(
                        completed: startupProgress.currentLocation,
                        total: startupProgress.totalLocations,
                        applicationName: startupProgress.mechanism,
                        phase: .startupDefinitions
                    ))
                }
            )
        }
        return ApplicationSecurityAuditReport(
            findings: findings,
            startupFindings: StartupSecurityReviewPolicy.findings(for: startupResult.items),
            skippedStartupItems: startupResult.skipped,
            inaccessibleLocations: inventory.inaccessibleLocations,
            wasLimited: inventory.wasLimited,
            wasCancelled: startupResult.wasCancelled
        )
    }

    private func inspect(_ application: InstalledApplication) -> ApplicationSignatureFinding {
        var code: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(application.url as CFURL, SecCSFlags(rawValue: 0), &code)
        guard createStatus == errSecSuccess, let code else {
            return ApplicationSignatureFinding(application: application, status: .couldNotInspect, teamIdentifier: nil)
        }

        var rawInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        )
        if informationStatus == errSecCSUnsigned {
            return ApplicationSignatureFinding(application: application, status: .noSignature, teamIdentifier: nil)
        }
        guard informationStatus == errSecSuccess,
              let information = rawInformation as? [String: Any] else {
            return ApplicationSignatureFinding(application: application, status: .couldNotInspect, teamIdentifier: nil)
        }

        let identifier = information[kSecCodeInfoIdentifier as String] as? String
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String
        guard identifier != nil else {
            return ApplicationSignatureFinding(application: application, status: .noSignature, teamIdentifier: nil)
        }

        // Include sealed resources and nested code so this is a bundle-integrity check,
        // not just a check of the main executable. This can take longer for large apps.
        let validityStatus = SecStaticCodeCheckValidity(code, Self.validationFlags, nil)
        let status = Self.classify(
            hasSigningIdentifier: true,
            hasTeamIdentifier: teamIdentifier?.isEmpty == false,
            validityStatus: validityStatus
        )
        return ApplicationSignatureFinding(application: application, status: status, teamIdentifier: teamIdentifier)
    }

    static func classify(
        hasSigningIdentifier: Bool,
        hasTeamIdentifier: Bool,
        validityStatus: OSStatus?
    ) -> ApplicationSignatureStatus {
        guard hasSigningIdentifier else { return .noSignature }
        guard let validityStatus else { return .couldNotInspect }
        guard validityStatus == errSecSuccess else { return .couldNotValidate }
        return hasTeamIdentifier ? .signatureMatches : .signatureMatchesWithoutTeamID
    }
}
