import AppKit
import SwiftUI

struct DeviceBackupsView: View {
    @ObservedObject var model: ScanViewModel
    let onOpenOverview: () -> Void
    @State private var inventory = DeviceBackupInventory(
        backups: [],
        isAvailable: false,
        message: nil,
        skippedLocations: 0,
        wasLimited: false,
        wasCancelled: false
    )
    @State private var isScanning = false
    @State private var isMoving = false
    @State private var hasScanned = false
    @State private var accessUnavailable = false
    @State private var selectedPaths: Set<String> = []
    @State private var showingReview = false
    @State private var operationMessage: String?
    @StateObject private var scanProgress = DeviceBackupProgressState()
    @State private var scanTask: Task<DeviceBackupInventory, Never>?

    private var selectedBackups: [DeviceBackup] {
        inventory.backups.filter { selectedPaths.contains($0.path) && $0.canMoveToTrash }
    }

    private var selectedBytes: Int64 {
        selectedBackups.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                safetyNotice
                if accessUnavailable {
                    accessNotice
                }
                if let operationMessage {
                    Label(operationMessage, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                inventoryContent
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showingReview) {
            DeviceBackupRemovalReview(
                backups: selectedBackups,
                isMoving: isMoving,
                onCancel: { showingReview = false },
                onConfirm: moveSelectedBackups
            )
        }
        .onDisappear {
            scanTask?.cancel()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Device Backups")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(MacCleanerTheme.primaryText)
                Text("Review local iPhone and iPad backups by size and file-change date.")
                    .font(.title3)
                    .foregroundStyle(MacCleanerTheme.secondaryText)
            }
            Spacer(minLength: 8)
            if isScanning {
                Button("Cancel Scan") { scanTask?.cancel() }
                    .buttonStyle(.bordered)
            } else {
                Button {
                    scan()
                } label: {
                    Label(hasScanned ? "Refresh" : "Find Backups", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(MacCleanerTheme.accent)
                .disabled(isMoving)
            }
        }
    }

    private var safetyNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Only local device backups are included", systemImage: "iphone.and.arrow.left.and.arrow.right")
                .font(.headline)
            Text("Mac Cleaner reads folder names, file sizes, and dates in the standard iPhone/iPad backup folder. It does not open backup contents. It never scans iCloud backups or other folders.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Moving a backup to Trash may prevent restoring a device from that backup. Items remain in Trash until you empty it.")
                .font(.callout.weight(.medium))
                .foregroundStyle(MacCleanerTheme.secondaryText)
            Text("The listed date is the newest file-modified date Mac Cleaner can see. Recognized metadata does not prove a backup is complete or restorable.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Button("Open Overview") {
                onOpenOverview()
            }
            .buttonStyle(.link)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard()
    }

    @ViewBuilder
    private var inventoryContent: some View {
        if isScanning {
            VStack(spacing: 10) {
                ProgressView()
                if let progress = scanProgress.progress {
                    Text("Checking \(progress.backupName) · \(progress.entriesChecked.formatted()) items")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Checking local backup folders…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        } else if !hasScanned {
            ContentUnavailableView(
                "Review local device backups",
                systemImage: "iphone.and.arrow.left.and.arrow.right",
                description: Text("Check the standard local backup folder. This scan reads metadata only.")
            )
            .frame(minHeight: 220)
        } else if inventory.wasCancelled {
            ContentUnavailableView(
                "Scan cancelled",
                systemImage: "stop.circle",
                description: Text(inventory.message ?? "No backup folders were made available for cleanup review.")
            )
            .frame(minHeight: 220)
        } else if inventory.wasLimited && inventory.backups.isEmpty {
            ContentUnavailableView(
                "Scan reached its safety limit",
                systemImage: "exclamationmark.triangle",
                description: Text("Some backup folders were not checked. Refresh the list after reviewing the standard backup folder in Finder.")
            )
            .frame(minHeight: 220)
        } else if inventory.backups.isEmpty {
            ContentUnavailableView(
                inventory.isAvailable ? "No local backups found" : "Backup folder unavailable",
                systemImage: "externaldrive",
                description: Text(inventory.message ?? "No local iPhone or iPad backups were found.")
            )
            .frame(minHeight: 220)
        } else {
            results
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("\(inventory.backups.count) backup folders", systemImage: "folder")
                Text("·")
                Text("\(inventory.backups.reduce(Int64(0)) { $0 + $1.sizeBytes }.formattedByteCount) logical size")
                Spacer()
                if !selectedBackups.isEmpty {
                    Button("Review \(selectedBackups.count) selected") { showingReview = true }
                        .buttonStyle(.borderedProminent)
                        .tint(MacCleanerTheme.accent)
                        .disabled(isMoving)
                }
            }
            .font(.callout.weight(.medium))

            if inventory.wasLimited {
                Label("Mac Cleaner reached its file-count safety limit. Backups with incomplete checks are view-only, and remaining folders were not listed.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if inventory.skippedLocations > 0 {
                Label("\(inventory.skippedLocations) folder(s) could not be checked; they were left out of cleanup review.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVStack(spacing: 10) {
                ForEach(inventory.backups) { backup in
                    backupRow(backup)
                }
            }
        }
    }

    private func backupRow(_ backup: DeviceBackup) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Button {
                toggleSelection(for: backup)
            } label: {
                Image(systemName: selectedPaths.contains(backup.path) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(selectedPaths.contains(backup.path) ? MacCleanerTheme.accent : MacCleanerTheme.secondaryText)
                    .frame(width: 24, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(!backup.canMoveToTrash || isMoving)
            .accessibilityLabel(selectedPaths.contains(backup.path) ? "Remove \(backup.name) from selection" : "Select \(backup.name)")

            Image(systemName: backup.isRecognizedBackup ? "iphone.gen3" : "folder.badge.questionmark")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(MacCleanerTheme.accent)
                .frame(width: 32, height: 32)
                .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(backup.isRecognizedBackup ? "Local device backup" : "Unverified backup folder")
                        .font(.headline)
                    Spacer()
                    Text(backup.sizeBytes.formattedByteCount)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(MacCleanerTheme.primaryText)
                }
                    Text("\(backup.fileCount.formatted()) files · Newest file change \(backup.lastChangedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(backup.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                if let status = backup.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backup.path)])
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard()
    }

    private func toggleSelection(for backup: DeviceBackup) {
        guard backup.canMoveToTrash else { return }
        if selectedPaths.contains(backup.path) {
            selectedPaths.remove(backup.path)
        } else {
            selectedPaths.insert(backup.path)
        }
    }

    private func scan() {
        guard !isScanning && !isMoving else { return }
        operationMessage = nil
        isScanning = true
        selectedPaths.removeAll()
        scanProgress.progress = nil
        guard let access = model.borrowDiskAccess() else {
            accessUnavailable = true
            inventory = DeviceBackupInventory(
                backups: [],
                isAvailable: false,
                message: "Enable Mac Cleaner under Full Disk Access in System Settings. This tool does not request another permission.",
                skippedLocations: 0,
                wasLimited: false,
                wasCancelled: false
            )
            hasScanned = true
            isScanning = false
            return
        }
        accessUnavailable = false
        let service = DeviceBackupService()
        let progressState = scanProgress
        let task = Task.detached(priority: .utility) {
            service.scan(isCancelled: { Task.isCancelled }) { progress in
                Task { @MainActor in progressState.progress = progress }
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
            scanProgress.progress = nil
        }
    }

    private func moveSelectedBackups() {
        guard !isMoving, !selectedBackups.isEmpty else { return }
        operationMessage = nil
        guard let access = model.borrowDiskAccess() else {
            accessUnavailable = true
            operationMessage = "Full Disk Access is unavailable. Enable Mac Cleaner in System Settings, then retry."
            return
        }
        isMoving = true
        let backups = selectedBackups
        let service = DeviceBackupService()
        Task {
            let outcomes = await Task.detached(priority: .utility) {
                backups.map { backup -> DeviceBackupActionOutcome in
                    do {
                        let result = try service.moveToTrash(backup)
                        return DeviceBackupActionOutcome(path: result.path, sizeBytes: result.sizeBytes, error: nil)
                    } catch {
                        return DeviceBackupActionOutcome(path: backup.path, sizeBytes: 0, error: error.localizedDescription)
                    }
                }
            }.value
            access.stopAccessingSecurityScopedResource()
            let moved = outcomes.filter { $0.error == nil }
            let movedPaths = Set(moved.map(\.path))
            inventory = DeviceBackupInventory(
                backups: inventory.backups.filter { !movedPaths.contains($0.path) },
                isAvailable: inventory.isAvailable,
                message: inventory.backups.count == moved.count ? "Selected backups were moved to Trash." : inventory.message,
                skippedLocations: inventory.skippedLocations,
                wasLimited: inventory.wasLimited,
                wasCancelled: inventory.wasCancelled
            )
            selectedPaths.subtract(movedPaths)
            if moved.isEmpty {
                operationMessage = outcomes.compactMap(\.error).joined(separator: " ")
            } else {
                let bytes = moved.reduce(Int64(0)) { $0 + $1.sizeBytes }
                let failures = outcomes.count - moved.count
                model.activity.record(
                    title: "Local device backups moved to Trash",
                    files: moved.count,
                    bytes: bytes,
                    note: "\(moved.count) selected local device backup(s) moved to Trash. Contents and folder paths were not added to activity history.\(failures > 0 ? " \(failures) selected backup(s) stayed in place." : "")",
                    kind: .cleanup
                )
                operationMessage = failures == 0 ? nil : "\(failures) backup(s) stayed in place. \(outcomes.compactMap(\.error).joined(separator: " "))"
            }
            isMoving = false
            showingReview = false
        }
    }
}

@MainActor
private final class DeviceBackupProgressState: ObservableObject {
    @Published var progress: DeviceBackupProgress?
}

private struct DeviceBackupActionOutcome: Sendable {
    let path: String
    let sizeBytes: Int64
    let error: String?
}

private struct DeviceBackupRemovalReview: View {
    let backups: [DeviceBackup]
    let isMoving: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @State private var backupCompleted = false

    private var selectedBytes: Int64 {
        backups.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Review before moving to Trash")
                    .font(.title2.weight(.semibold))
                Text("\(backups.count) backup(s) · \(selectedBytes.formattedByteCount) logical size")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            List(backups) { backup in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Local device backup").fontWeight(.medium)
                        Spacer()
                        Text(backup.sizeBytes.formattedByteCount).monospacedDigit()
                    }
                    Text(backup.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 3)
            }
            .frame(minHeight: 150, maxHeight: 320)

            VStack(alignment: .leading, spacing: 8) {
                Label("These backups may be needed to restore an iPhone or iPad. They will go to Trash and can be restored until Trash is emptied.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("I checked that no device backup or sync is running.", isOn: $backupCompleted)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isMoving ? "Moving…" : "Move \(backups.count) to Trash", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!backupCompleted || isMoving || backups.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 660, height: 520)
    }
}
