import Security
import XCTest
@testable import MacCleaner

private final class ApplicationSecurityProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ApplicationSecurityAuditProgress] = []

    func append(_ value: ApplicationSecurityAuditProgress) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [ApplicationSecurityAuditProgress] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class ApplicationSecurityAuditTests: XCTestCase {
    func testMissingCodeSignatureIsNotReportedAsMalware() {
        XCTAssertEqual(
            ApplicationSecurityAuditService.classify(
                hasSigningIdentifier: false,
                hasTeamIdentifier: false,
                validityStatus: errSecCSUnsigned
            ),
            .noSignature
        )
        XCTAssertTrue(ApplicationSignatureStatus.noSignature.requiresReview)
        XCTAssertTrue(ApplicationSignatureStatus.noSignature.explanation.contains("not mean the app is harmful"))
    }

    func testValidSignatureDistinguishesDeveloperTeamIdentifier() {
        XCTAssertEqual(
            ApplicationSecurityAuditService.classify(
                hasSigningIdentifier: true,
                hasTeamIdentifier: true,
                validityStatus: errSecSuccess
            ),
            .signatureMatches
        )
        XCTAssertEqual(
            ApplicationSecurityAuditService.classify(
                hasSigningIdentifier: true,
                hasTeamIdentifier: false,
                validityStatus: errSecSuccess
            ),
            .signatureMatchesWithoutTeamID
        )
        XCTAssertFalse(ApplicationSignatureStatus.signatureMatches.requiresReview)
    }

    func testInvalidAndUnavailableSignaturesRemainDistinct() {
        XCTAssertEqual(
            ApplicationSecurityAuditService.classify(
                hasSigningIdentifier: true,
                hasTeamIdentifier: true,
                validityStatus: errSecCSBadResource
            ),
            .couldNotValidate
        )
        XCTAssertEqual(
            ApplicationSecurityAuditService.classify(
                hasSigningIdentifier: true,
                hasTeamIdentifier: false,
                validityStatus: nil
            ),
            .couldNotInspect
        )
    }

    func testBundleValidationChecksEveryArchitectureResourcesAndNestedCode() {
        let flags = ApplicationSecurityAuditService.validationFlags.rawValue
        XCTAssertNotEqual(flags & kSecCSCheckAllArchitectures, 0)
        XCTAssertNotEqual(flags & kSecCSStrictValidate, 0)
        XCTAssertNotEqual(flags & kSecCSCheckNestedCode, 0)
        XCTAssertEqual(flags & kSecCSDoNotValidateResources, 0)
    }

    func testActivitySummaryContainsAggregateCountsWithoutAppNamesOrPaths() {
        let first = installedApplication(name: "Private App Name", identifier: "org.private.example")
        let second = installedApplication(name: "Second Private App", identifier: "org.private.second")
        let third = installedApplication(name: "Third Private App", identifier: "org.private.third")
        let startup = startupItem(
            mechanism: "User launch agent",
            program: "/Users/example/Private App Name/helper",
            assessment: StartupSignatureAssessment(status: .unsigned, teamIdentifier: nil)
        )
        let report = ApplicationSecurityAuditReport(
            findings: [
                ApplicationSignatureFinding(application: first, status: .signatureMatches, teamIdentifier: "TEAM123"),
                ApplicationSignatureFinding(application: second, status: .noSignature, teamIdentifier: nil),
                ApplicationSignatureFinding(application: third, status: .couldNotValidate, teamIdentifier: nil),
                ApplicationSignatureFinding(application: installedApplication(name: "Fourth App", identifier: "org.private.fourth"), status: .couldNotInspect, teamIdentifier: nil)
            ],
            startupFindings: [StartupSecurityReviewFinding(item: startup, reasons: ["Review this item."])],
            skippedStartupItems: 0,
            inaccessibleLocations: 0,
            wasLimited: false,
            wasCancelled: false
        )

        let summary = ApplicationSecurityActivitySummary(report: report)

        XCTAssertEqual(summary.checkedApps, 4)
        XCTAssertEqual(summary.verifiedSignatures, 1)
        XCTAssertEqual(summary.missingSignatures, 1)
        XCTAssertEqual(summary.appsNotVerified, 2)
        XCTAssertEqual(summary.startupItemsForReview, 1)
        XCTAssertEqual(summary.title, "App Security check completed")
        XCTAssertTrue(summary.note.contains("1 signature verified"))
        XCTAssertTrue(summary.note.contains("1 app has no signature"))
        XCTAssertTrue(summary.note.contains("2 apps could not be verified"))
        XCTAssertTrue(summary.note.contains("1 startup item flagged for review"))
        XCTAssertTrue(summary.note.contains("No files were changed."))
        for privateValue in ["Private App Name", "org.private.example", "/Users/example"] {
            XCTAssertFalse(summary.note.contains(privateValue))
        }
    }

    func testCancelledSecurityActivitySummaryIsMarkedPartialAndStopped() {
        let app = installedApplication(name: "Checked App", identifier: "org.example.checked")
        let report = ApplicationSecurityAuditReport(
            findings: [ApplicationSignatureFinding(application: app, status: .signatureMatches, teamIdentifier: nil)],
            startupFindings: [],
            skippedStartupItems: 0,
            inaccessibleLocations: 0,
            wasLimited: false,
            wasCancelled: true
        )

        let summary = ApplicationSecurityActivitySummary(report: report)

        XCTAssertTrue(summary.wasCancelled)
        XCTAssertEqual(summary.title, "App Security check stopped")
        XCTAssertTrue(summary.note.hasPrefix("Partial results."))
    }

    func testScanReportsProgressAndSeparatesUnsignedAppsFromUnreadableApps() throws {
        let root = try temporaryFolder()
        let appURL = root.appendingPathComponent("Example.app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let executableFolder = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executableFolder, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "test.example.mac-cleaner-security",
            "CFBundleExecutable": "Example",
            "CFBundleName": "Example",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("unsigned fixture".utf8).write(to: executableFolder.appendingPathComponent("Example"))
        let progress = ApplicationSecurityProgressRecorder()

        let report = ApplicationSecurityAuditService().scan(roots: [root], progress: { value in
            progress.append(value)
        })

        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings.first?.status, .noSignature)
        XCTAssertFalse(report.wasCancelled)
        XCTAssertEqual(progress.values.map(\.completed), [1, 0, 1])
        XCTAssertEqual(progress.values.first?.total, 1)
        XCTAssertEqual(progress.values.first?.applicationName, "Example")
    }

    func testCancelledBundleAuditDoesNotClaimItFinished() throws {
        let root = try temporaryFolder()

        let report = ApplicationSecurityAuditService().scan(roots: [root], isCancelled: { true })

        XCTAssertTrue(report.wasCancelled)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testLimitedApplicationInventoryIsReportedAsIncomplete() throws {
        let root = try temporaryFolder()
        try Data("fixture".utf8).write(to: root.appendingPathComponent("item"))

        let report = ApplicationSecurityAuditService().scan(roots: [root], maximumVisitedEntries: 0)
        let summary = ApplicationSecurityActivitySummary(report: report)

        XCTAssertTrue(report.wasLimited)
        XCTAssertFalse(report.wasCancelled)
        XCTAssertEqual(summary.title, "App Security results incomplete")
        XCTAssertTrue(summary.note.hasPrefix("Partial results."))
    }

    func testStartupReviewFlagsUnsignedAndUnverifiableItemsWithoutCallingThemMalware() {
        let unsigned = startupItem(
            mechanism: "User launch agent",
            assessment: StartupSignatureAssessment(status: .unsigned, teamIdentifier: nil)
        )
        let missingPath = startupItem(mechanism: "User launch agent", assessment: nil)
        let invalid = startupItem(
            mechanism: "Shared launch daemon",
            assessment: StartupSignatureAssessment(status: .invalid, teamIdentifier: nil)
        )
        let unavailable = startupItem(
            mechanism: "Shared launch agent",
            assessment: StartupSignatureAssessment(status: .unavailable, teamIdentifier: nil)
        )
        let verified = startupItem(
            mechanism: "User launch agent",
            assessment: StartupSignatureAssessment(status: .verified, teamIdentifier: "ABCDE12345")
        )

        let findings = StartupSecurityReviewPolicy.findings(for: [unsigned, missingPath, invalid, unavailable, verified])

        XCTAssertEqual(findings.map(\.item.id), [unsigned.id, missingPath.id, invalid.id, unavailable.id])
        XCTAssertTrue(findings[0].reasons[0].contains("does not mean the item is harmful"))
        XCTAssertTrue(findings[1].reasons[0].contains("no direct program path"))
        XCTAssertTrue(findings[2].reasons[0].contains("not a malware verdict"))
        XCTAssertTrue(findings[3].reasons[0].contains("not a malware verdict"))
    }

    func testAppleLaunchDefinitionsAreNotFlaggedUnlessApprovalIsNeeded() {
        let unsignedApple = startupItem(
            mechanism: "Apple launch agent",
            assessment: StartupSignatureAssessment(status: .unsigned, teamIdentifier: nil)
        )
        let approvalRequiredApple = startupItem(
            mechanism: "Apple launch agent",
            authorization: "Needs approval",
            assessment: StartupSignatureAssessment(status: .verified, teamIdentifier: "APPLE")
        )

        XCTAssertTrue(StartupSecurityReviewPolicy.findings(for: [unsignedApple]).isEmpty)
        XCTAssertEqual(
            StartupSecurityReviewPolicy.findings(for: [approvalRequiredApple]).first?.reasons,
            ["macOS says this startup item needs your approval."]
        )
    }

    func testBundledHelpersDoNotClaimAnotherAppsRegistrationStatusIsKnown() {
        let helper = startupItem(
            mechanism: "App-bundled login item",
            authorization: "Registration status unavailable for another app",
            assessment: StartupSignatureAssessment(status: .verified, teamIdentifier: "ABCDE12345")
        )

        XCTAssertTrue(StartupSecurityReviewPolicy.findings(for: [helper]).isEmpty)
    }

    func testStartupReviewAddsContextForProgramsInTemporaryAndDownloadsFolders() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let temporary = startupItem(
            mechanism: "User launch agent",
            program: "/private/tmp/background-helper",
            assessment: StartupSignatureAssessment(status: .verified, teamIdentifier: "ABCDE12345")
        )
        let downloaded = startupItem(
            mechanism: "User launch agent",
            program: "/Users/example/Downloads/Example.app/Contents/MacOS/Example",
            assessment: StartupSignatureAssessment(status: .verified, teamIdentifier: "ABCDE12345")
        )
        let ordinary = startupItem(
            mechanism: "User launch agent",
            program: "/Applications/Example.app/Contents/MacOS/Example",
            assessment: StartupSignatureAssessment(status: .verified, teamIdentifier: "ABCDE12345")
        )

        let temporaryReasons = StartupSecurityReviewPolicy.reasons(for: temporary, homeDirectory: home)
        let downloadsReasons = StartupSecurityReviewPolicy.reasons(for: downloaded, homeDirectory: home)

        XCTAssertTrue(temporaryReasons.contains { $0.contains("temporary folder") })
        XCTAssertTrue(downloadsReasons.contains { $0.contains("from Downloads") })
        XCTAssertTrue(temporaryReasons.last?.contains("not a malware verdict") == true)
        XCTAssertTrue(StartupSecurityReviewPolicy.reasons(for: ordinary, homeDirectory: home).isEmpty)
    }

    func testStartupLocationHeuristicUsesFolderBoundariesAndSkipsAppleItems() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let downloadsArchive = startupItem(
            mechanism: "User launch agent",
            program: "/Users/example/DownloadsArchive/helper",
            assessment: StartupSignatureAssessment(status: .verified, teamIdentifier: "ABCDE12345")
        )
        let appleTemporaryItem = startupItem(
            mechanism: "Apple launch agent",
            program: "/private/tmp/apple-helper",
            assessment: StartupSignatureAssessment(status: .unsigned, teamIdentifier: nil)
        )

        XCTAssertTrue(StartupSecurityReviewPolicy.reasons(for: downloadsArchive, homeDirectory: home).isEmpty)
        XCTAssertTrue(StartupSecurityReviewPolicy.reasons(for: appleTemporaryItem, homeDirectory: home).isEmpty)
    }

    func testAuditIncludesStartupDefinitionsInItsReadOnlyReport() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("MacCleanerSecurityStartup-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let definition: [String: Any] = [
            "Label": "example.review-me",
            "ProgramArguments": ["relative-helper"]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
        try data.write(to: root.appendingPathComponent("review-me.plist"))
        let progress = ApplicationSecurityProgressRecorder()

        let report = ApplicationSecurityAuditService().scan(
            roots: [],
            startupLocations: [(root, "User launch agent")],
            progress: { progress.append($0) }
        )

        XCTAssertFalse(report.wasCancelled)
        XCTAssertEqual(report.startupFindings.count, 1)
        XCTAssertTrue(report.startupFindings[0].reasons[0].contains("no direct program path"))
        XCTAssertEqual(progress.values.last?.phase, .startupDefinitions)
        XCTAssertEqual(progress.values.last?.completed, 1)
    }

    func testAuditInspectsHelpersEmbeddedInsideInstalledApps() throws {
        let root = try temporaryFolder()
        let parentApp = root.appendingPathComponent("Example.app", isDirectory: true)
        let parentContents = parentApp.appendingPathComponent("Contents", isDirectory: true)
        let parentExecutableFolder = parentContents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: parentExecutableFolder, withIntermediateDirectories: true)
        try writeAppInfo(at: parentContents, name: "Example App", identifier: "test.example.parent", executable: "Example")
        try Data("unsigned parent".utf8).write(to: parentExecutableFolder.appendingPathComponent("Example"))
        let helperApp = parentContents.appendingPathComponent("Library/LoginItems/ExampleHelper.app", isDirectory: true)
        let helperContents = helperApp.appendingPathComponent("Contents", isDirectory: true)
        let helperExecutableFolder = helperContents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: helperExecutableFolder, withIntermediateDirectories: true)
        try writeAppInfo(at: helperContents, name: "Example Helper", identifier: "test.example.helper", executable: "ExampleHelper")
        try Data("unsigned helper".utf8).write(to: helperExecutableFolder.appendingPathComponent("ExampleHelper"))

        let report = ApplicationSecurityAuditService().scan(roots: [root])

        XCTAssertFalse(report.wasCancelled)
        XCTAssertEqual(report.startupFindings.count, 1)
        XCTAssertEqual(report.startupFindings[0].item.label, "test.example.helper")
        XCTAssertEqual(report.startupFindings[0].item.associatedApp, "Example App")
        XCTAssertEqual(report.startupFindings[0].item.authorization, "Registration status unavailable for another app")
        XCTAssertEqual(report.inaccessibleLocations, 0)
    }

    private func startupItem(
        mechanism: String,
        authorization: String = "Authorized",
        program: String = "/Applications/Example.app/Contents/MacOS/ExampleHelper",
        assessment: StartupSignatureAssessment?
    ) -> StartupItem {
        StartupItem(
            locationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).plist"),
            label: "example.startup",
            program: assessment == nil ? nil : program,
            mechanism: mechanism,
            associatedApp: nil,
            purpose: "Test item",
            configuration: "No disabled flag in file",
            launchConditions: ["Started on demand by macOS"],
            authorization: authorization,
            signatureAssessment: assessment
        )
    }

    private func installedApplication(name: String, identifier: String) -> InstalledApplication {
        InstalledApplication(
            url: URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true),
            name: name,
            bundleIdentifier: identifier,
            version: "1",
            logicalSize: 0,
            sizeIncomplete: false
        )
    }

    private func temporaryFolder() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeAppInfo(
        at contents: URL,
        name: String,
        identifier: String,
        executable: String? = nil
    ) throws {
        var info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1"
        ]
        if let executable { info["CFBundleExecutable"] = executable }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
