import AppKit
import ServiceManagement
import SwiftUI

struct StartupView: View {
    @ObservedObject var model: ScanViewModel
    @State private var items: [StartupItem] = []
    @State private var query = ""
    @State private var scanning = false
    @State private var scanned = false
    @State private var skipped = 0
    @State private var accessUnavailable = false
    @State private var applicationInventoryWasLimited = false
    @State private var applicationInventoryWasCancelled = false
    @State private var startupInventoryWasCancelled = false
    @State private var scanTask: Task<(StartupInventoryResult, ApplicationInventoryResult), Never>?
    private var filtered: [StartupItem] {
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || ($0.associatedApp?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.purpose.localizedCaseInsensitiveContains(query)
                || $0.mechanism.localizedCaseInsensitiveContains(query)
                || ($0.program?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Startup & Background").font(.largeTitle.bold())
                    Text("Review launch definitions and helpers bundled with installed apps.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Manage Login Items in Settings") { SMAppService.openSystemSettingsLoginItems() }
                Button(scanning ? "Cancel Scan" : (scanned ? "Refresh" : "Find Startup Items")) {
                    if scanning { scanTask?.cancel() } else { scan() }
                }
                .buttonStyle(.borderedProminent).tint(MacCleanerTheme.accent)
            }
            Text("“Enabled in file” describes a setting, not whether an item is running. macOS reports approval for some legacy items; it does not expose another app’s registration status here. Recent login items are managed in System Settings. A signature check does not determine whether software is safe.")
                .font(.caption).foregroundStyle(.secondary)
            if scanning {
                ProgressView("Reading startup items…"); Spacer()
            } else if !scanned {
                ContentUnavailableView("Review startup items", systemImage: "power", description: Text("Find launch agents, daemons, and helpers inside installed apps without changing them."))
            } else {
                HStack { Text("\(filtered.count) startup items").font(.headline); Spacer(); TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240) }
                if skipped > 0 || accessUnavailable || applicationInventoryWasLimited || applicationInventoryWasCancelled || startupInventoryWasCancelled {
                    Label(
                        "Some startup items or locations could not be checked.\(skipped > 0 ? " \(skipped) skipped." : "")\(accessUnavailable ? " Full Disk Access was unavailable." : "")\(applicationInventoryWasLimited ? " App discovery reached its safety limit, so some bundled helpers may be missing." : "")\(applicationInventoryWasCancelled ? " App discovery stopped early, so some bundled helpers may be missing." : "")\(startupInventoryWasCancelled ? " The startup scan was cancelled before it finished." : "")",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                List(filtered) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.label).fontWeight(.medium)
                            Spacer()
                            Text(item.configuration)
                                .font(.caption)
                                .foregroundStyle(item.configuration == "Disabled in file" ? .secondary : MacCleanerTheme.accent)
                            Text(item.mechanism).font(.caption).foregroundStyle(.secondary)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.locationURL]) }
                        }
                        if let app = item.associatedApp { Text("App referenced: \(app)").font(.caption).foregroundStyle(.secondary) }
                        Text(item.purpose).font(.callout)
                        Text("When it runs: \(item.launchConditions.joined(separator: " · "))").font(.caption).foregroundStyle(.secondary)
                        Text("macOS authorization: \(item.authorization)").font(.caption).foregroundStyle(.secondary)
                        if let signing = item.signing { Text(signing).font(.caption).foregroundStyle(.secondary) }
                        if let path = item.program { Text("Executable: \(path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        Text("Location: \(item.locationURL.path)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(.vertical, 4)
                }
            }
        }
        .padding(28)
        .onDisappear { scanTask?.cancel() }
    }
    private func scan() {
        scanning = true
        applicationInventoryWasLimited = false
        applicationInventoryWasCancelled = false
        startupInventoryWasCancelled = false
        let access = model.borrowDiskAccess()
        accessUnavailable = access == nil
        let locations = StartupInventory.standardLocations()
        let applicationRoots = StartupInventory.standardApplicationRoots()
        let worker = Task.detached(priority: .utility) {
                let applications = ApplicationInventory().scan(
                    roots: applicationRoots,
                    includeSizes: false,
                    isCancelled: { Task.isCancelled }
                )
                let result = StartupInventory().scan(
                    locations: locations,
                    applicationBundles: applications.applications.map(\.url),
                    isCancelled: { Task.isCancelled }
                )
                return (result, applications)
        }
        scanTask = worker
        Task {
            let (result, applications) = await worker.value
            access?.stopAccessingSecurityScopedResource()
            items = result.items
            skipped = result.skipped + applications.inaccessibleLocations
            applicationInventoryWasLimited = applications.wasLimited
            applicationInventoryWasCancelled = applications.wasCancelled
            startupInventoryWasCancelled = result.wasCancelled
            scanned = true
            scanning = false
            scanTask = nil
        }
    }
}
