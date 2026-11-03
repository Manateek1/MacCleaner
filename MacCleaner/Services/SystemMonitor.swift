import Combine
import Darwin
import Dispatch
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

@MainActor
final class SystemMonitor: ObservableObject {
    enum Client: Hashable {
        case performanceView
        case maintenanceView
        case menuBarPanel
    }

    private struct VisibleClient: Hashable {
        let client: Client
        let id: UUID
    }

    @Published private(set) var snapshot = SystemMonitorSnapshot(
        cpuUsagePercent: nil,
        memory: nil,
        swap: nil,
        memoryPressure: nil,
        processActivity: .unavailable,
        battery: nil,
        storage: StorageSnapshot.current(),
        networkTraffic: nil,
        externalVolumes: [],
        uptimeSeconds: ProcessInfo.processInfo.systemUptime,
        updatedAt: .now
    )

    private var visibleClients: Set<VisibleClient> = []
    private var pollingTask: Task<Void, Never>?
    private var processSamplingTask: Task<Void, Never>?
    private let processActivitySampler = ProcessActivitySampler()
    private var previousCPUCounters: CPULoadCounters?
    private var previousNetworkCounters: NetworkByteCounters?
    private var previousNetworkSampleDate: Date?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var memoryPressureLevel: MemoryPressureLevel?

    private static let reportedBatteryCycleCount = batteryCycleCount()

    func setVisible(_ visible: Bool, for client: Client, id: UUID) {
        let registration = VisibleClient(client: client, id: id)
        if visible {
            guard visibleClients.insert(registration).inserted else { return }
            if pollingTask == nil { startPolling() }
        } else {
            visibleClients.remove(registration)
            if visibleClients.isEmpty { stopPolling() }
        }
    }

    private func startPolling() {
        memoryPressureLevel = nil
        refresh()
        startMemoryPressureMonitoring()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        processSamplingTask?.cancel()
        processSamplingTask = nil
        previousCPUCounters = nil
        previousNetworkCounters = nil
        previousNetworkSampleDate = nil
        if let memoryPressureSource {
            memoryPressureSource.setEventHandler(handler: nil)
            memoryPressureSource.cancel()
            self.memoryPressureSource = nil
        }
    }

    private func refresh() {
        let now = Date()
        let counters = Self.cpuCounters()
        let cpuUsage = counters.flatMap { SystemMetricMath.cpuUsagePercent(previous: previousCPUCounters, current: $0) }
        previousCPUCounters = counters
        let networkCounters = SystemActivityReader.networkByteCounters()
        let networkTraffic = networkCounters.flatMap { current in
            SystemMetricMath.networkTrafficRate(
                previous: previousNetworkCounters,
                current: current,
                elapsedSeconds: previousNetworkSampleDate.map { now.timeIntervalSince($0) } ?? 0
            )
        }
        previousNetworkCounters = networkCounters
        previousNetworkSampleDate = networkCounters == nil ? nil : now
        snapshot = SystemMonitorSnapshot(
            cpuUsagePercent: cpuUsage,
            memory: Self.memorySnapshot(),
            swap: Self.swapSnapshot(),
            memoryPressure: memoryPressureLevel,
            processActivity: snapshot.processActivity,
            battery: Self.batterySnapshot(),
            storage: StorageSnapshot.current(),
            networkTraffic: networkTraffic,
            externalVolumes: SystemActivityReader.externalVolumes(),
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            updatedAt: now
        )
        refreshProcessActivity()
    }

    private func refreshProcessActivity() {
        guard processSamplingTask == nil else { return }
        let sampler = processActivitySampler
        processSamplingTask = Task { [weak self] in
            let reading = await sampler.sample()
            guard let self, !Task.isCancelled else { return }
            var updatedSnapshot = self.snapshot
            updatedSnapshot.processActivity = reading
            self.snapshot = updatedSnapshot
            self.processSamplingTask = nil
        }
    }

    private func startMemoryPressureMonitoring() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            guard let level = MemoryPressureLevel.reported(by: source.data) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.memoryPressureLevel = level
                self.refresh()
            }
        }
        memoryPressureSource = source
        source.resume()
    }

    private static func cpuCounters() -> CPULoadCounters? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        let user = UInt64(ticks.0)
        let system = UInt64(ticks.1)
        let idle = UInt64(ticks.2)
        let nice = UInt64(ticks.3)
        return CPULoadCounters(totalTicks: user + system + idle + nice, idleTicks: idle)
    }

    private static func memorySnapshot() -> MemorySnapshot? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageBytes = UInt64(vm_page_size)
        return MemorySnapshot(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            freeBytes: UInt64(info.free_count) * pageBytes,
            activeBytes: UInt64(info.active_count) * pageBytes,
            wiredBytes: UInt64(info.wire_count) * pageBytes,
            compressedBytes: UInt64(info.compressor_page_count) * pageBytes
        )
    }

    private static func swapSnapshot() -> SwapSnapshot? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        guard result == 0,
              size == MemoryLayout<xsw_usage>.size else { return nil }
        return SwapSnapshot(totalBytes: usage.xsu_total, usedBytes: usage.xsu_used)
    }

    private static func batterySnapshot() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = values[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return BatterySnapshot(
                percentage: min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded()))),
                isCharging: values[kIOPSIsChargingKey] as? Bool ?? false,
                onExternalPower: values[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                healthRating: BatteryHealthRating(systemValue: values[kIOPSBatteryHealthKey] as? String),
                healthCondition: BatteryServiceCondition(systemValue: values[kIOPSBatteryHealthConditionKey] as? String),
                cycleCount: reportedBatteryCycleCount
            )
        }
        return nil
    }

    private static func batteryCycleCount() -> Int? {
        var rawInfo: Unmanaged<CFArray>?
        guard IOPMCopyBatteryInfo(mach_port_t(MACH_PORT_NULL), &rawInfo) == kIOReturnSuccess,
              let dictionaries = rawInfo?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return dictionaries
            .compactMap { ($0[kIOBatteryCycleCountKey as String] as? NSNumber)?.intValue }
            .first(where: { $0 >= 0 })
    }
}
