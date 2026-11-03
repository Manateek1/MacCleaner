import AppKit
import SwiftUI

struct XcodeArchiveInventoryView: View {
    @ObservedObject var model: ScanViewModel
    let onOpenOverview: () -> Void

    @State private var inventory: XcodeStorageScanResult?
    @State private var isScanning = false
    @State private var hasScanned = false
    @State private var accessUnavailable = false
    @State private var scanTask: Task<XcodeStorageScanResult, Never>?
    @StateObject private var scanProgress = XcodeStorageProgressState()
    @State private var selectedArchivePaths: Set<String> = []
    @State private var selectedDeviceSupportPaths: Set<String> = []
    @State private var activeRemovalReview: RemovalReview?
    @State private var isRemovingArchives = false
    @State private var isRemovingDeviceSupport = false
    @State private var archiveRemovalError: String?
    @State private var deviceSupportRemovalError: String?
    @State private var cleanupResultTitle = "Xcode cleanup complete"
    @State private var cleanupResultMessage: String?
    @State private var showingCleanupResult = false

    private var selectedArchives: [XcodeArchiveRecord] {
        (inventory?.archives.archives ?? []).filter { selectedArchivePaths.contains($0.path) }
    }

    private var selectedArchiveBytes: Int64 {
        selectedArchives.reduce(Int64(0)) { total, archive in
            let (sum, overflow) = total.addingReportingOverflow(archive.sizeBytes)
            return overflow ? Int64.max : sum
        }
    }

    private var selectedDeviceSupport: [XcodeDeviceSupportFolder] {
        (inventory?.deviceSupport.folders ?? []).filter { selectedDeviceSupportPaths.contains($0.path) }
    }

    private var selectedDeviceSupportBytes: Int64 {
        selectedDeviceSupport.reduce(Int64(0)) { total, folder in
            let (sum, overflow) = total.addingReportingOverflow(folder.sizeBytes)
            return overflow ? Int64.max : sum
        }
    }

    private var isXcodeRunning: Bool {
        ["com.apple.dt.Xcode", "com.apple.dt.Xcode-beta"].contains { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                safetyNotice
                if accessUnavailable { accessNotice }
                if isScanning {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(scanProgress.message ?? "Checking local Xcode storage…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .cleanerCard()
                }
                if isRemovingArchives || isRemovingDeviceSupport {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(isRemovingArchives
                             ? "Rechecking selected archives and moving them to Trash…"
                             : "Rechecking selected support folders and moving them to Trash…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .cleanerCard()
                }
                if hasScanned, let inventory {
                    archiveSection(inventory.archives)
                    deviceSupportSection(inventory.deviceSupport)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onDisappear { scanTask?.cancel() }
        .sheet(item: $activeRemovalReview) { review in
            switch review {
            case .archives: archiveRemovalReviewSheet
            case .deviceSupport: deviceSupportRemovalReviewSheet
            }
        }
        .alert(cleanupResultTitle, isPresented: $showingCleanupResult) {
            Button("Done", role: .cancel) { }
        } message: {
            Text(cleanupResultMessage ?? "The selected Xcode storage items were reviewed.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Xcode Storage")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(MacCleanerTheme.primaryText)
                Text("Review local build archives and connected-device support files by name, size, date, and location.")
                    .font(.title3)
                    .foregroundStyle(MacCleanerTheme.secondaryText)
            }
            Spacer(minLength: 8)
            if isScanning {
                Button("Cancel Scan") { scanTask?.cancel() }
                    .buttonStyle(.bordered)
            } else {
                Button(action: scan) {
                    Label(hasScanned ? "Refresh" : "Find Xcode Storage", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(MacCleanerTheme.accent)
                .disabled(isRemovingArchives || isRemovingDeviceSupport)
            }
        }
    }

    private var safetyNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Xcode files stay under your control", systemImage: "hammer")
                .font(.headline)
            Text("Archives may contain app builds prepared for distribution and debugging symbols. Complete archives can be selected and reviewed by exact name and path before one confirmation moves them to Trash. Device-support folders help Xcode work with connected Apple devices; complete folders can also be reviewed and moved to Trash. Close Xcode first.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Sizes are logical file sizes. APFS may share storage between files, so the space actually used can be lower.")
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
            Button("Open Overview", action: onOpenOverview)
                .buttonStyle(.link)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard()
    }

    @ViewBuilder
    private func archiveSection(_ archiveInventory: XcodeArchiveInventory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Build Archives", detail: "Xcode keeps these for distributing builds and examining crash reports.", symbol: "archivebox")
            if !archiveInventory.isAvailable {
                unavailableMessage(archiveInventory.message)
            } else if archiveInventory.archives.isEmpty {
                emptyMessage("No Xcode Archives Found", message: archiveInventory.message ?? "No archives were found in Xcode's standard local Archives folder.", partial: partialMessage(
                    wasLimited: archiveInventory.wasLimited,
                    wasCancelled: archiveInventory.wasCancelled,
                    skippedLocations: archiveInventory.skippedLocations,
                    noun: "archives"
                ))
            } else {
                summaryMetrics(
                    countTitle: "Archives",
                    count: archiveInventory.archives.count,
                    size: totalBytes(archiveInventory.archives.map(\.sizeBytes)),
                    entries: archiveInventory.entriesChecked
                )
                if let partial = partialMessage(wasLimited: archiveInventory.wasLimited, wasCancelled: archiveInventory.wasCancelled, skippedLocations: archiveInventory.skippedLocations, noun: "archives") {
                    partialNotice(partial)
                }
                LazyVStack(spacing: 12) {
                    ForEach(archiveInventory.archives) { archive in
                        storageCard(
                            name: archive.name,
                            path: archive.path,
                            sizeBytes: archive.sizeBytes,
                            fileCount: archive.fileCount,
                            modifiedAt: archive.modifiedAt,
                            isComplete: archive.isComplete,
                            archive: archive
                        )
                    }
                }
                archiveSelectionReview
            }
        }
        .padding(16)
        .cleanerCard()
    }

    @ViewBuilder
    private func deviceSupportSection(_ supportInventory: XcodeDeviceSupportInventory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Device Support", detail: "Local support folders for developing and debugging connected devices.", symbol: "iphone.and.arrow.left.and.right")
            if !supportInventory.isAvailable {
                unavailableMessage(supportInventory.message)
            } else if supportInventory.folders.isEmpty {
                emptyMessage("No Device Support Folders Found", message: supportInventory.message ?? "No support folders were found in Xcode's standard local location.", partial: partialMessage(
                    wasLimited: supportInventory.wasLimited,
                    wasCancelled: supportInventory.wasCancelled,
                    skippedLocations: supportInventory.skippedLocations,
                    noun: "device-support folders"
                ))
            } else {
                summaryMetrics(
                    countTitle: "Versions",
                    count: supportInventory.folders.count,
                    size: totalBytes(supportInventory.folders.map(\.sizeBytes)),
                    entries: supportInventory.entriesChecked
                )
                if let partial = partialMessage(wasLimited: supportInventory.wasLimited, wasCancelled: supportInventory.wasCancelled, skippedLocations: supportInventory.skippedLocations, noun: "device-support folders") {
                    partialNotice(partial)
                }
                LazyVStack(spacing: 12) {
                    ForEach(supportInventory.folders) { folder in
                        storageCard(
                            name: folder.name,
                            path: folder.path,
                            sizeBytes: folder.sizeBytes,
                            fileCount: folder.fileCount,
                            modifiedAt: folder.modifiedAt,
                            isComplete: folder.isComplete,
                            deviceSupport: folder
                        )
                    }
                }
                deviceSupportSelectionReview
            }
        }
        .padding(16)
        .cleanerCard()
    }

    private func sectionHeading(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(MacCleanerTheme.primaryText)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func summaryMetrics(countTitle: String, count: Int, size: Int64, entries: Int) -> some View {
        HStack(spacing: 10) {
            metric(title: countTitle, value: count.formatted(), symbol: "folder")
            metric(title: "Listed size", value: size.formattedByteCount, symbol: "externaldrive")
            metric(title: "Items checked", value: entries.formatted(), symbol: "doc.text.magnifyingglass")
        }
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
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard()
    }

    private func storageCard(
        name: String,
        path: String,
        sizeBytes: Int64,
        fileCount: Int,
        modifiedAt: Date,
        isComplete: Bool,
        archive: XcodeArchiveRecord? = nil,
        deviceSupport: XcodeDeviceSupportFolder? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            if let archive {
                Toggle("Select for Trash review", isOn: Binding(
                    get: { selectedArchivePaths.contains(archive.path) },
                    set: { isSelected in
                        if isSelected { selectedArchivePaths.insert(archive.path) }
                        else { selectedArchivePaths.remove(archive.path) }
                    }
                ))
                .toggleStyle(.checkbox)
                .disabled(!archive.canMoveToTrash || isScanning || isRemovingArchives)
                if !archive.canMoveToTrash {
                    Text("This archive is incomplete, too large to verify, or contains a linked or unsupported item. It stays view-only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let deviceSupport {
                Toggle("Select for Trash review", isOn: Binding(
                    get: { selectedDeviceSupportPaths.contains(deviceSupport.path) },
                    set: { isSelected in
                        if isSelected { selectedDeviceSupportPaths.insert(deviceSupport.path) }
                        else { selectedDeviceSupportPaths.remove(deviceSupport.path) }
                    }
                ))
                .toggleStyle(.checkbox)
                .disabled(!deviceSupport.canMoveToTrash || isScanning || isRemovingArchives || isRemovingDeviceSupport)
                if !deviceSupport.canMoveToTrash {
                    Text(deviceSupport.fileCount == 0
                         ? "This folder has no checked files to move."
                         : "This folder is incomplete, too large to verify, or contains a linked or unsupported item. It stays view-only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(name)
                    .font(.headline)
                    .foregroundStyle(MacCleanerTheme.primaryText)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                Text(sizeBytes.formattedByteCount)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(MacCleanerTheme.accent)
            }
            HStack(spacing: 14) {
                Label(modifiedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                Label("\(fileCount.formatted()) files", systemImage: "doc")
                if !isComplete {
                    Label("Some items could not be checked", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard()
    }

    private var archiveSelectionReview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(selectedArchives.count) selected · \(selectedArchiveBytes.formattedByteCount)", systemImage: "archivebox")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MacCleanerTheme.primaryText)
                Spacer()
                Button("Clear") { selectedArchivePaths.removeAll() }
                    .buttonStyle(.link)
                    .disabled(selectedArchives.isEmpty || isRemovingArchives || isRemovingDeviceSupport)
            }
            Text("Archives contain the archived app and debugging symbols. Moving them to Trash may prevent distributing that build or investigating related crash reports. Trash remains recoverable until emptied.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isXcodeRunning {
                Label("Quit Xcode before moving archives.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Review Selected Archives") {
                    archiveRemovalError = nil
                    activeRemovalReview = .archives
                }
                    .buttonStyle(.borderedProminent)
                    .tint(MacCleanerTheme.accent)
                    .disabled(selectedArchives.isEmpty || isScanning || isRemovingArchives || isRemovingDeviceSupport)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard()
    }

    private var archiveRemovalReviewSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review selected archives")
                .font(.title2.weight(.semibold))
            Text("These exact Xcode archives will move to Trash. Each includes an archived app build and may include the debugging symbols needed to inspect crashes.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(selectedArchives) { archive in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(archive.name).font(.headline)
                                Spacer()
                                Text(archive.sizeBytes.formattedByteCount)
                                    .font(.callout.monospacedDigit())
                            }
                            Text(archive.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .cleanerCard()
                    }
                }
            }
            if let archiveRemovalError {
                Label(archiveRemovalError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { activeRemovalReview = nil }
                Button("Move \(selectedArchives.count) to Trash", role: .destructive) {
                    removeSelectedArchives()
                }
                .disabled(selectedArchives.isEmpty || isRemovingArchives || isRemovingDeviceSupport)
            }
        }
        .padding(22)
        .frame(width: 640, height: 520)
    }

    private var deviceSupportSelectionReview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(selectedDeviceSupport.count) selected · \(selectedDeviceSupportBytes.formattedByteCount)", systemImage: "iphone.and.arrow.left.and.right")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MacCleanerTheme.primaryText)
                Spacer()
                Button("Clear") { selectedDeviceSupportPaths.removeAll() }
                    .buttonStyle(.link)
                    .disabled(selectedDeviceSupport.isEmpty || isRemovingDeviceSupport)
            }
            Text("These files support connected-device development and debugging. Xcode may need them again for a future device session. Trash keeps them recoverable until you empty it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isXcodeRunning {
                Label("Quit Xcode before moving device-support folders.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let deviceSupportRemovalError {
                Label(deviceSupportRemovalError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Review Selected Folders") {
                    deviceSupportRemovalError = nil
                    activeRemovalReview = .deviceSupport
                }
                    .buttonStyle(.borderedProminent)
                    .tint(MacCleanerTheme.accent)
                    .disabled(selectedDeviceSupport.isEmpty || isScanning || isRemovingArchives || isRemovingDeviceSupport)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard()
    }

    private var deviceSupportRemovalReviewSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review selected device-support folders")
                .font(.title2.weight(.semibold))
            Text("These exact folders will move to Trash. Xcode uses this data for connected-device development and debugging. Close Xcode before continuing.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(selectedDeviceSupport) { folder in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(folder.name).font(.headline)
                                Spacer()
                                Text(folder.sizeBytes.formattedByteCount)
                                    .font(.callout.monospacedDigit())
                            }
                            Text(folder.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .cleanerCard()
                    }
                }
            }
            if isXcodeRunning {
                Label("Quit Xcode before moving device-support folders.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let deviceSupportRemovalError {
                Label(deviceSupportRemovalError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { activeRemovalReview = nil }
                Button("Move \(selectedDeviceSupport.count) to Trash", role: .destructive) {
                    removeSelectedDeviceSupport()
                }
                .disabled(selectedDeviceSupport.isEmpty || isRemovingArchives || isRemovingDeviceSupport || isXcodeRunning)
            }
        }
        .padding(22)
        .frame(width: 640, height: 520)
    }

    @ViewBuilder
    private func emptyMessage(_ title: String, message: String, partial: String?) -> some View {
        if let partial {
            partialNotice(partial)
        } else {
            ContentUnavailableView(title, systemImage: "folder", description: Text(message))
                .frame(minHeight: 140)
        }
    }

    private func unavailableMessage(_ message: String?) -> some View {
        Label(message ?? "This Xcode storage location is unavailable.", systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cleanerCard()
    }

    private func partialNotice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cleanerCard()
    }

    private func partialMessage(wasLimited: Bool, wasCancelled: Bool, skippedLocations: Int, noun: String) -> String? {
        if wasCancelled { return "Scan cancelled. The listed \(noun) are the ones checked before cancellation." }
        if wasLimited { return "The scan reached its safety limit. Some \(noun) or files may not be listed." }
        if skippedLocations > 0 { return "Some locations could not be checked. Listed sizes may be incomplete." }
        return nil
    }

    private func totalBytes(_ sizes: [Int64]) -> Int64 {
        sizes.reduce(0) { total, size in
            let (sum, overflow) = total.addingReportingOverflow(size)
            return overflow ? Int64.max : sum
        }
    }

    private func scan() {
        guard !isScanning, !isRemovingArchives, !isRemovingDeviceSupport else { return }
        accessUnavailable = false
        scanProgress.message = nil
        selectedArchivePaths.removeAll()
        selectedDeviceSupportPaths.removeAll()
        guard let access = model.borrowDiskAccess() else {
            accessUnavailable = true
            let message = "Enable Mac Cleaner under Full Disk Access in System Settings. This tool does not request another permission."
            inventory = XcodeStorageScanResult(
                archives: XcodeArchiveInventory(
                    archives: [], isAvailable: false, message: message, entriesChecked: 0,
                    skippedLocations: 0, wasLimited: false, wasCancelled: false
                ),
                deviceSupport: XcodeDeviceSupportInventory(
                    folders: [], isAvailable: false, message: message, entriesChecked: 0,
                    skippedLocations: 0, wasLimited: false, wasCancelled: false
                )
            )
            hasScanned = true
            return
        }

        isScanning = true
        let archiveService = XcodeArchiveInventoryService()
        let supportService = XcodeDeviceSupportInventoryService()
        let progressState = scanProgress
        let task = Task.detached(priority: .utility) {
            let archives = archiveService.scan(isCancelled: { Task.isCancelled }) { progress in
                Task { @MainActor in progressState.message = "Checking archive \(progress.archiveName)…" }
            }
            let deviceSupport = supportService.scan(isCancelled: { Task.isCancelled }) { progress in
                Task { @MainActor in progressState.message = "Checking device support \(progress.folderName)…" }
            }
            return XcodeStorageScanResult(archives: archives, deviceSupport: deviceSupport)
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

    private func removeSelectedArchives() {
        guard !isScanning, !isRemovingArchives, !isRemovingDeviceSupport, !selectedArchives.isEmpty else { return }
        guard !isXcodeRunning else {
            archiveRemovalError = "Quit Xcode before moving its archives. Then close this review and check again."
            return
        }
        guard let accessURL = model.borrowDiskAccess() else {
            archiveRemovalError = "Full Disk Access is unavailable. Enable Mac Cleaner in System Settings, then try again."
            return
        }

        archiveRemovalError = nil
        activeRemovalReview = nil
        isRemovingArchives = true
        let selection = selectedArchives
        let service = XcodeArchiveRemovalService()
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                service.moveToTrash(selection)
            }.value
            accessURL.stopAccessingSecurityScopedResource()
            isRemovingArchives = false
            selectedArchivePaths.removeAll()
            if !result.movedPaths.isEmpty {
                model.activity.record(
                    title: "Xcode archives moved to Trash",
                    files: result.movedPaths.count,
                    bytes: result.bytesMoved,
                    note: "Selected Xcode archives were moved to Trash after review.",
                    kind: .cleanup
                )
            }
            cleanupResultTitle = "Archive review complete"
            cleanupResultMessage = result.movedPaths.isEmpty
                ? "No archives were moved. \(result.failures.count) selected \(result.failures.count == 1 ? "archive was" : "archives were") left in place."
                : "\(result.movedPaths.count) archive(s) moved to Trash · \(result.bytesMoved.formattedByteCount). \(result.failures.count) stayed in place. Nothing was permanently deleted."
            showingCleanupResult = true
            if !result.movedPaths.isEmpty { scan() }
        }
    }

    private func removeSelectedDeviceSupport() {
        guard !isScanning, !isRemovingArchives, !isRemovingDeviceSupport, !selectedDeviceSupport.isEmpty else { return }
        guard !isXcodeRunning else {
            deviceSupportRemovalError = "Quit Xcode before moving device-support folders. Then refresh this review."
            return
        }
        guard let accessURL = model.borrowDiskAccess() else {
            deviceSupportRemovalError = "Full Disk Access is unavailable. Enable Mac Cleaner in System Settings, then try again."
            return
        }

        deviceSupportRemovalError = nil
        activeRemovalReview = nil
        isRemovingDeviceSupport = true
        let selection = selectedDeviceSupport
        let service = XcodeDeviceSupportRemovalService()
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                service.moveToTrash(selection)
            }.value
            accessURL.stopAccessingSecurityScopedResource()
            isRemovingDeviceSupport = false
            selectedDeviceSupportPaths.removeAll()
            if !result.movedPaths.isEmpty {
                model.activity.record(
                    title: "Xcode device support moved to Trash",
                    files: result.movedPaths.count,
                    bytes: result.bytesMoved,
                    note: "Selected Xcode device-support folders were moved to Trash after review.",
                    kind: .cleanup
                )
            }
            cleanupResultTitle = "Device support review complete"
            cleanupResultMessage = result.movedPaths.isEmpty
                ? "No folders were moved. \(result.failures.count) selected \(result.failures.count == 1 ? "folder was" : "folders were") left in place."
                : "\(result.movedPaths.count) folder(s) moved to Trash · \(result.bytesMoved.formattedByteCount). \(result.failures.count) stayed in place. Nothing was permanently deleted."
            showingCleanupResult = true
            if !result.movedPaths.isEmpty { scan() }
        }
    }
}

private enum RemovalReview: String, Identifiable {
    case archives
    case deviceSupport

    var id: String { rawValue }
}

@MainActor
private final class XcodeStorageProgressState: ObservableObject {
    @Published var message: String?
}
