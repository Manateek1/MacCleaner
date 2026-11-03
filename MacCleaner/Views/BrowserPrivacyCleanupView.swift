import AppKit
import SwiftUI

struct BrowserPrivacyCleanupView: View {
    @ObservedObject var model: ScanViewModel
    let onOpenOverview: () -> Void

    @State private var inventory = BrowserPrivacyInventory(
        candidates: [],
        skippedLocations: 0,
        wasLimited: false,
        wasCancelled: false
    )
    @State private var hasScanned = false
    @State private var isScanning = false
    @State private var isMoving = false
    @State private var accessUnavailable = false
    @State private var selectedPaths: Set<String> = []
    @State private var showingReview = false
    @State private var operationMessage: String?
    @State private var browserLaunchMessage: String?
    @StateObject private var progressState = BrowserPrivacyProgressState()
    @State private var scanTask: Task<BrowserPrivacyInventory, Never>?

    private var selectedCandidates: [BrowserCacheCandidate] {
        inventory.candidates.filter { selectedPaths.contains($0.path) && $0.canMoveToTrash }
    }

    private var selectedBytes: Int64 {
        selectedCandidates.reduce(0) { total, candidate in
            let (sum, overflow) = total.addingReportingOverflow(candidate.sizeBytes)
            return overflow ? Int64.max : sum
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                privacyNotice
                browserControls

                if let operationMessage {
                    Label(operationMessage, systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(MacCleanerTheme.secondaryText)
                        .textSelection(.enabled)
                }
                if let browserLaunchMessage {
                    Label(browserLaunchMessage, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if accessUnavailable {
                    accessNotice
                }
                inventoryContent
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showingReview) {
            BrowserCacheCleanupReview(
                candidates: selectedCandidates,
                isMoving: isMoving,
                onCancel: { showingReview = false },
                onConfirm: moveSelectedCaches
            )
        }
        .onDisappear {
            scanTask?.cancel()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Privacy Cleanup")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(MacCleanerTheme.primaryText)
                Text("Review temporary browser cache without disturbing sign-ins or saved data.")
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
                    Label(hasScanned ? "Scan Again" : "Find Browser Caches", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .tint(MacCleanerTheme.accent)
                .disabled(isMoving)
            }
        }
    }

    private var privacyNotice: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Only temporary cache folders can be moved here", systemImage: "hand.raised.fill")
                .font(.headline)
            Text("Mac Cleaner does not include browsing history, download lists, cookies, website storage, passwords, form autofill, or downloaded files in this cleanup. Selected cache folders go to Trash after a separate review.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("This tool uses the Full Disk Access permission you already enabled and does not ask for another one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var browserControls: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), alignment: .top)], alignment: .leading, spacing: 14) {
            browserControlCard(
                browser: .safari,
                title: "Safari",
                description: "Use History > Clear History for visit and download records. If Safari uses iCloud, clearing history can affect your other Apple devices. Use Safari > Settings > Privacy to manage website data; removing it may sign you out.",
                buttonTitle: "Open Safari"
            )
            browserControlCard(
                browser: .chrome,
                title: "Chrome",
                description: "Mac Cleaner checks only Chrome’s temporary cache folders. It leaves browsing history, downloads, cookies, website storage, and saved passwords alone.",
                buttonTitle: "Open Chrome Privacy Settings"
            )
            browserControlCard(
                browser: .firefox,
                title: "Firefox",
                description: "Firefox keeps bookmarks, downloads, and browsing history together. Mac Cleaner leaves that database untouched. Open Privacy & Security to choose which browser data to clear.",
                buttonTitle: "Open Firefox Privacy Settings"
            )
        }
    }

    private func browserControlCard(
        browser: LocalBrowser,
        title: String,
        description: String,
        buttonTitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: browserSymbol(for: browser))
                .font(.headline)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(buttonTitle) {
                openPrivacyControls(for: browser)
            }
            .buttonStyle(.bordered)
            .disabled(!isBrowserInstalled(browser))
            if !isBrowserInstalled(browser) {
                Text("This browser was not found on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cleanerCard()
    }

    private var accessNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Full Disk Access is needed", systemImage: "lock.shield")
                .font(.headline)
            Text("Enable Mac Cleaner under Full Disk Access in System Settings, then return to Overview. This tool uses the same permission and does not ask for another one.")
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
    private var inventoryContent: some View {
        if isScanning {
            VStack(spacing: 10) {
                ProgressView()
                if let progress = progressState.progress {
                    Text("Checking \(progress.locationName) · \(progress.entriesChecked.formatted()) items")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Finding Safari, Chrome, and Firefox cache folders…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        } else if inventory.wasCancelled {
            ContentUnavailableView(
                "Scan cancelled",
                systemImage: "stop.circle",
                description: Text("No partial cache results are available. Run the scan again when you are ready.")
            )
            .frame(minHeight: 200)
        } else if accessUnavailable {
            ContentUnavailableView(
                "Full Disk Access unavailable",
                systemImage: "lock.shield",
                description: Text("Enable Mac Cleaner under Full Disk Access in System Settings, then return here to scan browser caches.")
            )
            .frame(minHeight: 200)
        } else if !hasScanned {
            ContentUnavailableView(
                "Review browser cache",
                systemImage: "hand.raised.slash",
                description: Text("Check recognized local Safari, Chrome, and Firefox cache folders. History, site data, and saved sign-ins stay in the browser.")
            )
            .frame(minHeight: 200)
        } else if inventory.candidates.isEmpty {
            ContentUnavailableView(
                inventory.skippedLocations > 0 ? "Some cache locations were unavailable" : "No browser caches found",
                systemImage: inventory.skippedLocations > 0 ? "exclamationmark.triangle" : "checkmark.circle",
                description: Text(inventory.skippedLocations > 0
                    ? "Mac Cleaner skipped locations it could not read or validate. No files were changed."
                    : "No recognized Safari, Chrome, or Firefox cache folders were found in the checked locations.")
            )
            .frame(minHeight: 200)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("\(inventory.candidates.count) cache folders")
                        .font(.headline)
                    Spacer()
                    if !selectedCandidates.isEmpty {
                        Text("\(selectedCandidates.count) selected · \(selectedBytes.formattedByteCount)")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(MacCleanerTheme.secondaryText)
                    }
                }

                if inventory.wasLimited {
                    Label("The scan reached its safety limit. Some cache entries were not checked and remain unavailable for cleanup.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if inventory.skippedLocations > 0 {
                    Label("\(inventory.skippedLocations) location(s) could not be read or validated.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(inventory.candidates) { candidate in
                    BrowserCacheReviewRow(
                        candidate: candidate,
                        isSelected: selectionBinding(for: candidate),
                        isBusy: isMoving,
                        onReveal: {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                URL(fileURLWithPath: candidate.path, isDirectory: true)
                            ])
                        }
                    )
                }

                HStack {
                    Spacer()
                    Button {
                        showingReview = true
                    } label: {
                        Label("Review Selected Cache Folders", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MacCleanerTheme.accent)
                    .disabled(selectedCandidates.isEmpty || isMoving)
                }
            }
        }
    }

    private func selectionBinding(for candidate: BrowserCacheCandidate) -> Binding<Bool> {
        Binding(
            get: { selectedPaths.contains(candidate.path) },
            set: { selected in
                if selected { selectedPaths.insert(candidate.path) }
                else { selectedPaths.remove(candidate.path) }
            }
        )
    }

    private func scan() {
        guard !isScanning && !isMoving else { return }
        operationMessage = nil
        browserLaunchMessage = nil
        selectedPaths.removeAll()
        accessUnavailable = false
        guard let access = model.borrowDiskAccess() else {
            accessUnavailable = true
            inventory = BrowserPrivacyInventory(candidates: [], skippedLocations: 0, wasLimited: false, wasCancelled: false)
            hasScanned = true
            return
        }

        isScanning = true
        progressState.progress = nil
        let service = BrowserPrivacyCleanupService()
        let running = Self.runningBrowserBundleIdentifiers
        let progressState = progressState
        let task = Task.detached(priority: .utility) {
            service.scan(runningBundleIdentifiers: running, isCancelled: { Task.isCancelled }) { progress in
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
            progressState.progress = nil
        }
    }

    private func moveSelectedCaches() {
        guard !isMoving, !selectedCandidates.isEmpty else { return }
        operationMessage = nil
        guard let access = model.borrowDiskAccess() else {
            accessUnavailable = true
            operationMessage = "Full Disk Access is unavailable. Enable Mac Cleaner in System Settings, then try again."
            return
        }

        isMoving = true
        let candidates = selectedCandidates
        let running = Self.runningBrowserBundleIdentifiers
        let service = BrowserPrivacyCleanupService()
        Task {
            let outcomes = await Task.detached(priority: .utility) {
                candidates.map { candidate -> BrowserCacheActionOutcome in
                    do {
                        let result = try service.moveToTrash(candidate, runningBundleIdentifiers: running)
                        return BrowserCacheActionOutcome(path: result.path, sizeBytes: result.sizeBytes, error: nil)
                    } catch {
                        return BrowserCacheActionOutcome(path: candidate.path, sizeBytes: 0, error: error.localizedDescription)
                    }
                }
            }.value
            access.stopAccessingSecurityScopedResource()

            let moved = outcomes.filter { $0.error == nil }
            let movedPaths = Set(moved.map(\.path))
            inventory = BrowserPrivacyInventory(
                candidates: inventory.candidates.filter { !movedPaths.contains($0.path) },
                skippedLocations: inventory.skippedLocations,
                wasLimited: inventory.wasLimited,
                wasCancelled: inventory.wasCancelled
            )
            selectedPaths.subtract(movedPaths)
            showingReview = false
            isMoving = false

            if !moved.isEmpty {
                let movedBytes = moved.reduce(Int64(0)) { total, outcome in
                    let (sum, overflow) = total.addingReportingOverflow(outcome.sizeBytes)
                    return overflow ? Int64.max : sum
                }
                model.activity.record(
                    title: "Browser caches moved to Trash",
                    files: moved.count,
                    bytes: movedBytes,
                    note: "Selected Safari, Chrome, or Firefox cache folders were moved to Trash after review. Browser profile paths and website data are not saved in activity.",
                    kind: .cleanup
                )
                operationMessage = "Moved \(moved.count) cache folder(s) to Trash. Browsers can rebuild temporary cache files as needed."
            }

            let failures = outcomes.compactMap { outcome -> String? in
                guard let error = outcome.error else { return nil }
                let title = candidates.first { $0.path == outcome.path }?.title ?? "Selected cache"
                return "\(title): \(error)"
            }
            if !failures.isEmpty {
                operationMessage = ([operationMessage].compactMap { $0 } + failures).joined(separator: " ")
            }
        }
    }

    private func openPrivacyControls(for browser: LocalBrowser) {
        browserLaunchMessage = nil
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) else {
            browserLaunchMessage = "\(browser.title) is not installed on this Mac."
            return
        }
        let privacyURL: URL?
        switch browser {
        case .safari:
            privacyURL = nil
        case .chrome:
            privacyURL = URL(string: "chrome://settings/clearBrowserData")
        case .firefox:
            privacyURL = URL(string: "about:preferences#privacy")
        }
        if let privacyURL {
            NSWorkspace.shared.open(
                [privacyURL],
                withApplicationAt: applicationURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                guard let error else { return }
                Task { @MainActor in browserLaunchMessage = "\(browser.title) privacy settings could not be opened: \(error.localizedDescription)" }
            }
        } else {
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard let error else { return }
                Task { @MainActor in browserLaunchMessage = "\(browser.title) could not be opened: \(error.localizedDescription)" }
            }
        }
    }

    private func browserSymbol(for browser: LocalBrowser) -> String {
        switch browser {
        case .safari: "safari"
        case .chrome, .firefox: "globe"
        }
    }

    private func isBrowserInstalled(_ browser: LocalBrowser) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) != nil
    }

    private static var runningBrowserBundleIdentifiers: Set<String> {
        let supportedIdentifiers = Set(LocalBrowser.allCases.map(\.bundleIdentifier))
        return Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).filter(supportedIdentifiers.contains))
    }
}

private struct BrowserCacheReviewRow: View {
    let candidate: BrowserCacheCandidate
    @Binding var isSelected: Bool
    let isBusy: Bool
    let onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: $isSelected) {
                HStack(spacing: 12) {
                    Image(systemName: candidate.browser == .safari ? "safari" : "globe")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(MacCleanerTheme.accent)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.title)
                            .fontWeight(.semibold)
                        Text("\(candidate.fileCount.formatted()) files · \(candidate.sizeBytes.formattedByteCount)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if let lastChangedAt = candidate.lastChangedAt {
                        Text("Changed \(lastChangedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!candidate.canMoveToTrash || isBusy)

            if let statusMessage = candidate.statusMessage {
                Label(statusMessage, systemImage: candidate.browserIsRunning ? "pause.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(candidate.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Show in Finder", action: onReveal)
                    .buttonStyle(.link)
                    .disabled(isBusy)
            }
        }
        .padding(14)
        .cleanerCard()
    }
}

private struct BrowserCacheCleanupReview: View {
    let candidates: [BrowserCacheCandidate]
    let isMoving: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Review browser caches")
                    .font(.title2.bold())
                Text("Only the exact cache folders listed below will be moved to Trash.")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(candidates) { candidate in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(candidate.title).fontWeight(.semibold)
                                Spacer()
                                Text(candidate.sizeBytes.formattedByteCount)
                                    .monospacedDigit()
                            }
                            Text(candidate.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .cleanerCard()
                    }
                }
            }

            Label("This does not remove browsing history, download records, cookies, site data, saved passwords, or downloaded files. Moved caches remain recoverable in Trash.", systemImage: "checkmark.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .disabled(isMoving)
                Button(isMoving ? "Moving…" : "Move \(candidates.count) to Trash", role: .destructive, action: onConfirm)
                    .disabled(isMoving || candidates.isEmpty)
            }
        }
        .padding(22)
        .frame(minWidth: 620, idealWidth: 700, minHeight: 440, idealHeight: 540)
    }
}

private struct BrowserCacheActionOutcome: Sendable {
    let path: String
    let sizeBytes: Int64
    let error: String?
}

@MainActor
private final class BrowserPrivacyProgressState: ObservableObject {
    @Published var progress: BrowserPrivacyProgress?
}
