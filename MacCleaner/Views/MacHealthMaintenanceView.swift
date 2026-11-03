import AppKit
import SwiftUI

struct MacHealthMaintenanceView: View {
    @ObservedObject var monitor: SystemMonitor
    let onNavigate: (AppSection) -> Void

    @State private var visibilityID = UUID()
    @State private var launchError: String?
    @State private var snapshotInventory: LocalTimeMachineSnapshotInventory?
    @State private var snapshotError: String?
    @State private var isCheckingSnapshots = false
    @State private var protectionReport: LocalProtectionReport?
    @State private var isCheckingProtection = false
    @State private var diskHealthReport: LocalDiskHealthReport?
    @State private var isCheckingDiskHealth = false
    @State private var macOSUpdateReport: LocalMacOSUpdateReport?
    @State private var isCheckingMacOSUpdates = false

    private var assessment: MacHealthAssessment {
        MacHealthAssessment(
            storage: monitor.snapshot.storage,
            memoryPressure: monitor.snapshot.memoryPressure,
            battery: monitor.snapshot.battery,
            startupDiskHealth: diskHealthReport?.state,
            protectionChecks: protectionReport?.checks ?? [],
            macOSUpdateState: macOSUpdateReport?.state
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Mac Health & Maintenance")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(MacCleanerTheme.primaryText)
                    Text("A clear snapshot of the signals macOS shares, with practical next steps you control.")
                        .font(.title3)
                        .foregroundStyle(MacCleanerTheme.secondaryText)
                }

                healthSummary
                startupDiskHealth
                protectionStatus
                macOSUpdateStatus

                VStack(alignment: .leading, spacing: 12) {
                    Text("Helpful maintenance")
                        .font(.title2.weight(.semibold))
                    Text("Choose a task when you need it. Mac Cleaner does not schedule cleanup or run privileged commands in the background.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], alignment: .leading, spacing: 12) {
                        maintenanceCard(
                            title: "Review cleanup candidates",
                            detail: "Find local files worth a closer look. Nothing is selected automatically.",
                            symbol: "sparkles",
                            buttonTitle: "Start Smart Scan"
                        ) { onNavigate(.smartScan) }

                        maintenanceCard(
                            title: "Review large files",
                            detail: "Preview large and older files before deciding whether to keep them.",
                            symbol: "externaldrive",
                            buttonTitle: "Find large files"
                        ) { onNavigate(.largeFiles) }

                        maintenanceCard(
                            title: "Review startup items",
                            detail: "See readable login and background items. macOS controls whether they can be changed.",
                            symbol: "power",
                            buttonTitle: "Review startup"
                        ) { onNavigate(.startup) }

                        maintenanceCard(
                            title: "Check the disk",
                            detail: "Open Apple Disk Utility to inspect a disk and run First Aid if you choose.",
                            symbol: "externaldrive.badge.checkmark",
                            buttonTitle: "Open Disk Utility"
                        ) { openAppleApp(bundleID: "com.apple.DiskUtility", name: "Disk Utility") }

                        maintenanceCard(
                            title: "Review Time Machine snapshots",
                            detail: "List local snapshots macOS reports for the startup volume. Mac Cleaner does not thin or delete them.",
                            symbol: "clock.arrow.circlepath",
                            buttonTitle: isCheckingSnapshots ? "Checking…" : "List Snapshots"
                        ) { checkTimeMachineSnapshots() }
                        .disabled(isCheckingSnapshots)
                    }

                    if let snapshotError {
                        Label(snapshotError, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    if let snapshotInventory {
                        timeMachineSnapshotPanel(snapshotInventory)
                    }

                    if let launchError {
                        Label(launchError, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            monitor.setVisible(true, for: .maintenanceView, id: visibilityID)
            if protectionReport == nil { refreshProtectionStatus(notifyWhenFinished: false) }
            if diskHealthReport == nil { refreshDiskHealth(notifyWhenFinished: false) }
        }
        .onDisappear { monitor.setVisible(false, for: .maintenanceView, id: visibilityID) }
    }

    private var macOSUpdateStatus: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("macOS update status")
                        .font(.title2.weight(.semibold))
                    Text("Check Apple’s update catalog when you choose. This check does not download or install updates.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button {
                    checkMacOSUpdates()
                } label: {
                    Label(isCheckingMacOSUpdates ? "Checking…" : "Check for Updates", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCheckingMacOSUpdates)
                Button("Open System Settings") {
                    openAppleApp(bundleID: "com.apple.systempreferences", name: "System Settings")
                }
                .buttonStyle(.link)
            }

            if isCheckingMacOSUpdates {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Asking Apple for available updates…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 7)
            } else if let macOSUpdateReport {
                macOSUpdateResult(macOSUpdateReport.state)
                Text("Checked \(macOSUpdateReport.checkedAt.formatted(date: .abbreviated, time: .shortened)). The check sends no scan results or file names.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Update status has not been checked.", systemImage: "questionmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .cleanerCard()
    }

    @ViewBuilder
    private func macOSUpdateResult(_ state: LocalMacOSUpdateState) -> some View {
        switch state {
        case .upToDate:
            Label("Apple reports no available updates.", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color(nsColor: .systemGreen))
        case let .updatesAvailable(items):
            VStack(alignment: .leading, spacing: 9) {
                Label("Apple reports \(items.count) available update\(items.count == 1 ? "" : "s").", systemImage: "arrow.down.circle")
                    .font(.callout.weight(.medium))
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title).font(.callout)
                        Spacer(minLength: 12)
                        if let version = item.version {
                            Text("Version \(version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 28)
                }
                Text("Review and install updates in System Settings when you’re ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
        case .notReported:
            Label("Apple’s update status could not be confirmed. Try again or check System Settings.", systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .timedOut:
            Label("The update check took too long. Try again or check System Settings.", systemImage: "clock.badge.exclamationmark")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var protectionStatus: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Protection status")
                        .font(.title2.weight(.semibold))
                    Text("Read-only checks of settings macOS reports. Mac Cleaner does not change them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button {
                    refreshProtectionStatus()
                } label: {
                    Label(isCheckingProtection ? "Checking…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isCheckingProtection)
                Button("Open System Settings") {
                    openAppleApp(bundleID: "com.apple.systempreferences", name: "System Settings")
                }
                .buttonStyle(.link)
            }

            if isCheckingProtection {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Checking local macOS settings…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 7)
            } else if let protectionReport {
                VStack(spacing: 11) {
                    ForEach(protectionReport.checks) { check in
                        protectionRow(check)
                    }
                }
                Text("Checked \(protectionReport.checkedAt.formatted(date: .abbreviated, time: .shortened)). “Not reported” means macOS did not return a recognizable state. Gatekeeper checks are not a malware scan.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Protection settings have not been checked yet.", systemImage: "questionmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .cleanerCard()
    }

    private var startupDiskHealth: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Startup disk health")
                        .font(.title2.weight(.semibold))
                    Text("A limited, read-only status reported by macOS for the drive that starts your Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button {
                    refreshDiskHealth()
                } label: {
                    Label(isCheckingDiskHealth ? "Checking…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isCheckingDiskHealth)
                Button("Open Disk Utility") {
                    openAppleApp(bundleID: "com.apple.DiskUtility", name: "Disk Utility")
                }
                .buttonStyle(.link)
            }

            if isCheckingDiskHealth {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Checking the startup disk status…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 7)
            } else if let diskHealthReport {
                startupDiskHealthRow(diskHealthReport)
                Text("Checked \(diskHealthReport.checkedAt.formatted(date: .abbreviated, time: .shortened)). This report does not predict every drive failure.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("The startup disk has not been checked yet.", systemImage: "questionmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .cleanerCard()
    }

    private func startupDiskHealthRow(_ report: LocalDiskHealthReport) -> some View {
        let tint: Color
        let symbol: String
        switch report.state {
        case .verified:
            tint = Color(nsColor: .systemGreen)
            symbol = "checkmark.circle.fill"
        case .attention:
            tint = .orange
            symbol = "exclamationmark.triangle.fill"
        case .unavailable:
            tint = MacCleanerTheme.secondaryText
            symbol = "questionmark.circle"
        }

        return HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Drive status")
                    .font(.callout.weight(.medium))
                Text(report.state.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(report.state.title)
                .font(.callout.weight(.medium))
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private func refreshDiskHealth(notifyWhenFinished: Bool = true) {
        guard !isCheckingDiskHealth else { return }
        isCheckingDiskHealth = true
        Task { @MainActor in
            diskHealthReport = await LocalDiskHealthService().report()
            isCheckingDiskHealth = false
            if notifyWhenFinished {
                await ActivityNotificationService.shared.notifyIfEnabled(.macHealthCheckCompleted)
            }
        }
    }

    private func checkMacOSUpdates() {
        guard !isCheckingMacOSUpdates else { return }
        isCheckingMacOSUpdates = true
        Task { @MainActor in
            macOSUpdateReport = await LocalMacOSUpdateService().report()
            isCheckingMacOSUpdates = false
            await ActivityNotificationService.shared.notifyIfEnabled(.macHealthCheckCompleted)
        }
    }

    private func protectionRow(_ check: LocalProtectionCheck) -> some View {
        let tint: Color
        let symbol: String
        switch check.state {
        case .enabled:
            tint = Color(nsColor: .systemGreen)
            symbol = "checkmark.shield.fill"
        case .disabled:
            tint = .orange
            symbol = "exclamationmark.shield.fill"
        case .unavailable:
            tint = MacCleanerTheme.secondaryText
            symbol = "questionmark.circle"
        }

        return HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title).font(.callout.weight(.medium))
                Text(check.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(check.state.title)
                .font(.callout.weight(.medium))
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private func refreshProtectionStatus(notifyWhenFinished: Bool = true) {
        guard !isCheckingProtection else { return }
        isCheckingProtection = true
        Task { @MainActor in
            protectionReport = await LocalProtectionStatusService().report()
            isCheckingProtection = false
            if notifyWhenFinished {
                await ActivityNotificationService.shared.notifyIfEnabled(.macHealthCheckCompleted)
            }
        }
    }

    private var healthSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    Circle().stroke(MacCleanerTheme.border, lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: Double(assessment.score ?? 0) / 100)
                        .stroke(scoreColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(assessment.score.map { String($0) } ?? "—")
                            .font(.system(size: 29, weight: .semibold, design: .rounded).monospacedDigit())
                        Text("of 100")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 80, height: 80)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(assessment.score.map { "Mac health score \($0) out of 100" } ?? "Mac health score unavailable")

                VStack(alignment: .leading, spacing: 5) {
                    Text(assessment.rating)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(scoreColor)
                    Text("Based on \(assessment.availableCheckCount) of \(assessment.checks.count) available checks")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Storage, memory, battery, startup disk, selected macOS protection settings, and an optional Apple update check. This is a limited guide, not an Apple diagnosis.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("View live readings") { onNavigate(.performance) }
                    .buttonStyle(.bordered)
            }

            Divider()

            VStack(spacing: 10) {
                ForEach(assessment.checks) { check in
                    healthCheckRow(check)
                }
            }

            DisclosureGroup("How this score is calculated") {
                Text("Storage contributes 25%: 100 points at 20% or more free, 70 points from 10% to under 20%, and 35 points below 10%. Memory pressure contributes 20%: normal is 100, elevated is 55, and high is 25. Battery condition contributes 15%: Good is 100, Fair is 60, and Poor or a service warning is 20. The startup disk contributes 15% when macOS reports a status: Verified is 100 and Needs attention is 0. FileVault and Firewall contribute 5% each: On is 100 and Off is 60. Gatekeeper and System Integrity Protection contribute 5% each: On is 100 and Off is 20. An Apple update check contributes 5%: no updates reported is 100 and updates available is 60. Checks that are unavailable or not run are left out, and the other weights are rescaled. The score is Mac Cleaner’s guide, not an Apple diagnosis or a malware verdict.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .cleanerCard()
    }

    private var scoreColor: Color {
        guard let score = assessment.score else { return MacCleanerTheme.secondaryText }
        if score >= 85 { return Color(nsColor: .systemGreen) }
        if score >= 65 { return Color.orange }
        return Color.red
    }

    private func healthCheckRow(_ check: MacHealthCheck) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon(for: check.status))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color(for: check.status))
                .frame(width: 24)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title).font(.callout.weight(.medium))
                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let scorePoints = check.scorePoints {
                Text("\(scorePoints)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Score contribution \(scorePoints) out of 100")
            } else {
                Text("Not reported")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func maintenanceCard(
        title: String,
        detail: String,
        symbol: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(MacCleanerTheme.accent)
                .frame(width: 40, height: 40)
                .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 188, alignment: .leading)
        .cleanerCard()
    }

    private func timeMachineSnapshotPanel(_ inventory: LocalTimeMachineSnapshotInventory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Local Time Machine snapshots")
                    .font(.headline)
                Spacer()
                Text("Checked \(inventory.checkedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if inventory.snapshots.isEmpty {
                Text("macOS did not report any local Time Machine snapshots for the startup volume.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(inventory.snapshots.count.formatted()) snapshots · names and dates only; sizes aren’t reported by this check")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(inventory.snapshots) { snapshot in
                    HStack(alignment: .firstTextBaseline) {
                        Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.callout.monospacedDigit())
                        Spacer()
                        Text(snapshot.name)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            Text("This check covers the startup volume only and is read-only. Time Machine manages local snapshot storage; use Apple’s backup settings to manage backups.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard()
    }

    private func checkTimeMachineSnapshots() {
        guard !isCheckingSnapshots else { return }
        isCheckingSnapshots = true
        snapshotError = nil
        Task {
            defer { isCheckingSnapshots = false }
            do {
                snapshotInventory = try await LocalTimeMachineSnapshotService().inventory()
            } catch {
                snapshotInventory = nil
                snapshotError = error.localizedDescription
            }
            await ActivityNotificationService.shared.notifyIfEnabled(.macHealthCheckCompleted)
        }
    }

    private func icon(for status: MacHealthCheckStatus) -> String {
        switch status {
        case .good: "checkmark.circle.fill"
        case .attention: "info.circle.fill"
        case .urgent: "exclamationmark.triangle.fill"
        case .unavailable: "minus.circle"
        }
    }

    private func color(for status: MacHealthCheckStatus) -> Color {
        switch status {
        case .good: Color(nsColor: .systemGreen)
        case .attention: .orange
        case .urgent: .red
        case .unavailable: MacCleanerTheme.secondaryText
        }
    }

    private func openAppleApp(bundleID: String, name: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            launchError = "Could not find \(name) on this Mac."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async {
                launchError = error.map { "Could not open \(name): \($0.localizedDescription)" }
            }
        }
    }
}
