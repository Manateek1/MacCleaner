import Foundation

enum LocalProtectionSetting: String, CaseIterable, Hashable, Identifiable, Sendable {
    case fileVault
    case firewall
    case gatekeeper
    case systemIntegrity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fileVault: "FileVault"
        case .firewall: "Firewall"
        case .gatekeeper: "Gatekeeper app checks"
        case .systemIntegrity: "System Integrity Protection"
        }
    }

    var explanation: String {
        switch self {
        case .fileVault:
            "FileVault adds login-password protection for startup-disk data. This reports FileVault’s state; it does not measure every hardware encryption feature."
        case .firewall:
            "The firewall can block some unwanted incoming network connections. Allowed apps and services may still receive connections."
        case .gatekeeper:
            "Gatekeeper checks whether downloaded apps meet macOS launch-safety rules. This setting check is not a malware scan."
        case .systemIntegrity:
            "System Integrity Protection helps keep protected macOS files and folders from being changed, even by root."
        }
    }
}

enum LocalProtectionState: String, Equatable, Sendable {
    case enabled
    case disabled
    case unavailable

    var title: String {
        switch self {
        case .enabled: "On"
        case .disabled: "Off"
        case .unavailable: "Not reported"
        }
    }
}

struct LocalProtectionCheck: Identifiable, Equatable, Sendable {
    let setting: LocalProtectionSetting
    let state: LocalProtectionState

    var id: LocalProtectionSetting { setting }
    var title: String { setting.title }
    var explanation: String { setting.explanation }
}

struct LocalProtectionReport: Equatable, Sendable {
    let checks: [LocalProtectionCheck]
    let checkedAt: Date
}

/// Reads a small set of local macOS protection states. Commands are fixed,
/// read-only, and run without a shell or elevated privileges.
struct LocalProtectionStatusService: Sendable {
    typealias OutputReader = @Sendable (LocalProtectionSetting) -> String?

    private let readOutput: OutputReader

    init() {
        readOutput = { setting in Self.commandOutput(for: setting) }
    }

    init(readOutput: @escaping OutputReader) {
        self.readOutput = readOutput
    }

    func report(checkedAt: Date = .now) async -> LocalProtectionReport {
        let readOutput = self.readOutput
        return await Task.detached(priority: .utility) {
            var outputs: [LocalProtectionSetting: String?] = [:]
            for setting in LocalProtectionSetting.allCases {
                outputs[setting] = readOutput(setting)
            }
            return Self.parse(outputs, checkedAt: checkedAt)
        }.value
    }

    static func parse(
        _ outputs: [LocalProtectionSetting: String?],
        checkedAt: Date = .now
    ) -> LocalProtectionReport {
        let checks = LocalProtectionSetting.allCases.map { setting in
            LocalProtectionCheck(setting: setting, state: state(for: setting, output: outputs[setting] ?? nil))
        }
        return LocalProtectionReport(checks: checks, checkedAt: checkedAt)
    }

    private static func state(for setting: LocalProtectionSetting, output: String?) -> LocalProtectionState {
        guard let output else { return .unavailable }
        let normalized = output.lowercased()
        switch setting {
        case .fileVault:
            if normalized.contains("filevault is on") { return .enabled }
            if normalized.contains("filevault is off") { return .disabled }
        case .firewall:
            if normalized.contains("firewall is enabled") { return .enabled }
            if normalized.contains("firewall is disabled") { return .disabled }
        case .gatekeeper:
            if normalized.contains("assessments enabled") { return .enabled }
            if normalized.contains("assessments disabled") { return .disabled }
        case .systemIntegrity:
            if normalized.contains("system integrity protection status: enabled") { return .enabled }
            if normalized.contains("system integrity protection status: disabled") { return .disabled }
        }
        return .unavailable
    }

    private static func commandOutput(for setting: LocalProtectionSetting) -> String? {
        let executable: String
        let arguments: [String]
        switch setting {
        case .fileVault:
            executable = "/usr/bin/fdesetup"
            arguments = ["status"]
        case .firewall:
            executable = "/usr/libexec/ApplicationFirewall/socketfilterfw"
            arguments = ["--getglobalstate"]
        case .gatekeeper:
            executable = "/usr/sbin/spctl"
            arguments = ["--status"]
        case .systemIntegrity:
            executable = "/usr/bin/csrutil"
            arguments = ["status"]
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
