import AppKit
import SwiftUI

struct PerformanceView: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var visibilityID = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Performance")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(MacCleanerTheme.primaryText)
                    Text("Live CPU, memory, storage, network, and battery readings. Sampling pauses when this view and the menu bar panel are closed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 14) {
                    CPUStatusCard(snapshot: monitor.snapshot)
                    MemoryStatusCard(snapshot: monitor.snapshot.memory, swap: monitor.snapshot.swap, pressure: monitor.snapshot.memoryPressure)
                    StorageStatusCard(snapshot: monitor.snapshot.storage)
                    NetworkStatusCard(snapshot: monitor.snapshot.networkTraffic)
                    ExternalVolumesCard(volumes: monitor.snapshot.externalVolumes)
                    BatteryStatusCard(snapshot: monitor.snapshot.battery)
                    UptimeStatusCard(seconds: monitor.snapshot.uptimeSeconds)
                    ProcessActivityCard(reading: monitor.snapshot.processActivity)
                }

                Text("Memory pressure, battery condition, and external-drive details come from macOS when available. Process rankings show readable activity for your account; Activity Monitor provides the broader system view. Hardware temperature is not exposed by a supported API to this app.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Text("Updated at \(monitor.snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { monitor.setVisible(true, for: .performanceView, id: visibilityID) }
        .onDisappear { monitor.setVisible(false, for: .performanceView, id: visibilityID) }
    }
}

struct SystemMonitorMenuView: View {
    @ObservedObject var monitor: SystemMonitor
    @Environment(\.openWindow) private var openWindow
    @State private var visibilityID = UUID()
    @AppStorage(MenuBarPreferenceKey.cpu) private var showCPU = true
    @AppStorage(MenuBarPreferenceKey.memory) private var showMemory = true
    @AppStorage(MenuBarPreferenceKey.storage) private var showStorage = true
    @AppStorage(MenuBarPreferenceKey.battery) private var showBattery = true
    @AppStorage(MenuBarPreferenceKey.network) private var showNetwork = false
    @AppStorage(MenuBarPreferenceKey.uptime) private var showUptime = false

    private var hasVisibleIndicator: Bool {
        showCPU || showMemory || showStorage || showBattery || showNetwork || showUptime
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Text("System Monitor")
                    .font(.headline)

                if showCPU { CPUStatusCard(snapshot: monitor.snapshot, compact: true) }
                if showMemory { MemoryStatusCard(snapshot: monitor.snapshot.memory, swap: monitor.snapshot.swap, pressure: monitor.snapshot.memoryPressure, compact: true) }
                if showStorage { StorageStatusCard(snapshot: monitor.snapshot.storage, compact: true) }
                if showBattery { BatteryStatusCard(snapshot: monitor.snapshot.battery, compact: true) }
                if showNetwork { NetworkStatusCard(snapshot: monitor.snapshot.networkTraffic, compact: true) }
                if showUptime { UptimeStatusCard(seconds: monitor.snapshot.uptimeSeconds, compact: true) }

                if !hasVisibleIndicator {
                    Text("No indicators selected. Choose what appears here in Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("Updated at \(monitor.snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)

                Divider()

                Button("Open Mac Cleaner") { openWindow(id: "main") }
                    .buttonStyle(.link)
            }
            .padding(16)
        }
        // MenuBarExtra's window-style scroll view may report a one-line
        // ideal height, so use a fixed window size and let the content scroll.
        .frame(width: 330, height: 560)
        .onAppear { monitor.setVisible(hasVisibleIndicator, for: .menuBarPanel, id: visibilityID) }
        .onChange(of: hasVisibleIndicator) { _, isVisible in
            monitor.setVisible(isVisible, for: .menuBarPanel, id: visibilityID)
        }
        .onDisappear { monitor.setVisible(false, for: .menuBarPanel, id: visibilityID) }
    }
}

private struct NetworkStatusCard: View {
    let snapshot: NetworkTrafficRate?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 12) {
            HStack {
                Label("Network", systemImage: "arrow.left.arrow.right")
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                Spacer()
                Text(snapshot == nil ? "Collecting…" : "Live")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let snapshot {
                HStack {
                    Label(snapshot.downloadDescription, systemImage: "arrow.down")
                    Spacer()
                    Label(snapshot.uploadDescription, systemImage: "arrow.up")
                }
                .font(.callout.monospacedDigit())
            } else {
                Text("Traffic rates appear after two readings from active network interfaces.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 12 : 18)
        .cleanerCard(cornerRadius: compact ? 12 : 16)
    }
}

private struct ExternalVolumesCard: View {
    let volumes: [ExternalVolumeSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("External Drives", systemImage: "externaldrive")
                .font(.headline)
            if volumes.isEmpty {
                Text("No mounted external volumes were found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(volumes) { volume in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(volume.name).font(.callout.weight(.medium))
                            Spacer()
                            Text("\(volume.availableBytes.formattedByteCount) available")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: volume.usedFraction)
                            .tint(volume.usedFraction > 0.9 ? .orange : MacCleanerTheme.accent)
                        Text("\(volume.usedBytes.formattedByteCount) used of \(volume.totalBytes.formattedByteCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("Only mounted local non-internal volumes are listed. Network drives are not included.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .cleanerCard()
    }
}

private struct UptimeStatusCard: View {
    let seconds: TimeInterval
    var compact = false

    var body: some View {
        HStack {
            Label("Since last restart", systemImage: "clock.arrow.circlepath")
                .font(compact ? .subheadline.weight(.semibold) : .headline)
            Spacer()
            Text(SystemMetricPresentation.uptimeDescription(seconds: seconds))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(compact ? 12 : 18)
        .cleanerCard(cornerRadius: compact ? 12 : 16)
    }
}

private struct ProcessActivityCard: View {
    let reading: ProcessActivityReading
    @State private var ranking: ProcessActivityRanking = .cpu
    @AppStorage(ProcessActivityDisplayLimit.storageKey)
    private var displayLimit = ProcessActivityDisplayLimit.defaultValue.rawValue

    private var highestProcesses: [ProcessActivitySnapshot] {
        let limit = ProcessActivityDisplayLimit(rawValue: displayLimit) ?? .defaultValue
        return limit.visibleProcesses(in: reading.processes, rankedBy: ranking)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Apps and background processes", systemImage: "chart.bar.xaxis")
                .font(.headline)
                Spacer()
                Picker("Rank by", selection: $ranking) {
                    ForEach(ProcessActivityRanking.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            Text("Live readings for processes running under your account.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !reading.isAvailable {
                Text("macOS did not provide a process list. Open Activity Monitor to see live resource use.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if highestProcesses.isEmpty {
                Text("No readable process activity is available right now. Some details may be limited by macOS.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 9) {
                    ForEach(Array(highestProcesses.enumerated()), id: \.element.id) { index, process in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 20, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(process.name)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            Text(value(for: process))
                                .font(.callout.monospacedDigit().weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        if index < highestProcesses.count - 1 { Divider() }
                    }
                }
                .padding(.vertical, 2)
            }

            if reading.wasTruncated {
                Text("There are more processes than Mac Cleaner can list here. Open Activity Monitor for the full view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("CPU is measured per processor core and can exceed 100%. Memory is the amount of RAM currently used by each process.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("Open Activity Monitor", action: openActivityMonitor)
                .buttonStyle(.bordered)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard()
    }

    private func value(for process: ProcessActivitySnapshot) -> String {
        switch ranking {
        case .cpu:
            guard let usage = process.cpuUsagePercent else { return "Measuring…" }
            return "\(usage.formatted(.number.precision(.fractionLength(1))))%"
        case .memory:
            return ByteCountFormatter.string(
                fromByteCount: Int64(clamping: process.residentMemoryBytes),
                countStyle: .memory
            )
        }
    }

    private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app", isDirectory: true)
        NSWorkspace.shared.open(url)
    }
}

private struct BatteryStatusCard: View {
    let snapshot: BatterySnapshot?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 12) {
            HStack {
                Label("Battery", systemImage: "battery.75percent")
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                Spacer()
                Text(snapshot.map { "\($0.percentage)%" } ?? "Unavailable")
                    .font(.callout.monospacedDigit())
            }
            if let snapshot {
                ProgressView(value: Double(snapshot.percentage) / 100)
                    .tint(MacCleanerTheme.accent)
                Text(snapshot.isCharging ? "Charging" : (snapshot.onExternalPower ? "Connected to power" : "Using battery"))
                    .font(.caption).foregroundStyle(.secondary)
                if let healthRating = snapshot.healthRating {
                    Label("Battery condition: \(healthRating.rawValue)", systemImage: healthRating == .poor ? "exclamationmark.triangle" : "heart.text.square")
                        .font(.caption)
                        .foregroundStyle(healthRating == .poor ? Color.orange : Color.secondary)
                }
                if let condition = snapshot.healthCondition {
                    Label("macOS recommends service: \(condition.rawValue)", systemImage: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                }
                if let cycleCount = snapshot.cycleCount {
                    Text("Battery cycles: \(cycleCount.formatted())")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Battery cycle count was not reported by macOS.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("No internal battery information is available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 12 : 18)
        .cleanerCard(cornerRadius: compact ? 12 : 16)
    }
}

private struct CPUStatusCard: View {
    let snapshot: SystemMonitorSnapshot
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 12) {
            HStack {
                Label("CPU", systemImage: "cpu")
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                Spacer()
                Text(snapshot.cpuUsagePercent.map { "\(Int($0.rounded()))%" } ?? "Collecting…")
                    .font(.system(compact ? .title3 : .largeTitle, design: .rounded).weight(.semibold).monospacedDigit())
            }
            ProgressView(value: (snapshot.cpuUsagePercent ?? 0) / 100)
                .tint((snapshot.cpuUsagePercent ?? 0) > 85 ? .orange : MacCleanerTheme.accent)
            Text("Total processor activity")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(compact ? 12 : 18)
        .cleanerCard(cornerRadius: compact ? 12 : 16)
    }
}

private struct MemoryStatusCard: View {
    let snapshot: MemorySnapshot?
    let swap: SwapSnapshot?
    let pressure: MemoryPressureLevel?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 11) {
            HStack {
                Label("Memory", systemImage: "memorychip")
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                Spacer()
                if let pressure {
                    Text("Pressure: \(pressure.title)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(pressure == .critical ? Color.red : (pressure == .warning ? Color.orange : Color.secondary))
                } else {
                    Text("Pressure: waiting")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(snapshot.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0.totalBytes), countStyle: .memory) } ?? "Unavailable")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let snapshot {
                MemoryLine(title: "Active", bytes: snapshot.activeBytes)
                MemoryLine(title: "Wired", bytes: snapshot.wiredBytes)
                MemoryLine(title: "Compressed", bytes: snapshot.compressedBytes)
                MemoryLine(title: "Free", bytes: snapshot.freeBytes)
                if pressure == nil {
                    Text("macOS has not sent a pressure update while Mac Cleaner is open.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if let swap {
                HStack {
                    Text("Swap memory used").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(memoryDescription(swap.usedBytes)) of \(memoryDescription(swap.totalBytes))")
                        .monospacedDigit()
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
            } else {
                Text("Swap usage is not reported by macOS.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(compact ? 12 : 18)
        .cleanerCard(cornerRadius: compact ? 12 : 16)
    }

    private func memoryDescription(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}

private struct MemoryLine: View {
    let title: String
    let bytes: UInt64

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory))
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private struct StorageStatusCard: View {
    let snapshot: StorageSnapshot
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 12) {
            HStack {
                Label("Storage", systemImage: "internaldrive")
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                Spacer()
                Text("\(snapshot.availableBytes.formattedByteCount) available")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: snapshot.usedFraction)
                .tint(snapshot.usedFraction > 0.9 ? .orange : MacCleanerTheme.accent)
            HStack {
                Text("\(snapshot.usedBytes.formattedByteCount) used")
                Spacer()
                Text("\(snapshot.totalBytes.formattedByteCount) total")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(compact ? 12 : 18)
        .cleanerCard(cornerRadius: compact ? 12 : 16)
    }
}
