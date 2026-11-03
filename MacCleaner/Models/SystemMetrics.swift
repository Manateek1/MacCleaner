import Foundation
import Dispatch

struct StorageSnapshot: Equatable, Sendable {
    let totalBytes: Int64
    let availableBytes: Int64

    static func current() -> StorageSnapshot {
        let volume = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? volume.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        let importantCapacity = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let ordinaryCapacity = Int64(values?.volumeAvailableCapacity ?? 0)
        let filesystemCapacity = (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return StorageSnapshot(
            totalBytes: Int64(values?.volumeTotalCapacity ?? 0),
            availableBytes: importantCapacity > 0 ? importantCapacity : max(ordinaryCapacity, filesystemCapacity)
        )
    }

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}

struct NetworkByteCounters: Equatable, Sendable {
    let receivedBytes: UInt64
    let sentBytes: UInt64
}

struct NetworkTrafficRate: Equatable, Sendable {
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double

    var downloadDescription: String { Self.rateDescription(downloadBytesPerSecond) }
    var uploadDescription: String { Self.rateDescription(uploadBytesPerSecond) }

    private static func rateDescription(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "Unavailable" }
        let amountBytes = bytesPerSecond >= Double(Int64.max) ? Int64.max : Int64(bytesPerSecond.rounded())
        let amount = ByteCountFormatter.string(fromByteCount: amountBytes, countStyle: .file)
        return "\(amount)/s"
    }
}

struct ExternalVolumeSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let totalBytes: Int64
    let availableBytes: Int64

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}

enum SystemMetricPresentation {
    static func uptimeDescription(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "Unavailable" }
        let wholeMinutes = floor(seconds / 60)
        guard wholeMinutes < Double(Int.max) else { return "Unavailable" }
        let totalMinutes = Int(wholeMinutes)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

struct CPULoadCounters: Equatable, Sendable {
    let totalTicks: UInt64
    let idleTicks: UInt64
}

enum MemoryPressureLevel: String, Equatable, Sendable {
    case normal
    case warning
    case critical

    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "High"
        }
    }

    var scorePoints: Int {
        switch self {
        case .normal: 100
        case .warning: 55
        case .critical: 25
        }
    }

    static func reported(by events: DispatchSource.MemoryPressureEvent) -> MemoryPressureLevel? {
        if events.contains(.critical) { return .critical }
        if events.contains(.warning) { return .warning }
        if events.contains(.normal) { return .normal }
        return nil
    }
}

enum BatteryHealthRating: String, Equatable, Sendable {
    case good = "Good"
    case fair = "Fair"
    case poor = "Poor"

    init?(systemValue: String?) {
        guard let systemValue else { return nil }
        switch systemValue {
        case "Good": self = .good
        case "Fair": self = .fair
        case "Poor": self = .poor
        default: return nil
        }
    }

    var scorePoints: Int {
        switch self {
        case .good: 100
        case .fair: 60
        case .poor: 20
        }
    }
}

enum BatteryServiceCondition: String, Equatable, Sendable {
    case checkBattery = "Check Battery"
    case permanentFailure = "Permanent Battery Failure"

    init?(systemValue: String?) {
        guard let value = systemValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        self.init(rawValue: value)
    }
}

enum MacHealthCheckStatus: Equatable, Sendable {
    case good
    case attention
    case urgent
    case unavailable
}

enum LocalDiskHealthState: String, Equatable, Sendable {
    case verified
    case attention
    case unavailable

    var title: String {
        switch self {
        case .verified: "Verified"
        case .attention: "Needs attention"
        case .unavailable: "Not reported"
        }
    }

    var explanation: String {
        switch self {
        case .verified:
            "macOS reports no issue in the startup drive’s built-in status. This cannot predict every drive failure."
        case .attention:
            "macOS reports a problem with the startup drive. Back up important files and review the drive in Disk Utility."
        case .unavailable:
            "macOS did not provide a recognizable startup-drive status. Some drives do not report one."
        }
    }
}

struct MacHealthCheck: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case storage
        case memoryPressure
        case battery
        case startupDisk
        case fileVault
        case firewall
        case gatekeeper
        case systemIntegrity
        case macOSUpdates

        var id: String { rawValue }
    }

    let kind: Kind
    let title: String
    let detail: String
    let status: MacHealthCheckStatus
    let scorePoints: Int?

    var id: Kind { kind }
}

struct MacHealthAssessment: Equatable, Sendable {
    let score: Int?
    let checks: [MacHealthCheck]
    let availableCheckCount: Int

    var rating: String {
        guard let score else { return "Waiting for readings" }
        if score >= 85 { return "In good shape" }
        if score >= 65 { return "Keep an eye on it" }
        return "Needs attention"
    }

    init(
        storage: StorageSnapshot,
        memoryPressure: MemoryPressureLevel?,
        battery: BatterySnapshot?,
        startupDiskHealth: LocalDiskHealthState? = nil,
        protectionChecks: [LocalProtectionCheck] = [],
        macOSUpdateState: LocalMacOSUpdateState? = nil
    ) {
        let storageFraction = storage.totalBytes > 0
            ? Double(storage.availableBytes) / Double(storage.totalBytes)
            : nil
        let storageCheck: MacHealthCheck
        if let storageFraction {
            if storageFraction >= 0.20 {
                storageCheck = MacHealthCheck(
                    kind: .storage,
                    title: "Available storage",
                    detail: "\(Int((storageFraction * 100).rounded()))% of this volume is available.",
                    status: .good,
                    scorePoints: 100
                )
            } else if storageFraction >= 0.10 {
                storageCheck = MacHealthCheck(
                    kind: .storage,
                    title: "Available storage",
                    detail: "\(Int((storageFraction * 100).rounded()))% is available. Review large items if the Mac feels low on space.",
                    status: .attention,
                    scorePoints: 70
                )
            } else {
                storageCheck = MacHealthCheck(
                    kind: .storage,
                    title: "Available storage",
                    detail: "Only \(Int((storageFraction * 100).rounded()))% is available. Review large items before installing or saving more.",
                    status: .urgent,
                    scorePoints: 35
                )
            }
        } else {
            storageCheck = MacHealthCheck(
                kind: .storage,
                title: "Available storage",
                detail: "macOS did not provide a total volume size.",
                status: .unavailable,
                scorePoints: nil
            )
        }

        let memoryCheck: MacHealthCheck
        if let memoryPressure {
            let status: MacHealthCheckStatus = switch memoryPressure {
            case .normal: .good
            case .warning: .attention
            case .critical: .urgent
            }
            memoryCheck = MacHealthCheck(
                kind: .memoryPressure,
                title: "Memory pressure",
                detail: "macOS currently reports \(memoryPressure.title.lowercased()) memory pressure.",
                status: status,
                scorePoints: memoryPressure.scorePoints
            )
        } else {
            memoryCheck = MacHealthCheck(
                kind: .memoryPressure,
                title: "Memory pressure",
                detail: "Waiting for macOS to report a memory-pressure event.",
                status: .unavailable,
                scorePoints: nil
            )
        }

        let batteryCheck: MacHealthCheck
        if let battery {
            if let healthCondition = battery.healthCondition {
                batteryCheck = MacHealthCheck(
                    kind: .battery,
                    title: "Battery condition",
                    detail: "macOS reports: \(healthCondition.rawValue.lowercased()).",
                    status: .urgent,
                    scorePoints: 20
                )
            } else if let healthRating = battery.healthRating {
                let status: MacHealthCheckStatus = switch healthRating {
                case .good: .good
                case .fair: .attention
                case .poor: .urgent
                }
                batteryCheck = MacHealthCheck(
                    kind: .battery,
                    title: "Battery condition",
                    detail: "macOS rates the battery \(healthRating.rawValue.lowercased()).",
                    status: status,
                    scorePoints: healthRating.scorePoints
                )
            } else {
                batteryCheck = MacHealthCheck(
                    kind: .battery,
                    title: "Battery condition",
                    detail: "This Mac has a battery, but macOS did not provide its condition.",
                    status: .unavailable,
                    scorePoints: nil
                )
            }
        } else {
            batteryCheck = MacHealthCheck(
                kind: .battery,
                title: "Battery condition",
                detail: "No internal battery information is available on this Mac.",
                status: .unavailable,
                scorePoints: nil
            )
        }

        let startupDiskCheck: MacHealthCheck
        switch startupDiskHealth ?? .unavailable {
        case .verified:
            startupDiskCheck = MacHealthCheck(
                kind: .startupDisk,
                title: "Startup disk status",
                detail: LocalDiskHealthState.verified.explanation,
                status: .good,
                scorePoints: 100
            )
        case .attention:
            startupDiskCheck = MacHealthCheck(
                kind: .startupDisk,
                title: "Startup disk status",
                detail: LocalDiskHealthState.attention.explanation,
                status: .urgent,
                scorePoints: 0
            )
        case .unavailable:
            startupDiskCheck = MacHealthCheck(
                kind: .startupDisk,
                title: "Startup disk status",
                detail: "macOS did not provide a recognizable startup-disk status.",
                status: .unavailable,
                scorePoints: nil
            )
        }

        func protectionHealthCheck(_ setting: LocalProtectionSetting, kind: MacHealthCheck.Kind) -> MacHealthCheck {
            let reportedCheck = protectionChecks.first { $0.setting == setting }
            let state = reportedCheck?.state ?? .unavailable
            let status: MacHealthCheckStatus
            let scorePoints: Int?
            switch (setting, state) {
            case (_, .enabled):
                status = .good
                scorePoints = 100
            case (.fileVault, .disabled), (.firewall, .disabled):
                status = .attention
                scorePoints = 60
            case (.gatekeeper, .disabled), (.systemIntegrity, .disabled):
                status = .urgent
                scorePoints = 20
            case (_, .unavailable):
                status = .unavailable
                scorePoints = nil
            }

            let detail: String
            if state == .unavailable {
                detail = "macOS did not report this setting."
            } else {
                detail = setting.explanation
            }
            return MacHealthCheck(
                kind: kind,
                title: setting.title,
                detail: detail,
                status: status,
                scorePoints: scorePoints
            )
        }

        let fileVaultCheck = protectionHealthCheck(.fileVault, kind: .fileVault)
        let firewallCheck = protectionHealthCheck(.firewall, kind: .firewall)
        let gatekeeperCheck = protectionHealthCheck(.gatekeeper, kind: .gatekeeper)
        let systemIntegrityCheck = protectionHealthCheck(.systemIntegrity, kind: .systemIntegrity)

        let updateCheck: MacHealthCheck
        switch macOSUpdateState {
        case .upToDate:
            updateCheck = MacHealthCheck(
                kind: .macOSUpdates,
                title: "macOS updates",
                detail: "Apple reported no available updates the last time you checked.",
                status: .good,
                scorePoints: 100
            )
        case let .updatesAvailable(items):
            let count = items.count
            updateCheck = MacHealthCheck(
                kind: .macOSUpdates,
                title: "macOS updates",
                detail: "Apple reported \(count) available update\(count == 1 ? "" : "s"). Review them in System Settings when you are ready.",
                status: .attention,
                scorePoints: 60
            )
        case .notReported, .timedOut, nil:
            updateCheck = MacHealthCheck(
                kind: .macOSUpdates,
                title: "macOS updates",
                detail: "No recent update result is available. Run a check when you choose.",
                status: .unavailable,
                scorePoints: nil
            )
        }

        checks = [
            storageCheck,
            memoryCheck,
            batteryCheck,
            startupDiskCheck,
            fileVaultCheck,
            firewallCheck,
            gatekeeperCheck,
            systemIntegrityCheck,
            updateCheck
        ]
        let weightedChecks: [(Int, Int)] = checks.compactMap { check in
            guard let points = check.scorePoints else { return nil }
            let weight: Int = switch check.kind {
            case .storage: 25
            case .memoryPressure: 20
            case .battery: 15
            case .startupDisk: 15
            case .fileVault, .firewall, .gatekeeper, .systemIntegrity: 5
            case .macOSUpdates: 5
            }
            return (points, weight)
        }
        availableCheckCount = weightedChecks.count
        let totalWeight = weightedChecks.reduce(0) { $0 + $1.1 }
        if totalWeight == 0 {
            score = nil
        } else {
            let weightedScore = weightedChecks.reduce(0) { $0 + ($1.0 * $1.1) }
            score = Int((Double(weightedScore) / Double(totalWeight)).rounded())
        }
    }
}

enum SystemMetricMath {
    static func cpuUsagePercent(previous: CPULoadCounters?, current: CPULoadCounters) -> Double? {
        guard let previous,
              current.totalTicks > previous.totalTicks,
              current.idleTicks >= previous.idleTicks else { return nil }
        let totalDelta = current.totalTicks - previous.totalTicks
        let idleDelta = current.idleTicks - previous.idleTicks
        guard idleDelta <= totalDelta else { return nil }
        return Double(totalDelta - idleDelta) / Double(totalDelta) * 100
    }

    static func networkTrafficRate(
        previous: NetworkByteCounters?,
        current: NetworkByteCounters,
        elapsedSeconds: TimeInterval
    ) -> NetworkTrafficRate? {
        guard let previous,
              elapsedSeconds.isFinite,
              elapsedSeconds > 0,
              current.receivedBytes >= previous.receivedBytes,
              current.sentBytes >= previous.sentBytes else { return nil }
        return NetworkTrafficRate(
            downloadBytesPerSecond: Double(current.receivedBytes - previous.receivedBytes) / elapsedSeconds,
            uploadBytesPerSecond: Double(current.sentBytes - previous.sentBytes) / elapsedSeconds
        )
    }
}

struct MemorySnapshot: Equatable, Sendable {
    let totalBytes: UInt64
    let freeBytes: UInt64
    let activeBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
}

struct SwapSnapshot: Equatable, Sendable {
    let totalBytes: UInt64
    let usedBytes: UInt64

    var availableBytes: UInt64 { totalBytes - usedBytes }
    var usedFraction: Double { Double(usedBytes) / Double(totalBytes) }

    init?(totalBytes: UInt64, usedBytes: UInt64) {
        guard totalBytes > 0, usedBytes <= totalBytes else { return nil }
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
    }
}

struct BatterySnapshot: Equatable, Sendable {
    let percentage: Int
    let isCharging: Bool
    let onExternalPower: Bool
    let healthRating: BatteryHealthRating?
    let healthCondition: BatteryServiceCondition?
    let cycleCount: Int?
}

struct ProcessActivitySnapshot: Identifiable, Equatable, Sendable {
    let processID: Int32
    let startedAtSeconds: UInt64
    let startedAtMicroseconds: UInt64
    let name: String
    let cpuUsagePercent: Double?
    let residentMemoryBytes: UInt64

    var id: String { "\(processID):\(startedAtSeconds):\(startedAtMicroseconds)" }
}

struct ProcessActivityReading: Equatable, Sendable {
    let processes: [ProcessActivitySnapshot]
    let isAvailable: Bool
    let wasTruncated: Bool

    static let unavailable = ProcessActivityReading(processes: [], isAvailable: false, wasTruncated: false)
}

struct SystemMonitorSnapshot: Equatable, Sendable {
    let cpuUsagePercent: Double?
    let memory: MemorySnapshot?
    let swap: SwapSnapshot?
    let memoryPressure: MemoryPressureLevel?
    var processActivity: ProcessActivityReading
    let battery: BatterySnapshot?
    let storage: StorageSnapshot
    let networkTraffic: NetworkTrafficRate?
    let externalVolumes: [ExternalVolumeSnapshot]
    let uptimeSeconds: TimeInterval
    let updatedAt: Date

}

enum MenuBarPreferenceKey {
    static let cpu = "MacCleaner.menuBar.showCPU.v1"
    static let memory = "MacCleaner.menuBar.showMemory.v1"
    static let storage = "MacCleaner.menuBar.showStorage.v1"
    static let battery = "MacCleaner.menuBar.showBattery.v1"
    static let network = "MacCleaner.menuBar.showNetwork.v1"
    static let uptime = "MacCleaner.menuBar.showUptime.v1"
}
