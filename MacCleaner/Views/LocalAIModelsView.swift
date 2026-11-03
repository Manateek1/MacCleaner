import AppKit
import SwiftUI

struct LocalAIModelsView: View {
    @ObservedObject var model: ScanViewModel
    let onOpenOverview: () -> Void

    @State private var inventory: LocalAIModelInventory?
    @State private var query = ""
    @State private var isScanning = false
    @State private var isRemoving = false
    @State private var accessUnavailable = false
    @State private var scanTask: Task<LocalAIModelInventory, Never>?
    @State private var removalTask: Task<(LocalAIModelRemovalResult, LocalAIModelInventory), Never>?
    @State private var selectedModelIDs: Set<String> = []
    @State private var showingRemovalConfirmation = false
    @State private var showingRemovalResult = false
    @State private var removalResult: LocalAIModelRemovalResult?

    private var selectedModels: [LocalAIModel] {
        (inventory?.models ?? []).filter { selectedModelIDs.contains($0.id) }
    }

    private var selectedSizeEstimate: Int64 {
        var uniqueFiles: [String: Int64] = [:]
        for item in selectedModels {
            let snapshots: [LocalAIModelTargetSnapshot]
            switch item.removalTarget {
            case .ollamaManifest(_, let blobs): snapshots = blobs
            case .huggingFaceRepository(_, let modelFiles): snapshots = modelFiles
            case .lmStudioDirectory(_, let files): snapshots = files
            case .modelFiles(let files): snapshots = files
            case nil: snapshots = []
            }
            if snapshots.isEmpty {
                uniqueFiles["model:\(item.id)"] = item.sizeBytes
            } else {
                for snapshot in snapshots {
                    uniqueFiles["\(snapshot.identity.device):\(snapshot.identity.inode)"] = snapshot.identity.size
                }
            }
        }
        return uniqueFiles.values.reduce(Int64(0)) { total, size in
            let (sum, overflow) = total.addingReportingOverflow(size)
            return overflow ? Int64.max : sum
        }
    }

    private var visibleModels: [LocalAIModel] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return inventory?.models ?? [] }
        return (inventory?.models ?? []).filter {
            $0.name.localizedCaseInsensitiveContains(normalized)
                || $0.provider.title.localizedCaseInsensitiveContains(normalized)
                || $0.path.localizedCaseInsensitiveContains(normalized)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                safetyNotice
                if accessUnavailable {
                    diskAccessNotice
                }
                if isScanning {
                    ProgressView("Checking provider folders and your home folder…")
                        .padding(.vertical, 28)
                } else if isRemoving {
                    ProgressView("Moving selected model data to Trash and refreshing…")
                        .padding(.vertical, 28)
                } else if let inventory {
                    results(inventory)
                } else {
                    ContentUnavailableView(
                        "Review local models",
                        systemImage: "cpu",
                        description: Text("Check known Ollama, Hugging Face, and LM Studio locations without opening model weights or connecting to the internet.")
                    )
                    .padding(.vertical, 20)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onDisappear { scanTask?.cancel() }
        .sheet(isPresented: $showingRemovalConfirmation) {
            removalReviewSheet
        }
        .alert("Model review complete", isPresented: $showingRemovalResult) {
            Button("Done", role: .cancel) {}
        } message: {
            Text(removalResultMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Local AI Models")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(MacCleanerTheme.primaryText)
                Text("See which downloaded models are using space on this Mac.")
                    .font(.title3)
                    .foregroundStyle(MacCleanerTheme.secondaryText)
            }
            Spacer(minLength: 8)
            if isScanning || isRemoving {
                Button("Cancel") { scanTask?.cancel() }
                    .buttonStyle(.bordered)
                    .disabled(isRemoving)
            } else {
                Button {
                    scan()
                } label: {
                    Label(inventory == nil ? "Find Models" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(MacCleanerTheme.accent)
            }
        }
    }

    private var safetyNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Local model review", systemImage: "lock.shield")
                .font(.headline)
            Text("Mac Cleaner checks the default Ollama, Hugging Face, and LM Studio folders, then looks for recognizable model files elsewhere in your home folder. It reads names, sizes, and dates without opening model weights or connecting to online services.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Choose the models you want to review. Before anything moves, Mac Cleaner shows the exact selection and asks once. Items go to Trash, and shared Ollama data stays in place when another model still uses it. Close apps that are using a model first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var diskAccessNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Full Disk Access is needed", systemImage: "lock.fill")
                .font(.headline)
            Text("Enable Mac Cleaner under Full Disk Access in System Settings. This tool uses that same permission and does not ask for another one.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Overview", action: onOpenOverview)
                .buttonStyle(.link)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard()
    }

    @ViewBuilder
    private func results(_ inventory: LocalAIModelInventory) -> some View {
        if inventory.wasCancelled {
            Label("This check was stopped. Results include only models found before you cancelled.", systemImage: "stop.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if inventory.wasLimited {
            Label("The safety limit was reached. Some folders were not checked, so more models may exist. Review the checked locations before relying on these results.", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        }
        if inventory.skippedLocations > 0 {
            Label("Some files or folders could not be checked. They were left out of the totals.", systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        HStack(spacing: 12) {
            summaryCard(title: "Models found", value: inventory.models.count.formatted(), symbol: "cpu")
            summaryCard(title: "Unique local data", value: inventory.uniqueBytes.formattedByteCount, symbol: "externaldrive")
        }

        if !inventory.models.isEmpty {
            TextField("Search models", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
            selectionControls
            LazyVStack(spacing: 12) {
                ForEach(visibleModels) { item in
                    modelCard(item)
                }
            }
            if visibleModels.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(minHeight: 150)
            }
        } else {
            ContentUnavailableView(
                "No recognizable model files found",
                systemImage: "shippingbox",
                description: Text("Mac Cleaner checked the provider folders and accessible parts of your home folder. Other user accounts and uncommon model formats are not included.")
            )
            .padding(.vertical, 18)
        }

        if !inventory.checkedLocations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("LOCATIONS CHECKED")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(inventory.checkedLocations, id: \.self) { path in
                    Text(path.replacingOccurrences(of: SafeFilePolicy.accountHome.path, with: "~"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cleanerCard()
        }

        Text("Sizes are logical file totals. Shared or cloned storage can make the space actually used or freed different.")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    private var selectionControls: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(selectedModels.count.formatted()) selected")
                    .font(.subheadline.weight(.semibold))
                Text("About \(selectedSizeEstimate.formattedByteCount) of model files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Select visible") { selectedModelIDs.formUnion(visibleModels.map(\.id)) }
                .buttonStyle(.bordered)
                .disabled(visibleModels.isEmpty)
            Button("Clear") { selectedModelIDs.removeAll() }
                .buttonStyle(.bordered)
                .disabled(selectedModelIDs.isEmpty)
            Button {
                showingRemovalConfirmation = true
            } label: {
                Label("Move to Trash…", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(MacCleanerTheme.accent)
            .disabled(selectedModels.isEmpty)
        }
        .padding(14)
        .cleanerCard()
    }

    private var removalReviewSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Review models to move")
                    .font(.title2.weight(.semibold))
                Text("\(selectedModels.count) selected · about \(selectedSizeEstimate.formattedByteCount) of model files")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Label("Close apps using these models first. Items move to Trash and can be restored.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(selectedModels) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(item.name).font(.headline)
                                Spacer()
                                Text(item.sizeBytes.formattedByteCount)
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Label(item.provider.title, systemImage: item.provider.symbol)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(item.path.replacingOccurrences(
                                of: SafeFilePolicy.accountHome.standardizedFileURL.resolvingSymlinksInPath().path,
                                with: "~"
                            ))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cleanerCard()
                    }
                }
            }
            .frame(minHeight: 180)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showingRemovalConfirmation = false }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) {
                    showingRemovalConfirmation = false
                    removeSelectedModels()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedModels.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 440)
    }

    private func summaryCard(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(MacCleanerTheme.accent)
                .frame(width: 38, height: 38)
                .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard()
    }

    private func modelCard(_ item: LocalAIModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    toggleSelection(for: item)
                } label: {
                    Image(systemName: selectedModelIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selectedModelIDs.contains(item.id) ? MacCleanerTheme.accent : MacCleanerTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .disabled(item.removalTarget == nil)
                .accessibilityLabel(selectedModelIDs.contains(item.id) ? "Deselect \(item.name)" : "Select \(item.name)")
                Label(item.provider.title, systemImage: item.provider.symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MacCleanerTheme.secondaryText)
                Spacer()
                Text(item.sizeBytes.formattedByteCount)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(MacCleanerTheme.primaryText)
            }
            Text(item.name)
                .font(.headline)
                .textSelection(.enabled)
            if item.provider == .other {
                Text("Possible model file · confirm what this is before making changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Only the recognized model-weight files shown for this entry are moved. Other files in the folder stay in place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if item.provider == .ollama {
                Text("Model data can be shared. Mac Cleaner keeps any file another Ollama model still needs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Moving this model sends its local model folder to Trash. Apps using it may need the model downloaded again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(item.fileCount.formatted()) files · \(item.modifiedAt.map { "Changed \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Date unavailable")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(item.path.replacingOccurrences(of: SafeFilePolicy.accountHome.path, with: "~"))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard()
    }

    private func scan() {
        guard !isScanning, !isRemoving else { return }
        accessUnavailable = false
        guard let access = model.borrowDiskAccess() else {
            accessUnavailable = true
            return
        }

        selectedModelIDs.removeAll()
        isScanning = true
        let service = LocalAIModelInventoryService()
        let task = Task.detached(priority: .utility) { service.scan() }
        scanTask = task
        Task { @MainActor in
            let result = await task.value
            access.stopAccessingSecurityScopedResource()
            inventory = result
            isScanning = false
            scanTask = nil
        }
    }

    private func toggleSelection(for item: LocalAIModel) {
        guard item.removalTarget != nil else { return }
        if selectedModelIDs.contains(item.id) {
            selectedModelIDs.remove(item.id)
        } else {
            selectedModelIDs.insert(item.id)
        }
    }

    private func removeSelectedModels() {
        guard !isRemoving, !isScanning, !selectedModels.isEmpty else { return }
        accessUnavailable = false
        guard let access = model.borrowDiskAccess() else {
            accessUnavailable = true
            return
        }

        isRemoving = true
        let chosen = selectedModels
        let removalService = LocalAIModelRemovalService()
        let inventoryService = LocalAIModelInventoryService()
        let task = Task.detached(priority: .utility) {
            let result = removalService.moveToTrash(chosen)
            let refreshedInventory = inventoryService.scan()
            return (result, refreshedInventory)
        }
        removalTask = task
        Task { @MainActor in
            let (result, refreshedInventory) = await task.value
            access.stopAccessingSecurityScopedResource()
            inventory = refreshedInventory
            selectedModelIDs.removeAll()
            isRemoving = false
            removalTask = nil
            removalResult = result
            showingRemovalResult = true
            if result.filesMoved > 0 {
                let partial = result.failures.isEmpty ? "" : " Some selected items were left in place."
                let shared = result.sharedModelDataRetained ? " Shared model data remains available to other models." : ""
                model.activity.record(
                    title: "Local AI models reviewed",
                    files: result.movedModelIDs.count,
                    bytes: result.bytesMoved,
                    note: "Selected local model data was moved to Trash.\(partial)\(shared) Model names and paths are not stored.",
                    kind: .cleanup
                )
            }
        }
    }

    private var removalResultMessage: String {
        guard let removalResult else { return "The model list has been refreshed." }
        let moved = removalResult.movedModelIDs.count
        var parts: [String] = []
        if moved > 0 {
            let entryWord = moved == 1 ? "entry was" : "entries were"
            parts.append("\(moved) selected model \(entryWord) moved to Trash.")
            if removalResult.bytesMoved > 0 {
                parts.append("About \(removalResult.bytesMoved.formattedByteCount) of model data moved.")
            } else if removalResult.sharedModelDataRetained {
                parts.append("Shared model data was kept because another model may still need it.")
            }
        }
        if !removalResult.failures.isEmpty {
            let itemWord = removalResult.failures.count == 1 ? "item was" : "items were"
            parts.append("\(removalResult.failures.count) selected \(itemWord) left in place because they changed or could not be verified safely.")
        }
        if parts.isEmpty { return "Nothing was moved. The model list has been refreshed." }
        return parts.joined(separator: " ") + " You can restore items from Trash."
    }
}
