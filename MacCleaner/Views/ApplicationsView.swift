import AppKit
import SwiftUI

struct ApplicationsView: View {
    @ObservedObject var model: ScanViewModel
    @State private var apps: [InstalledApplication] = []
    @State private var query = ""
    @State private var scanning = false
    @State private var scanned = false
    @State private var inaccessible = 0
    @State private var inventoryWasLimited = false
    @State private var inventoryWasCancelled = false
    @State private var inventoryTask: Task<ApplicationInventoryResult, Never>?
    @State private var diskAccessUnavailable = false
    @State private var preparingReview = false
    @State private var selectedAppIDs = Set<String>()
    @State private var review: ApplicationReview?
    @State private var reviewAccess: URL?
    @State private var reviewError: String?
    @State private var showRemovalResult = false
    @State private var resultTitle = ""
    @State private var resultMessage = ""

    private var filtered: [InstalledApplication] {
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Applications").font(.largeTitle.bold())
                    Text("See installed apps and their sizes, and show them in Finder.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(scanning ? "Cancel Scan" : (scanned ? "Refresh" : "Find Applications")) {
                    if scanning { inventoryTask?.cancel() } else { scan() }
                }
                    .buttonStyle(.borderedProminent).tint(MacCleanerTheme.accent).disabled(preparingReview)
            }
            if scanning {
                ProgressView("Finding apps and measuring their folders…")
                Text("This may take a moment for large apps.").foregroundStyle(.secondary)
                Spacer()
            } else if !scanned {
                ContentUnavailableView("Find your applications", systemImage: "square.stack.3d.up", description: Text("Scan the standard Applications folders to see app versions and sizes."))
            } else {
                HStack {
                    Text("\(filtered.count) apps").font(.headline)
                    Spacer()
                    TextField("Search apps", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                }
                if inaccessible > 0 || inventoryWasLimited || inventoryWasCancelled {
                    Label(
                        inventoryWasCancelled
                            ? "The scan stopped early. The list or sizes may be incomplete."
                            : inventoryWasLimited
                                ? "The scan reached its safety limit. The list or sizes may be incomplete."
                                : "Some locations could not be read. The list or sizes may be incomplete.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if diskAccessUnavailable {
                    Label("Full Disk Access is unavailable. Some apps or sizes may be missing; enable Mac Cleaner in System Settings and refresh.", systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                List(filtered) { app in
                    HStack(spacing: 12) {
                        Button {
                            if selectedAppIDs.contains(app.id) { selectedAppIDs.remove(app.id) }
                            else { selectedAppIDs.insert(app.id) }
                        } label: {
                            Image(systemName: selectedAppIDs.contains(app.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedAppIDs.contains(app.id) ? MacCleanerTheme.accent : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(isProtected(app) || isRunning(app))
                        .accessibilityLabel(selectedAppIDs.contains(app.id) ? "Unselect \(app.name)" : "Select \(app.name)")
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).fontWeight(.medium)
                            Text([app.version.flatMap { $0.isEmpty ? nil : "Version \($0)" }, app.bundleIdentifier].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("\(app.sizeIncomplete ? "At least " : "")\(ByteCountFormatter.string(fromByteCount: app.logicalSize, countStyle: .file))")
                            .foregroundStyle(.secondary)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                        Button("Reset App") { prepareReview(app, mode: .reset) }
                            .disabled(preparingReview || isProtected(app) || isRunning(app))
                        Button("Review Removal") { prepareReview(app, mode: .remove) }
                            .disabled(preparingReview || isProtected(app) || isRunning(app))
                    }.padding(.vertical, 4)
                }
                HStack {
                    Text("Sizes count app contents, not shared support files or guaranteed recovered space.")
                    Spacer()
                    if !selectedAppIDs.isEmpty {
                        Button("Review \(selectedAppIDs.count) selected") { prepareBatchRemoval() }
                            .buttonStyle(.borderedProminent).tint(MacCleanerTheme.accent).disabled(preparingReview)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if preparingReview { ProgressView("Checking app data locations…") }
            }
        }
        .padding(28)
        .sheet(item: $review, onDismiss: {
            reviewAccess?.stopAccessingSecurityScopedResource()
            reviewAccess = nil
            if !resultMessage.isEmpty { showRemovalResult = true }
        }) { review in
            switch review {
            case .remove(let plan):
                ApplicationRemovalReview(plan: plan) { selectedPaths in
                    let outcome = try ApplicationRemovalService().moveToTrash(plan, selectedRelatedPaths: selectedPaths, runningBundleIDs: runningIDs(for: plan.app))
                    if outcome.appMoved { apps.removeAll { $0.id == plan.app.id }; selectedAppIDs.remove(plan.app.id) }
                    record(outcome, plan: plan)
                    let failureCount = outcome.relatedData.failures.count + (outcome.appFailure == nil ? 0 : 1)
                    resultTitle = outcome.appMoved ? "App moved to Trash" : "Removal not completed"
                    if outcome.appMoved {
                        resultMessage = "\(plan.app.name) was moved to Trash. \(outcome.relatedData.movedPaths.count) selected data location(s) were also moved.\(failureCount > 0 ? " \(failureCount) item(s) could not be moved; review them and try again." : "")"
                    } else {
                        resultMessage = "The app stayed in place. \(outcome.relatedData.movedPaths.count) selected data location(s) were moved to Trash before this issue: \(outcome.appFailure ?? "Unknown error")."
                    }
                    let details = failureDetails(outcome.relatedData.failures, appFailure: outcome.appFailure)
                    if !details.isEmpty { resultMessage += "\n\nDetails:\n\(details)" }
                    self.review = nil
                    return outcome
                }
            case .reset(let plan):
                ApplicationDataReview(plan: plan) { selectedPaths in
                    let result = try ApplicationRemovalService().resetData(plan, selectedPaths: selectedPaths, runningBundleIDs: runningIDs(for: plan.app))
                    if !result.movedPaths.isEmpty {
                        model.activity.record(title: "Application data moved to Trash", files: result.movedPaths.count, bytes: result.bytesMoved, note: "Only selected exact bundle-ID locations were moved; the app remains installed.", kind: .cleanup)
                    }
                    resultTitle = result.failures.isEmpty ? "App data moved to Trash" : "App data partially moved"
                    resultMessage = "\(result.movedPaths.count) selected location(s) were moved for \(plan.app.name).\(result.failures.isEmpty ? "" : " \(result.failures.count) location(s) changed or could not be moved and were left in place.") The app remains installed."
                    let details = failureDetails(result.failures)
                    if !details.isEmpty { resultMessage += "\n\nDetails:\n\(details)" }
                    self.review = nil
                    return result
                }
            case .batch(let batch):
                BatchApplicationRemovalReview(batch: batch) { appIDsToRemove, selectedPaths in
                    let service = ApplicationRemovalService()
                    var outcomes: [String: ApplicationRemovalOutcome] = [:]
                    var failedApps = 0
                    var failedAppDetails: [String] = []
                    let selectedPlans = batch.plans.filter { appIDsToRemove.contains($0.id) }
                    for plan in selectedPlans {
                        do {
                            outcomes[plan.id] = try service.moveToTrash(plan, selectedRelatedPaths: selectedPaths.intersection(Set(plan.relatedData.map(\.id))), runningBundleIDs: runningIDs(for: plan.app))
                        } catch {
                            failedApps += 1
                            failedAppDetails.append("\(plan.app.name): \(error.localizedDescription)")
                        }
                    }
                    let moved = outcomes.values.filter(\.appMoved).count
                    for plan in selectedPlans {
                        guard let outcome = outcomes[plan.id] else { continue }
                        if outcome.appMoved { apps.removeAll { $0.id == plan.app.id }; self.selectedAppIDs.remove(plan.app.id) }
                        record(outcome, plan: plan)
                    }
                    let dataCount = outcomes.values.reduce(0) { $0 + $1.relatedData.movedPaths.count }
                    let failures = outcomes.values.reduce(failedApps) { $0 + $1.relatedData.failures.count + ($1.appFailure == nil ? 0 : 1) }
                    resultTitle = moved == selectedPlans.count && failedApps == 0 ? "Apps moved to Trash" : "Some apps stayed in place"
                    resultMessage = "\(moved) of \(selectedPlans.count) selected app(s) moved to Trash; \(dataCount) selected data location(s) also moved.\(failures > 0 ? " \(failures) item(s) could not be moved." : "")"
                    var outcomeDetails: [String] = []
                    for plan in selectedPlans {
                        guard let outcome = outcomes[plan.id] else { continue }
                        if let appFailure = outcome.appFailure { outcomeDetails.append("\(plan.app.name): \(appFailure)") }
                        let dataFailure = failureDetails(outcome.relatedData.failures)
                        if !dataFailure.isEmpty { outcomeDetails.append("\(plan.app.name):\n\(dataFailure)") }
                    }
                    let details = (failedAppDetails + outcomeDetails).joined(separator: "\n")
                    if !details.isEmpty { resultMessage += "\n\nDetails:\n\(details)" }
                    self.review = nil
                    return outcomes
                }
            }
        }
        .alert("Cannot review this app", isPresented: Binding(get: { reviewError != nil }, set: { if !$0 { reviewError = nil } })) {
            Button("OK") { reviewError = nil }
        } message: { Text(reviewError ?? "") }
        .alert(resultTitle, isPresented: $showRemovalResult) {
            Button("OK") { resultTitle = ""; resultMessage = "" }
        } message: { Text(resultMessage) }
        .onDisappear {
            inventoryTask?.cancel()
        }
    }

    private func scan() {
        scanning = true
        inventoryWasLimited = false
        inventoryWasCancelled = false
        let access = model.borrowDiskAccess()
        diskAccessUnavailable = access == nil
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true), SafeFilePolicy.accountHome.appendingPathComponent("Applications", isDirectory: true)]
        let worker = Task.detached(priority: .userInitiated) {
            ApplicationInventory().scan(roots: roots, isCancelled: { Task.isCancelled })
        }
        inventoryTask = worker
        Task {
            let result = await worker.value
            access?.stopAccessingSecurityScopedResource()
            apps = result.applications
            selectedAppIDs.formIntersection(Set(result.applications.map(\.id)))
            inaccessible = result.inaccessibleLocations
            inventoryWasLimited = result.wasLimited
            inventoryWasCancelled = result.wasCancelled
            scanned = true
            scanning = false
            inventoryTask = nil
        }
    }

    private func prepareReview(_ app: InstalledApplication, mode: ApplicationReview.Mode) {
        guard let access = model.borrowDiskAccess() else {
            reviewError = "Full Disk Access is unavailable. Enable Mac Cleaner in System Settings, then refresh this list."
            return
        }
        preparingReview = true
        let running = runningIDs(for: app)
        Task {
            do {
                let plan = try await Task.detached(priority: .userInitiated) {
                    try ApplicationRemovalService().prepare(app, runningBundleIDs: running)
                }.value
                reviewAccess = access
                review = mode == .remove ? .remove(plan) : .reset(plan)
            } catch {
                access.stopAccessingSecurityScopedResource()
                reviewError = error.localizedDescription
            }
            preparingReview = false
        }
    }

    private func prepareBatchRemoval() {
        let requested = apps.filter { selectedAppIDs.contains($0.id) }
        guard !requested.isEmpty else { return }
        guard let access = model.borrowDiskAccess() else {
            reviewError = "Full Disk Access is unavailable. Enable Mac Cleaner in System Settings, then refresh this list."
            return
        }
        preparingReview = true
        let runningByID = Dictionary(uniqueKeysWithValues: requested.map { ($0.id, runningIDs(for: $0)) })
        Task {
            do {
                let batch = await Task.detached(priority: .userInitiated) {
                    ApplicationRemovalService().prepareBatch(requested, runningBundleIDsByAppID: runningByID)
                }.value
                guard !batch.plans.isEmpty else {
                    let reasons = batch.skipped.map { "\($0.appName): \($0.reason)" }.joined(separator: "\n")
                    throw NSError(domain: "MacCleaner.ApplicationReview", code: 1, userInfo: [NSLocalizedDescriptionKey: "None of the selected apps can be reviewed right now.\n\(reasons)"])
                }
                reviewAccess = access
                review = .batch(batch)
            } catch {
                access.stopAccessingSecurityScopedResource()
                reviewError = error.localizedDescription
            }
            preparingReview = false
        }
    }

    private func record(_ outcome: ApplicationRemovalOutcome, plan: ApplicationRemovalPlan) {
        let count = outcome.relatedData.movedPaths.count + (outcome.appMoved ? 1 : 0)
        guard count > 0 else { return }
        let bytes = outcome.relatedData.bytesMoved + (outcome.appMoved ? plan.app.logicalSize : 0)
        let title = outcome.appMoved ? "Application moved to Trash" : "Application data moved to Trash"
        let failures = outcome.relatedData.failures.count + (outcome.appFailure == nil ? 0 : 1)
        model.activity.record(title: title, files: count, bytes: bytes, note: "Selected app and data locations were moved to Trash.\(failures > 0 ? " Some selected items could not be moved." : "") Sizes are logical estimates.", kind: .cleanup)
    }

    private func failureDetails(_ failures: [TrashFailure], appFailure: String? = nil) -> String {
        var details = failures.map { "\(URL(fileURLWithPath: $0.path).lastPathComponent): \($0.reason)" }
        if let appFailure { details.append("App bundle: \(appFailure)") }
        let shown = Array(details.prefix(5))
        return shown.joined(separator: "\n") + (details.count > shown.count ? "\n…and \(details.count - shown.count) more." : "")
    }

    private func runningIDs(for app: InstalledApplication) -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { running in
            guard !running.isTerminated else { return nil }
            if let url = running.bundleURL?.standardizedFileURL,
               url.path == app.url.standardizedFileURL.path || SafeFilePolicy.isInside(url.path, root: app.url.standardizedFileURL.path) {
                return app.bundleIdentifier
            }
            return running.bundleIdentifier
        })
    }

    private func isRunning(_ app: InstalledApplication) -> Bool {
        guard let identifier = app.bundleIdentifier else { return false }
        return runningIDs(for: app).contains(identifier)
    }

    private func isProtected(_ app: InstalledApplication) -> Bool {
        guard let identifier = app.bundleIdentifier else { return true }
        let lowered = identifier.lowercased()
        let path = app.url.standardizedFileURL.path
        return lowered.hasPrefix("com.apple.") || lowered == "com.manateek1.maccleaner" || path == "/System" || path.hasPrefix("/System/")
    }
}

private enum ApplicationReview: Identifiable {
    enum Mode: Equatable, Sendable { case remove, reset }
    case remove(ApplicationRemovalPlan)
    case reset(ApplicationRemovalPlan)
    case batch(ApplicationRemovalBatchPlan)

    var id: String {
        switch self {
        case .remove(let plan): "remove-\(plan.id)"
        case .reset(let plan): "reset-\(plan.id)"
        case .batch(let batch): "batch-\(batch.plans.map(\.id).joined(separator: "|"))"
        }
    }
}

private struct ApplicationRemovalReview: View {
    let plan: ApplicationRemovalPlan
    let remove: (Set<String>) throws -> ApplicationRemovalOutcome
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false
    @State private var error: String?
    @State private var selectedPaths = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review app removal").font(.title.bold())
            Text("Choose whether to move any matching app data with \(plan.app.name). Every data location starts unselected.")
            LabeledContent("Application", value: plan.app.name)
            LabeledContent("Location", value: plan.app.url.path).textSelection(.enabled)
            LabeledContent("Bundle identifier", value: plan.app.bundleIdentifier ?? "Unknown").textSelection(.enabled)
            LabeledContent("App size", value: "\(plan.app.sizeIncomplete ? "At least " : "")\(plan.app.logicalSize.formattedByteCount)")
            Divider()
            Text("Possible app data").font(.headline)
            Text("Exact bundle-ID locations and user login helpers that point directly into this app are shown. A path match does not prove ownership. Names that suggest credentials, personal history, models, development data, or sign-in settings are kept unavailable. Inspect every path before choosing it.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.relatedData) { item in
                        ApplicationDataChoice(item: item, isSelected: selection(for: item))
                    }
                    if plan.relatedData.isEmpty {
                        ContentUnavailableView("No matching app data found", systemImage: "folder", description: Text("Mac Cleaner checked common user Library locations and login helpers that point directly into this app."))
                    }
                }
            }
            Text("The app bundle will be moved to Trash. Selected data is also reversible from Trash. Some apps require their own uninstaller. App size is a logical estimate.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(selectedPaths.isEmpty ? "Move App to Trash" : "Move App and Data to Trash") { confirm = true }
                    .buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .padding(24).frame(width: 720, height: 640)
        .alert("Move \(plan.app.name) to Trash?", isPresented: $confirm) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                do { _ = try remove(selectedPaths) } catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("App bundle:\n\(plan.app.url.path)\n\nSelected data:\n\(selectedDataDescription)\n\nYou can restore moved items from Trash. Trash will not be emptied.")
        }
        .alert("App was not moved", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var selectedDataDescription: String {
        let paths = plan.relatedData.filter { selectedPaths.contains($0.id) }.map { $0.url.path }
        return paths.isEmpty ? "None" : paths.joined(separator: "\n")
    }

    private func selection(for item: ApplicationDataCandidate) -> Binding<Bool> {
        Binding(
            get: { selectedPaths.contains(item.id) },
            set: { value in if value { selectedPaths.insert(item.id) } else { selectedPaths.remove(item.id) } }
        )
    }
}

private struct ApplicationDataReview: View {
    let plan: ApplicationRemovalPlan
    let reset: (Set<String>) throws -> ApplicationDataMoveResult
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPaths = Set<String>()
    @State private var confirm = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reset \(plan.app.name)").font(.title.bold())
            Text("Move selected app data to Trash and keep the app installed. The app should be closed first. Selected locations may contain settings, saved sign-in state, or personal content; review each path before choosing it.")
                .foregroundStyle(.secondary)
            LabeledContent("Bundle identifier", value: plan.app.bundleIdentifier ?? "Unknown").textSelection(.enabled)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.relatedData) { item in
                        ApplicationDataChoice(item: item, isSelected: selection(for: item))
                    }
                    if plan.relatedData.isEmpty {
                        ContentUnavailableView("No matching app data found", systemImage: "folder", description: Text("Mac Cleaner checked common user Library locations and login helpers that point directly into this app."))
                    }
                }
            }
            HStack {
                Text("Items go to Trash. Nothing is permanently deleted.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Move \(selectedPaths.count) Selected to Trash") { confirm = true }
                    .buttonStyle(.borderedProminent).tint(MacCleanerTheme.accent).disabled(selectedPaths.isEmpty)
            }
        }
        .padding(24).frame(width: 720, height: 640)
        .alert("Reset app data?", isPresented: $confirm) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                do { _ = try reset(selectedPaths) } catch { self.error = error.localizedDescription }
            }
        } message: {
            let paths = plan.relatedData.filter { selectedPaths.contains($0.id) }.map { $0.url.path }.joined(separator: "\n")
            Text("Only these selected locations will move to Trash:\n\(paths)\n\nThe app remains installed.")
        }
        .alert("App data was not moved", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func selection(for item: ApplicationDataCandidate) -> Binding<Bool> {
        Binding(
            get: { selectedPaths.contains(item.id) },
            set: { value in if value { selectedPaths.insert(item.id) } else { selectedPaths.remove(item.id) } }
        )
    }
}

private struct BatchApplicationRemovalReview: View {
    let batch: ApplicationRemovalBatchPlan
    let remove: (Set<String>, Set<String>) throws -> [String: ApplicationRemovalOutcome]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAppIDs: Set<String>
    @State private var selectedDataPaths = Set<String>()
    @State private var confirm = false
    @State private var error: String?

    init(batch: ApplicationRemovalBatchPlan, remove: @escaping (Set<String>, Set<String>) throws -> [String: ApplicationRemovalOutcome]) {
        self.batch = batch
        self.remove = remove
        _selectedAppIDs = State(initialValue: Set(batch.plans.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review selected apps").font(.title.bold())
            Text("Every selected app starts checked. Review the exact app bundles and choose any related data separately; data locations start unchecked.")
                .foregroundStyle(.secondary)
            if !batch.skipped.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Skipped apps").font(.headline)
                    ForEach(batch.skipped) { item in
                        Text("\(item.appName): \(item.reason)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(batch.plans) { plan in
                        VStack(alignment: .leading, spacing: 9) {
                            Toggle(isOn: appSelection(for: plan)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(plan.app.name).font(.headline)
                                    Text(plan.app.url.path).font(.caption).textSelection(.enabled)
                                }
                            }
                            .toggleStyle(.checkbox)
                            if selectedAppIDs.contains(plan.id) {
                                ForEach(plan.relatedData) { item in
                                    ApplicationDataChoice(item: item, isSelected: dataSelection(for: item))
                                        .padding(.leading, 22)
                                }
                            }
                        }
                        Divider()
                    }
                }
            }
            HStack {
                Text("Apps and chosen data move to Trash; nothing is permanently deleted.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Review & Move \(selectedAppIDs.count) Apps") { confirm = true }
                    .buttonStyle(.borderedProminent).tint(.red).disabled(selectedAppIDs.isEmpty)
            }
        }
        .padding(24).frame(width: 760, height: 680)
        .alert("Move selected apps to Trash?", isPresented: $confirm) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                do { _ = try remove(selectedAppIDs, selectedDataPaths) } catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("Apps:\n\(selectedAppDescription)\n\nSelected data:\n\(selectedDataDescription)\n\nItems moved to Trash can be restored. Trash will not be emptied.")
        }
        .alert("Apps were not moved", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var selectedAppDescription: String {
        batch.plans.filter { selectedAppIDs.contains($0.id) }.map { "\($0.app.name): \($0.app.url.path)" }.joined(separator: "\n")
    }

    private var selectedDataDescription: String {
        let paths = batch.plans
            .filter { selectedAppIDs.contains($0.id) }
            .flatMap(\.relatedData)
            .filter { selectedDataPaths.contains($0.id) }
            .map { $0.url.path }
        return paths.isEmpty ? "None" : paths.joined(separator: "\n")
    }

    private func appSelection(for plan: ApplicationRemovalPlan) -> Binding<Bool> {
        Binding(get: { selectedAppIDs.contains(plan.id) }, set: { value in
            if value {
                selectedAppIDs.insert(plan.id)
            } else {
                selectedAppIDs.remove(plan.id)
                selectedDataPaths.subtract(plan.relatedData.map(\.id))
            }
        })
    }

    private func dataSelection(for item: ApplicationDataCandidate) -> Binding<Bool> {
        Binding(get: { selectedDataPaths.contains(item.id) }, set: { value in if value { selectedDataPaths.insert(item.id) } else { selectedDataPaths.remove(item.id) } })
    }
}

private struct ApplicationDataChoice: View {
    let item: ApplicationDataCandidate
    @Binding var isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(isOn: $isSelected) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.location.title).fontWeight(.medium)
                        Spacer()
                        Text("\(item.sizeIncomplete ? "At least " : "")\(item.logicalSize.formattedByteCount)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(item.url.path).font(.caption).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    Text(item.safetyNote).font(.caption).foregroundStyle(item.safeToMove ? Color.secondary : Color.orange)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!item.safeToMove)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                .controlSize(.small)
        }
    }
}
