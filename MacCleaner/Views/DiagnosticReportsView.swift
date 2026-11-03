import AppKit
import QuickLookUI
import SwiftUI

struct DiagnosticReportsView: View {
    @ObservedObject var model: ScanViewModel
    let onOpenOverview: () -> Void

    @State private var inventory = DiagnosticReportInventory.empty()
    @State private var ageThresholdDays = 90
    @State private var searchText = ""
    @State private var selectedPaths: Set<String> = []
    @State private var isScanning = false
    @State private var isMoving = false
    @State private var hasScanned = false
    @State private var accessUnavailable = false
    @State private var showingReview = false
    @State private var operationMessage: String?
    @State private var previewReport: DiagnosticReport?
    @State private var scanTask: Task<DiagnosticReportInventory, Never>?
    @StateObject private var scanProgress = DiagnosticReportProgressState()

    private var selectedReports: [DiagnosticReport] {
        inventory.reports.filter { selectedPaths.contains($0.path) && $0.canMoveToTrash }
    }

    private var visibleReports: [DiagnosticReport] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return inventory.reports }
        return inventory.reports.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedBytes: Int64 {
        totalBytes(selectedReports.map(\.sizeBytes))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                safetyNotice
                if accessUnavailable { accessNotice }
                if let operationMessage {
                    Label(operationMessage, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if isScanning { progressNotice }
                if hasScanned { inventoryContent }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showingReview) {
            DiagnosticReportTrashReview(
                reports: selectedReports,
                selectedBytes: selectedBytes,
                thresholdDays: ageThresholdDays,
                isMoving: isMoving,
                onCancel: { showingReview = false },
                onConfirm: moveSelectedReports
            )
        }
        .sheet(item: $previewReport) { report in
            DiagnosticReportPreview(url: URL(fileURLWithPath: report.path))
        }
        .onChange(of: ageThresholdDays) { _, _ in
            selectedPaths.removeAll()
            hasScanned = false
            operationMessage = nil
        }
        .onDisappear { scanTask?.cancel() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Diagnostic Reports")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(MacCleanerTheme.primaryText)
                Text("Review older crash and diagnostic reports from this Mac account.")
                    .font(.title3)
                    .foregroundStyle(MacCleanerTheme.secondaryText)
            }
            Spacer(minLength: 8)
            if isScanning {
                Button("Cancel Scan") { scanTask?.cancel() }
                    .buttonStyle(.bordered)
            } else {
                Button(action: scan) {
                    Label(hasScanned ? "Refresh" : "Find Old Reports", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(MacCleanerTheme.accent)
                .disabled(isMoving)
            }
        }
    }

    private var safetyNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Older does not mean unneeded", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            Text("Mac Cleaner checks report names, dates, and file sizes in your account's standard DiagnosticReports folder. It never reads report contents during a scan. Reports can help troubleshoot a problem; preview and review each one before choosing whether to move it to Trash.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Recent reports stay out of this list. Selected reports go to Trash only after you confirm; they remain recoverable until Trash is emptied.")
                .font(.callout.weight(.medium))
                .foregroundStyle(MacCleanerTheme.secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var accessNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Full Disk Access is needed", systemImage: "lock.shield")
                .font(.headline)
            Text("Enable Mac Cleaner under Full Disk Access in System Settings. This tool uses that same permission and does not ask for another one.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Overview", action: onOpenOverview)
                .buttonStyle(.link)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard()
    }

    private var progressNotice: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(scanProgress.message ?? "Checking diagnostic reports…")
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .cleanerCard()
    }

    @ViewBuilder
    private var inventoryContent: some View {
        if !inventory.isAvailable {
            Label(inventory.message ?? "The DiagnosticReports folder is unavailable.", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cleanerCard()
        } else {
            summary
            if inventory.recentReportsKept > 0 {
                Label("\(inventory.recentReportsKept.formatted()) recent report(s) were kept out of this older-report review.", systemImage: "clock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if inventory.wasLimited || inventory.wasCancelled || inventory.skippedLocations > 0 {
                partialNotice
            }
            if inventory.reports.isEmpty && (inventory.wasLimited || inventory.wasCancelled || inventory.skippedLocations > 0) {
                ContentUnavailableView(
                    "Scan Incomplete",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The scan stopped before it could finish checking older reports. Run it again to complete the review.")
                )
                .frame(minHeight: 180)
            } else if inventory.reports.isEmpty {
                ContentUnavailableView(
                    "No Older Diagnostic Reports Found",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(inventory.message ?? "No reports older than \(ageThresholdDays) days were available to review.")
                )
                .frame(minHeight: 180)
            } else {
                reportControls
                LazyVStack(spacing: 12) {
                    ForEach(visibleReports) { report in
                        reportRow(report)
                    }
                }
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            metric(title: "Older reports", value: inventory.reports.count.formatted(), symbol: "doc.text")
            metric(title: "Listed size", value: totalBytes(inventory.reports.map(\.sizeBytes)).formattedByteCount, symbol: "externaldrive")
            metric(title: "Kept by age", value: inventory.recentReportsKept.formatted(), symbol: "clock")
        }
    }

    private var reportControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TextField("Search report names", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Picker("Report age", selection: $ageThresholdDays) {
                    Text("Older than 30 days").tag(30)
                    Text("Older than 90 days").tag(90)
                    Text("Older than 180 days").tag(180)
                    Text("Older than 1 year").tag(365)
                }
                .labelsHidden()
                .disabled(isScanning || isMoving)
                Spacer()
                Button("Select listed reports") {
                    selectedPaths = Set(visibleReports.filter(\.canMoveToTrash).map(\.path))
                }
                .buttonStyle(.link)
                .disabled(isMoving || visibleReports.allSatisfy { !$0.canMoveToTrash })
                Button("Clear") { selectedPaths.removeAll() }
                    .buttonStyle(.link)
                    .disabled(isMoving || selectedPaths.isEmpty)
            }
            HStack(spacing: 10) {
                if !selectedPaths.isEmpty {
                    Text("\(selectedReports.count) selected · \(selectedBytes.formattedByteCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingReview = true
                } label: {
                    Label("Review before moving to Trash", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(selectedReports.isEmpty || isMoving)
            }
        }
        .padding(14)
        .cleanerCard()
    }

    private func metric(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(MacCleanerTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard()
    }

    private func reportRow(_ report: DiagnosticReport) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(isOn: selectionBinding(for: report)) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("Select report \(report.name)")
            .disabled(!report.canMoveToTrash || isMoving)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(report.name)
                        .font(.headline)
                        .foregroundStyle(MacCleanerTheme.primaryText)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer(minLength: 12)
                    Text(report.sizeBytes.formattedByteCount)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(MacCleanerTheme.accent)
                }
                HStack(spacing: 12) {
                    Label(report.modifiedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    Label("\(max(0, Calendar.current.dateComponents([.day], from: report.modifiedAt, to: Date()).day ?? 0)) days old", systemImage: "clock")
                    if !report.canMoveToTrash {
                        Label(report.statusMessage ?? "View-only", systemImage: "lock")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(report.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Button {
                        previewReport = report
                    } label: {
                        Label("Preview report", systemImage: "eye")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: report.path)])
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard()
    }

    private var partialNotice: some View {
        let message: String = {
            if inventory.wasCancelled { return "Scan cancelled. Listed reports were checked before cancellation." }
            if inventory.wasLimited { return "The scan reached its safety limit. Some reports may not be listed." }
            return "Some report locations could not be checked. Listed results may be incomplete."
        }()
        return Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cleanerCard()
    }

    private func selectionBinding(for report: DiagnosticReport) -> Binding<Bool> {
        Binding(
            get: { selectedPaths.contains(report.path) },
            set: { isSelected in
                if isSelected { selectedPaths.insert(report.path) }
                else { selectedPaths.remove(report.path) }
            }
        )
    }

    private func totalBytes(_ sizes: [Int64]) -> Int64 {
        sizes.reduce(0) { total, size in
            let (sum, overflow) = total.addingReportingOverflow(size)
            return overflow ? Int64.max : sum
        }
    }

    private func scan() {
        guard !isScanning && !isMoving else { return }
        accessUnavailable = false
        operationMessage = nil
        selectedPaths.removeAll()
        scanProgress.message = nil
        guard let access = model.borrowDiskAccess() else {
            accessUnavailable = true
            inventory = DiagnosticReportInventory(
                reports: [], isAvailable: false,
                message: "Enable Mac Cleaner under Full Disk Access in System Settings. This tool does not request another permission.",
                ageThresholdDays: ageThresholdDays, recentReportsKept: 0, entriesChecked: 0,
                skippedLocations: 0, wasLimited: false, wasCancelled: false
            )
            hasScanned = true
            return
        }

        isScanning = true
        let service = DiagnosticReportInventoryService()
        let progressState = scanProgress
        let threshold = ageThresholdDays
        let task = Task.detached(priority: .utility) {
            service.scan(olderThanDays: threshold, isCancelled: { Task.isCancelled }) { progress in
                Task { @MainActor in
                    progressState.message = "Checking report details… \(progress.reportsChecked.formatted()) items"
                }
            }
        }
        scanTask = task
        Task { @MainActor in
            let result = await task.value
            access.stopAccessingSecurityScopedResource()
            inventory = result
            hasScanned = true
            isScanning = false
            scanTask = nil
            scanProgress.message = nil
        }
    }

    private func moveSelectedReports() {
        guard !isMoving, !selectedReports.isEmpty else { return }
        operationMessage = nil
        guard let access = model.borrowDiskAccess() else {
            accessUnavailable = true
            operationMessage = "Full Disk Access is unavailable. Enable Mac Cleaner in System Settings, then try again."
            return
        }
        isMoving = true
        let reports = selectedReports
        let service = DiagnosticReportInventoryService()
        let threshold = ageThresholdDays
        Task {
            let outcomes = await Task.detached(priority: .utility) {
                reports.map { report -> DiagnosticReportActionOutcome in
                    do {
                        let bytes = try service.moveToTrash(report, olderThanDays: threshold)
                        return DiagnosticReportActionOutcome(path: report.path, bytesMoved: bytes, error: nil)
                    } catch {
                        return DiagnosticReportActionOutcome(path: report.path, bytesMoved: 0, error: error.localizedDescription)
                    }
                }
            }.value
            access.stopAccessingSecurityScopedResource()
            let moved = outcomes.filter { $0.error == nil }
            let movedPaths = Set(moved.map(\.path))
            let failures = outcomes.count - moved.count
            inventory = DiagnosticReportInventory(
                reports: inventory.reports.filter { !movedPaths.contains($0.path) },
                isAvailable: inventory.isAvailable,
                message: moved.isEmpty ? inventory.message : "Selected reports were moved to Trash.",
                ageThresholdDays: inventory.ageThresholdDays,
                recentReportsKept: inventory.recentReportsKept,
                entriesChecked: inventory.entriesChecked,
                skippedLocations: inventory.skippedLocations,
                wasLimited: inventory.wasLimited,
                wasCancelled: inventory.wasCancelled
            )
            selectedPaths.subtract(movedPaths)
            if !moved.isEmpty {
                model.activity.record(
                    title: "Diagnostic reports moved to Trash",
                    files: moved.count,
                    bytes: totalBytes(moved.map(\.bytesMoved)),
                    note: "Selected older crash and diagnostic reports were moved to Trash. Report names, paths, and contents are not added to activity history.\(failures > 0 ? " Some selected reports stayed in place." : "")",
                    kind: .cleanup
                )
            }
            operationMessage = failures == 0 ? nil : "Some reports stayed in place. \(outcomes.compactMap(\.error).joined(separator: " "))"
            isMoving = false
            showingReview = false
        }
    }
}

@MainActor
private final class DiagnosticReportProgressState: ObservableObject {
    @Published var message: String?
}

private struct DiagnosticReportPreview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            DiagnosticReportQuickLookView(url: url)
                .frame(minWidth: 620, minHeight: 440)
        }
    }
}

private struct DiagnosticReportQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
    }
}

private struct DiagnosticReportTrashReview: View {
    let reports: [DiagnosticReport]
    let selectedBytes: Int64
    let thresholdDays: Int
    let isMoving: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Review reports before moving to Trash")
                    .font(.title2.weight(.semibold))
                Text("\(reports.count) report(s) · \(selectedBytes.formattedByteCount) · older than \(thresholdDays) days")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("These reports may help troubleshoot past problems. Review the exact names below and keep any you might need. macOS keeps moved items in Trash until you empty it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List(reports) { report in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(report.name).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer()
                        Text(report.sizeBytes.formattedByteCount).font(.callout.monospacedDigit())
                    }
                    Text(report.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                }
                .padding(.vertical, 3)
            }
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(isMoving ? "Moving…" : "Move Selected to Trash", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(MacCleanerTheme.accent)
                    .disabled(isMoving)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 480)
    }
}
