import AppKit
import SwiftUI

@MainActor
private final class ApplicationLeftoverScanStatus: ObservableObject {
    @Published var message = "Checking installed apps and common data locations…"
}

private func possibleAppName(for identifier: String) -> String {
    let components = identifier.split(separator: ".").map(String.init)
    var name = components.last ?? identifier
    if ["app", "application", "client", "main"].contains(name.lowercased()), components.count > 1 {
        name = components[components.count - 2]
    }
    return name
        .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        .localizedCapitalized
}

struct ApplicationLeftoversView: View {
    @ObservedObject var model: ScanViewModel
    @StateObject private var scanStatus = ApplicationLeftoverScanStatus()
    @State private var scanResult: ApplicationLeftoverScanResult?
    @State private var isScanning = false
    @State private var searchText = ""
    @State private var selectedPaths = Set<String>()
    @State private var reviewedPaths = Set<String>()
    @State private var review: ApplicationLeftoverReviewState?
    @State private var errorMessage: String?
    @State private var resultMessage = ""
    @State private var selectionLimitMessage = ""

    private let selectionLimit = 50

    private var standardApplicationRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            SafeFilePolicy.accountHome.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        ]
    }

    private var filteredCandidates: [ApplicationDataCandidate] {
        guard let scanResult else { return [] }
        guard !searchText.isEmpty else { return scanResult.candidates }
        return scanResult.candidates.filter {
            $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
                || $0.location.title.localizedCaseInsensitiveContains(searchText)
                || $0.url.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredGroupContainers: [ApplicationGroupContainer] {
        guard let scanResult else { return [] }
        guard !searchText.isEmpty else { return scanResult.groupContainers.containers }
        return scanResult.groupContainers.containers.filter { container in
            container.groupIdentifier.localizedCaseInsensitiveContains(searchText)
                || container.url.path.localizedCaseInsensitiveContains(searchText)
                || container.owners.contains {
                    $0.applicationName.localizedCaseInsensitiveContains(searchText)
                        || $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
                }
        }
    }

    private var selectedCandidates: [ApplicationDataCandidate] {
        scanResult?.candidates.filter { selectedPaths.contains($0.id) } ?? []
    }

    private var selectedBytes: Int64 {
        selectedCandidates.reduce(0) { $0 + $1.logicalSize }
    }

    private var noResultsDescription: String {
        guard searchText.isEmpty else { return "Try a different app name, group name, or location." }
        guard let groupScan = scanResult?.groupContainers,
              groupScan.ownershipEvidenceIncomplete || groupScan.unreadableLocations > 0 || groupScan.wasLimited else {
            return "No possible app leftovers or shared app folders were found in the locations Mac Cleaner checked."
        }
        return "No possible app leftovers were found, but the App Group folder list could not be fully checked. See the note above."
    }

    private var selectedSizeSummary: String {
        if selectedCandidates.contains(where: \.sizeIncomplete) {
            return selectedBytes > 0
                ? "At least \(selectedBytes.formattedByteCount) checked; some sizes incomplete"
                : "some folder sizes incomplete"
        }
        return selectedBytes.formattedByteCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("App Leftovers").font(.largeTitle.bold())
                    Text("Review possible app leftovers and see which installed apps declare access to shared folders.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(scanResult == nil ? "Find Possible Leftovers" : "Scan Again", action: scan)
                    .buttonStyle(.borderedProminent)
                    .tint(MacCleanerTheme.accent)
                    .disabled(isScanning || model.isCleaning)
            }

            if isScanning {
                ProgressView(scanStatus.message)
                Text("This is a read-only scan. It checks names and file sizes, not file contents. Large app-data folders may take a moment.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else if let scanResult {
                scanWarnings(scanResult)
                HStack {
                    Text("\(filteredCandidates.count) possible locations · \(filteredGroupContainers.count) shared folders (view only)").font(.headline)
                    Spacer()
                    TextField("Search app names or locations", text: $searchText)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                }

                if filteredCandidates.isEmpty && filteredGroupContainers.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No possible leftovers found" : "No matching locations",
                        systemImage: searchText.isEmpty ? "checkmark.circle" : "magnifyingglass",
                        description: Text(noResultsDescription)
                    )
                } else {
                    List {
                        if !filteredCandidates.isEmpty {
                            Section("Possible app leftovers") {
                                ForEach(filteredCandidates) { candidate in
                                    leftoverRow(candidate)
                                }
                            }
                        }
                        if !filteredGroupContainers.isEmpty {
                            Section("Shared App Group folders · view only") {
                                ForEach(filteredGroupContainers) { container in
                                    groupContainerRow(container)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }

                if !selectionLimitMessage.isEmpty {
                    Label(selectionLimitMessage, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !resultMessage.isEmpty {
                    Label(resultMessage, systemImage: resultMessage.contains("could not") ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Text("Selected: \(selectedPaths.count) · \(selectedSizeSummary)")
                    Spacer()
                    Text("Up to \(selectionLimit) locations per review")
                        .foregroundStyle(.secondary)
                    Button("Review Selected") {
                        review = ApplicationLeftoverReviewState(scan: scanResult, candidates: selectedCandidates)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MacCleanerTheme.accent)
                    .disabled(selectedCandidates.isEmpty || isScanning)
                }
                .font(.caption)
            } else {
                ContentUnavailableView(
                    "Find possible app leftovers",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Mac Cleaner checks seven common app-data folders and lists shared App Group folders with any installed apps that declare access. Nothing is selected automatically.")
                )
            }
        }
        .padding(28)
        .sheet(item: $review) { review in
            ApplicationLeftoverReview(
                candidates: review.candidates,
                move: { selectedPaths in try await move(review.scan, selectedPaths: selectedPaths) },
                onComplete: completeMove
            )
        }
        .alert("Cannot scan app data", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func scanWarnings(_ result: ApplicationLeftoverScanResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                "A name match does not prove data is unused. Apps in custom folders or on external drives may still use these locations. Review every exact path in Finder.",
                systemImage: "info.circle"
            )
            Label("Folder sizes use file details only. Mac Cleaner does not open or read file contents.", systemImage: "doc.text.magnifyingglass")
            Label("App Group folders are designed to be shared. Mac Cleaner shows signed app access declarations but cannot verify every app copy or helper, so these folders are view-only.", systemImage: "person.2")
            if result.groupContainers.ownershipEvidenceIncomplete {
                Label("App Group ownership evidence is incomplete. The displayed owners may be only part of the picture.", systemImage: "exclamationmark.triangle")
            }
            if result.groupContainers.unreadableLocations > 0 {
                Label("Some App Group folders could not be listed.", systemImage: "lock")
            }
            if result.groupContainers.wasLimited {
                Label("The App Group folder list reached its safety limit.", systemImage: "ellipsis.circle")
            }
            if result.installedAppInventoryIncomplete {
                Label("The installed-app scan was incomplete. These results are view-only until a complete scan is possible.", systemImage: "lock")
            }
            if result.unreadableLocations > 0 {
                Label("Some data locations could not be read, so the list may be incomplete.", systemImage: "exclamationmark.triangle")
            }
            if result.wasLimited {
                Label("The scan reached its safety limit. Rescan later to review additional locations.", systemImage: "ellipsis.circle")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func groupContainerRow(_ container: ApplicationGroupContainer) -> some View {
        let listedOwners = container.owners.prefix(3).map { "\($0.applicationName) (\($0.bundleIdentifier))" }
        let hiddenOwnerCount = container.owners.count - listedOwners.count
        let ownersDescription = container.owners.isEmpty
            ? "No matching owner found in the checked Applications folders."
            : "Signed access declared by: " + listedOwners.joined(separator: ", ") + (hiddenOwnerCount > 0 ? ", and \(hiddenOwnerCount) more" : "")
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.2.fill")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(container.groupIdentifier).font(.headline)
                Text(ownersDescription)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Text(container.url.path)
                    .font(.caption).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                Text("Other app copies or helpers may also use this shared folder. Mac Cleaner does not offer it for cleanup.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([container.url]) }
                .controlSize(.small)
        }
        .padding(.vertical, 7)
    }

    private func leftoverRow(_ candidate: ApplicationDataCandidate) -> some View {
        let sizeLabel = candidate.sizeIncomplete
            ? (candidate.logicalSize > 0 ? "At least \(candidate.logicalSize.formattedByteCount) checked" : "Size not fully checked")
            : candidate.logicalSize.formattedByteCount
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: selection(for: candidate)) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(candidate.match.isRecognizedSuffix
                                ? "Possible related data for \(possibleAppName(for: candidate.bundleIdentifier))"
                                : "Possible data for \(possibleAppName(for: candidate.bundleIdentifier))")
                                .font(.headline)
                            if candidate.match.isRecognizedSuffix {
                                Text("Possible match")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(MacCleanerTheme.accent.opacity(0.12), in: Capsule())
                                    .foregroundStyle(MacCleanerTheme.accent)
                            }
                            Spacer()
                            Text(sizeLabel)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("App identifier: \(candidate.bundleIdentifier)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(candidate.location.title).font(.subheadline.weight(.medium))
                        Text(candidate.url.path)
                            .font(.caption).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        Text(candidate.safetyNote)
                            .font(.caption).foregroundStyle(candidate.safeToMove ? MacCleanerTheme.secondaryText : Color.orange)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!candidate.safeToMove || !reviewedPaths.contains(candidate.id)
                    || (!selectedPaths.contains(candidate.id) && selectedPaths.count >= selectionLimit))
                if candidate.safeToMove {
                    Toggle("I reviewed this location in Finder", isOn: reviewAcknowledgement(for: candidate))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([candidate.url]) }
                .controlSize(.small)
        }
        .padding(.vertical, 5)
    }

    private func selection(for candidate: ApplicationDataCandidate) -> Binding<Bool> {
        Binding(
            get: { selectedPaths.contains(candidate.id) },
            set: { selected in
                if selected {
                    guard selectedPaths.count < selectionLimit else {
                        selectionLimitMessage = "Review up to \(selectionLimit) locations at a time."
                        return
                    }
                    selectedPaths.insert(candidate.id)
                    selectionLimitMessage = ""
                } else {
                    selectedPaths.remove(candidate.id)
                    selectionLimitMessage = ""
                }
            }
        )
    }

    private func reviewAcknowledgement(for candidate: ApplicationDataCandidate) -> Binding<Bool> {
        Binding(
            get: { reviewedPaths.contains(candidate.id) },
            set: { reviewed in
                if reviewed { reviewedPaths.insert(candidate.id) }
                else {
                    reviewedPaths.remove(candidate.id)
                    selectedPaths.remove(candidate.id)
                }
            }
        )
    }

    private func scan() {
        guard let access = model.borrowDiskAccess() else {
            errorMessage = "Full Disk Access is unavailable. Enable Mac Cleaner in System Settings, then try again."
            return
        }
        isScanning = true
        scanStatus.message = "Checking apps and signed shared-folder access…"
        errorMessage = nil
        resultMessage = ""
        selectionLimitMessage = ""
        reviewedPaths.removeAll()
        let roots = standardApplicationRoots
        let home = SafeFilePolicy.accountHome
        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let scanStatus = self.scanStatus
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let installed = ApplicationInventory().bundleIdentifiers(roots: roots) { applicationName, inspectedCount in
                    Task { @MainActor in
                        scanStatus.message = "Checking signed access · app \(inspectedCount) · \(String(applicationName.prefix(48)))…"
                    }
                }
                let leftovers = ApplicationRemovalService(home: home).scanLeftovers(
                    installedApps: installed,
                    runningBundleIDs: runningBundleIDs,
                    progress: { location, index, total in
                        Task { @MainActor in
                            scanStatus.message = "Checking \(location.title.lowercased()) · \(index) of \(total)…"
                        }
                    }
                )
                return leftovers
            }.value
            access.stopAccessingSecurityScopedResource()
            scanResult = result
            selectedPaths.removeAll()
            reviewedPaths.removeAll()
            isScanning = false
        }
    }

    private func move(_ scan: ApplicationLeftoverScanResult, selectedPaths: Set<String>) async throws -> ApplicationDataMoveResult {
        guard selectedPaths.isSubset(of: reviewedPaths) else { throw ApplicationRemovalError.invalidSelection }
        guard let access = model.borrowDiskAccess() else { throw ApplicationRemovalError.inaccessible }
        defer { access.stopAccessingSecurityScopedResource() }
        let roots = standardApplicationRoots
        let home = SafeFilePolicy.accountHome
        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let reviewedPaths = self.reviewedPaths
        let installed = await Task.detached(priority: .userInitiated) {
            ApplicationInventory().bundleIdentifiers(roots: roots, includeSignedGroupOwnership: false)
        }.value
        return try await Task.detached(priority: .userInitiated) {
            try ApplicationRemovalService(home: home).moveLeftoversToTrash(
                scan,
                selectedPaths: selectedPaths,
                installedApps: installed,
                runningBundleIDs: runningBundleIDs,
                reviewedPaths: reviewedPaths
            )
        }.value
    }

    private func completeMove(_ result: ApplicationDataMoveResult) {
        let movedPaths = Set(result.movedPaths)
        let movedCandidates = scanResult?.candidates.filter { movedPaths.contains($0.id) } ?? []
        let hasUnknownFolderSize = movedCandidates.contains(where: \.sizeIncomplete)
        if !result.movedPaths.isEmpty {
            model.activity.record(
                title: "Possible app data moved to Trash",
                files: result.movedPaths.count,
                bytes: result.bytesMoved,
                note: "Only locations you selected were moved. App ownership was not proven; logical sizes are estimates, and items remain recoverable in Trash.\(hasUnknownFolderSize ? " Some folder sizes were incomplete." : "")",
                kind: .cleanup
            )
        }
        if let scanResult {
            self.scanResult = ApplicationLeftoverScanResult(
                candidates: scanResult.candidates.filter { !movedPaths.contains($0.id) },
                groupContainers: scanResult.groupContainers,
                unreadableLocations: scanResult.unreadableLocations,
                wasLimited: scanResult.wasLimited,
                installedAppInventoryIncomplete: scanResult.installedAppInventoryIncomplete
            )
        }
        selectedPaths.removeAll()
        reviewedPaths.subtract(movedPaths)
        let sizeNote = hasUnknownFolderSize ? " Some folder sizes were incomplete." : ""
        resultMessage = result.failures.isEmpty
            ? "Moved \(result.movedPaths.count) selected location(s) to Trash.\(sizeNote)"
            : "Moved \(result.movedPaths.count) location(s); \(result.failures.count) could not be moved. Those items were left in place.\(sizeNote)"
        if !result.failures.isEmpty {
            let details = result.failures.prefix(5).map { "\(URL(fileURLWithPath: $0.path).lastPathComponent): \($0.reason)" }.joined(separator: "\n")
            resultMessage += "\n\n" + details
        }
    }
}

private struct ApplicationLeftoverReviewState: Identifiable {
    let scan: ApplicationLeftoverScanResult
    let candidates: [ApplicationDataCandidate]
    var id: String { candidates.map(\.id).joined(separator: "|") }
}

private struct ApplicationLeftoverReview: View {
    let candidates: [ApplicationDataCandidate]
    let move: (Set<String>) async throws -> ApplicationDataMoveResult
    let onComplete: (ApplicationDataMoveResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false
    @State private var moving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review possible leftovers").font(.title.bold())
            Text(candidates.contains(where: { $0.match.isRecognizedSuffix })
                ? "Some names are only possible matches based on a familiar suffix and another unused app-data name. That clue can be wrong. Review every exact path in Finder before moving it."
                : "These exact names were not matched to apps found in standard Applications folders. They may belong to apps installed elsewhere or contain settings and personal data. Review each path in Finder before moving it.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(candidates) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Possible data for \(possibleAppName(for: item.bundleIdentifier))").font(.headline)
                            Text("App identifier: \(item.bundleIdentifier)").font(.caption).foregroundStyle(.secondary)
                            Text(item.location.title).font(.subheadline)
                            Text(item.url.path).font(.caption).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                            HStack {
                                Text(item.sizeIncomplete ? "Folder size not calculated" : item.logicalSize.formattedByteCount)
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                    .controlSize(.small)
                            }
                        }
                        Divider()
                    }
                }
            }
            Text("Mac Cleaner checks names and basic file details, not file contents. Selected locations move to Trash, which is not emptied.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.disabled(moving)
                Button("Move \(candidates.count) to Trash") { confirm = true }
                    .buttonStyle(.borderedProminent).tint(.red).disabled(candidates.isEmpty || moving)
            }
            if moving { ProgressView("Rechecking and moving selected locations…") }
        }
        .padding(24).frame(width: 760, height: 620)
        .alert("Move possible app data to Trash?", isPresented: $confirm) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                moving = true
                Task {
                    do {
                        let result = try await move(Set(candidates.map(\.id)))
                        onComplete(result)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    moving = false
                }
            }
        } message: {
            Text(candidates.contains(where: { $0.match.isRecognizedSuffix })
                ? "Move these exact \(candidates.count) reviewed locations to Trash? Some are only possible name matches and may belong to another app. They can be restored from Trash."
                : "Move the exact \(candidates.count) locations listed in this review to Trash? They can be restored from Trash. Nothing will be permanently deleted.")
        }
        .alert("No locations were moved", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
