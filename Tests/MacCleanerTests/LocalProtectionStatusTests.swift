import XCTest
@testable import MacCleaner

final class LocalProtectionStatusTests: XCTestCase {
    func testReadOnlyReportParsesEnabledStatesAndKeepsStableOrder() async {
        let outputs: [LocalProtectionSetting: String] = [
            .fileVault: "FileVault is On.",
            .firewall: "Firewall is enabled. (State = 1)",
            .gatekeeper: "assessments enabled",
            .systemIntegrity: "System Integrity Protection status: enabled."
        ]
        let checkedAt = Date(timeIntervalSince1970: 1_793_500_000)
        let service = LocalProtectionStatusService(readOutput: { outputs[$0] })

        let report = await service.report(checkedAt: checkedAt)

        XCTAssertEqual(report.checkedAt, checkedAt)
        XCTAssertEqual(report.checks.map(\.setting), LocalProtectionSetting.allCases)
        XCTAssertEqual(report.checks.map(\.state), Array(repeating: .enabled, count: 4))
    }

    func testDisabledAndUnknownStatesAreNotReportedAsEnabled() {
        let report = LocalProtectionStatusService.parse([
            .fileVault: "FileVault is Off.",
            .firewall: "Firewall is disabled. (State = 0)",
            .gatekeeper: "assessments disabled",
            .systemIntegrity: "csrutil: unable to read system integrity status"
        ])

        XCTAssertEqual(report.checks.map(\.state), [.disabled, .disabled, .disabled, .unavailable])
    }

    func testMissingOrUnrecognizedOutputIsUnavailable() {
        let report = LocalProtectionStatusService.parse([
            .fileVault: "FileVault encryption is being prepared.",
            .firewall: "Firewall configuration could not be read."
        ])

        XCTAssertEqual(report.checks.map(\.state), Array(repeating: .unavailable, count: 4))
    }

    func testSystemStatusProbeReturnsAllSettingsWithoutAssumingTheirValues() async {
        let report = await LocalProtectionStatusService().report()

        XCTAssertEqual(report.checks.map(\.setting), LocalProtectionSetting.allCases)
        XCTAssertTrue(report.checks.allSatisfy { !$0.title.isEmpty && !$0.explanation.isEmpty })
    }
}
