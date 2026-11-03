import AppKit
import SwiftUI

struct ApplicationUpdaterView: View {
    @ObservedObject var model: ScanViewModel

    @State private var targets: [ApplicationUpdateTarget] = []
    @State private var query = ""
    @State private var loading = false
    @State private var scanned = false
    @State private var inaccessibleLocations = 0
    @State private var inventoryWasLimited = false
    @State private var inventoryWasCancelled = false
    @State private var inventoryTask: Task<ApplicationUpdateDiscoveryResult, Never>?
    @State private var checkingIDs = Set<String>()
    @State private var checkResults = Self.loadHistory()
    @State private var versionHistory = Self.loadVersionHistory()
    @State private var checkErrors: [String: String] = [:]
    @State private var pendingFeed: ApplicationUpdateTarget?
    @State private var showFeedNotice = false
    @State private var feedNoticeAccepted = UserDefaults.standard.bool(forKey: Self.feedNoticeKey)
    @State private var isCheckingHomebrew = false
    @State private var homebrewReport = Self.loadHomebrewReport()
    @State private var homebrewError: String?
    @State private var showsAllHomebrewUpdates = false
    @State private var homebrewCopyMessage: String?

    private static let historyKey = "MacCleaner.applicationUpdater.history.v1"
    private static let versionHistoryKey = "MacCleaner.applicationUpdater.versionHistory.v1"
    private static let feedNoticeKey = "MacCleaner.applicationUpdater.feedNoticeAccepted.v1"
    private static let homebrewHistoryKey = "MacCleaner.applicationUpdater.homebrewHistory.v1"

    private var visibleHomebrewUpdates: [HomebrewCaskUpdate] {
        guard let updates = homebrewReport?.updates else { return [] }
        return showsAllHomebrewUpdates ? updates : Array(updates.prefix(3))
    }

    private var filteredTargets: [ApplicationUpdateTarget] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return targets }
        return targets.filter {
            $0.application.name.localizedCaseInsensitiveContains(query)
                || ($0.application.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.source.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("App Updater").font(.largeTitle.bold())
                    Text("See installed versions and check each app through its supported update source.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(loading ? "Cancel Scan" : (scanned ? "Refresh Apps" : "Find Apps")) {
                    if loading { inventoryTask?.cancel() } else { scan() }
                }
                    .buttonStyle(.borderedProminent)
                    .tint(MacCleanerTheme.accent)
            }

            softwareUpdateCard

            homebrewUpdateCard

            Label(
                "A feed check contacts only the secure update address listed by that app. The publisher receives ordinary connection information. Mac Cleaner does not send file names or contents, and it never downloads or installs an update.",
                systemImage: "lock.shield"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))

            if loading {
                ProgressView("Finding installed apps…")
                Spacer()
            } else if !scanned {
                ContentUnavailableView("Find your apps", systemImage: "arrow.down.app", description: Text("Mac Cleaner reads app versions and update-source details from standard Applications folders."))
                Spacer()
            } else if targets.isEmpty {
                ContentUnavailableView("No apps found", systemImage: "app.dashed", description: Text("No readable apps were found in the standard Applications folders."))
                Spacer()
            } else {
                HStack {
                    Text("\(filteredTargets.count) apps").font(.headline)
                    Spacer()
                    TextField("Search apps", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredTargets) { target in
                            applicationRow(target)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            if scanned && (inaccessibleLocations > 0 || inventoryWasLimited || inventoryWasCancelled) {
                Label(
                    inventoryWasCancelled
                        ? "The scan stopped early. This list may be incomplete."
                        : inventoryWasLimited
                            ? "The scan reached its safety limit. This list may be incomplete."
                            : "Some app locations could not be read. This list may be incomplete.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .task {
            if !scanned && !loading { scan() }
        }
        .onDisappear {
            inventoryTask?.cancel()
        }
        .alert("Check this publisher's update feed?", isPresented: $showFeedNotice) {
            Button("Cancel", role: .cancel) { pendingFeed = nil }
            Button("Check HTTPS Feed") {
                feedNoticeAccepted = true
                UserDefaults.standard.set(true, forKey: Self.feedNoticeKey)
                guard let pendingFeed,
                      case .sparkleFeed(let feedURL) = pendingFeed.source else { return }
                checkFeed(for: pendingFeed, url: feedURL)
                self.pendingFeed = nil
            }
        } message: {
            Text(feedNoticeMessage)
        }
    }

    private var softwareUpdateCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "gear.badge")
                .font(.title2)
                .foregroundStyle(MacCleanerTheme.accent)
                .frame(width: 46, height: 46)
                .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("macOS and Apple system updates").font(.headline)
                Text("Apple checks system updates in Software Update. Mac Cleaner sends you there to review them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Open Software Update", action: openSoftwareUpdate)
        }
        .padding(16)
        .cleanerCard()
    }

    private var homebrewUpdateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.title2)
                    .foregroundStyle(MacCleanerTheme.accent)
                    .frame(width: 46, height: 46)
                    .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Homebrew app updates").font(.headline)
                    Text("Check cask apps managed by Homebrew.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(isCheckingHomebrew ? "Checking…" : "Check Homebrew") {
                    checkHomebrewUpdates()
                }
                .buttonStyle(.borderedProminent)
                .tint(MacCleanerTheme.accent)
                .disabled(isCheckingHomebrew)
            }

            Text("This user-started check may contact Homebrew’s configured update source. Mac Cleaner sends no scan results, does not refresh Homebrew’s catalog, and never installs packages.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isCheckingHomebrew {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Checking Homebrew’s available catalog…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if let homebrewError {
                Label(homebrewError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if let homebrewReport {
                Text("Last checked \(homebrewReport.checkedAt.formatted(date: .abbreviated, time: .shortened)). Results use Homebrew’s current metadata, which may be out of date.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if homebrewReport.updates.isEmpty {
                    Label("Homebrew reports no outdated cask apps.", systemImage: "checkmark.circle")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                } else {
                    Label("\(homebrewReport.updates.count) cask app update\(homebrewReport.updates.count == 1 ? "" : "s") reported", systemImage: "arrow.up.circle")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(MacCleanerTheme.accent)

                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(visibleHomebrewUpdates) { update in
                            homebrewUpdateRow(update)
                        }
                    }

                    if homebrewReport.updates.count > 3 {
                        Button(showsAllHomebrewUpdates ? "Show fewer" : "Show all \(homebrewReport.updates.count) updates") {
                            showsAllHomebrewUpdates.toggle()
                        }
                        .buttonStyle(.link)
                    }
                }
            } else if !isCheckingHomebrew && homebrewError == nil {
                Label("Homebrew has not been checked yet.", systemImage: "questionmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let homebrewCopyMessage {
                Text(homebrewCopyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .cleanerCard()
    }

    private func homebrewUpdateRow(_ update: HomebrewCaskUpdate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(update.name).font(.callout.weight(.medium))
                Text("Installed \(update.installedVersions.joined(separator: ", ")) → Homebrew lists \(update.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Cask: \(update.token)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button("Copy update command") { copyHomebrewCommand(for: update) }
                .buttonStyle(.bordered)
                .accessibilityHint("Copies a command to the clipboard. Mac Cleaner will not run it.")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func applicationRow(_ target: ApplicationUpdateTarget) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: target.application.url.path))
                .resizable()
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(target.application.name).fontWeight(.semibold)
                    Spacer()
                    Text(target.source.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MacCleanerTheme.accent)
                }
                Text(versionDescription(for: target))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(sourceDescription(for: target))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let bundleIdentifier = target.application.bundleIdentifier {
                    Text(bundleIdentifier)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let result = target.application.bundleIdentifier.flatMap({ checkResults[$0] }) {
                    feedResultDescription(result)
                    if let change = ApplicationUpdateVersionTracker.change(
                        from: result.installedBuildVersion,
                        to: target.buildVersion
                    ) {
                        Label(
                            "Mac Cleaner now sees build \(change.currentBuildVersion); it saw build \(change.previousBuildVersion) at the last feed check.",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.caption)
                        .foregroundStyle(MacCleanerTheme.accent)
                    }
                }
                if let change = versionHistory[target.id]?.latestChange {
                    Label(change.summary, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(MacCleanerTheme.accent)
                    Text("Observed \(change.observedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let error = checkErrors[target.id] {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            sourceActions(for: target)
        }
        .padding(14)
        .cleanerCard()
    }

    @ViewBuilder
    private func sourceActions(for target: ApplicationUpdateTarget) -> some View {
        switch target.source {
        case .sparkleFeed(let feedURL):
            VStack(alignment: .trailing, spacing: 7) {
                Button(checkingIDs.contains(target.id) ? "Checking…" : "Check Feed") {
                    requestFeedCheck(for: target, url: feedURL)
                }
                .buttonStyle(.borderedProminent)
                .tint(MacCleanerTheme.accent)
                .disabled(checkingIDs.contains(target.id))
                Button("Open App Updater") { openApp(target) }
                    .buttonStyle(.link)
                    .disabled(checkingIDs.contains(target.id))
            }
        case .appStore:
            Button("Open App Store") { openAppStore() }
        case .appleSoftwareUpdate:
            Text("Use Software Update above")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 140, alignment: .trailing)
        case .builtInUpdater, .unsupportedFeed:
            Button("Open App") { openApp(target) }
        }
    }

    @ViewBuilder
    private func feedResultDescription(_ result: ApplicationUpdateFeedResult) -> some View {
        switch result.outcome {
        case .updateAdvertised:
            Label(
                "Feed advertises version \(result.advertisedDisplayVersion ?? result.advertisedBuildVersion ?? "newer"). Open the app's updater to apply it.",
                systemImage: "arrow.up.circle"
            )
            .foregroundStyle(MacCleanerTheme.accent)
        case .noNewerVersion:
            Label("No newer version was listed by this feed.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .versionCouldNotBeCompared:
            Label(
                "Feed listed \(result.advertisedDisplayVersion ?? result.advertisedBuildVersion ?? "a version"), but Mac Cleaner could not compare it safely.",
                systemImage: "questionmark.circle"
            )
            .foregroundStyle(.orange)
        }
        Text("Checked \(result.checkedAt.formatted(date: .abbreviated, time: .shortened)) · HTTPS metadata only; installer not checked")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private var feedNoticeMessage: String {
        guard let pendingFeed, case .sparkleFeed(let url) = pendingFeed.source else {
            return "Mac Cleaner will contact only the HTTPS address listed by this app."
        }
        return "Mac Cleaner will request the HTTPS update address listed by \(pendingFeed.application.name) (\(url.host ?? "publisher")). That server receives ordinary connection information. No file names or file contents are sent, and no installer is downloaded."
    }

    private func versionDescription(for target: ApplicationUpdateTarget) -> String {
        let shortVersion = target.application.version.map { "Version \($0)" }
        let buildVersion = target.buildVersion.map { "build \($0)" }
        return [shortVersion, buildVersion].compactMap { $0 }.joined(separator: " · ").ifEmpty("Version not provided")
    }

    private func sourceDescription(for target: ApplicationUpdateTarget) -> String {
        switch target.source {
        case .sparkleFeed:
            "Mac Cleaner checks this publisher feed only when you press Check Feed."
        case .appStore:
            "App Store receipt found. Open the App Store and review Updates."
        case .appleSoftwareUpdate:
            "Apple system updates are checked together in Software Update."
        case .builtInUpdater:
            "No supported update feed was found. Check the app's menu or help for its updater."
        case .unsupportedFeed:
            "This app lists a feed Mac Cleaner will not contact. Use the app's own updater."
        }
    }

    private func scan() {
        guard !loading else { return }
        loading = true
        scanned = false
        inventoryWasLimited = false
        inventoryWasCancelled = false
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            SafeFilePolicy.accountHome.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        ]
        let worker = Task.detached(priority: .utility) {
            ApplicationUpdaterService().discover(roots: roots, isCancelled: { Task.isCancelled })
        }
        inventoryTask = worker
        Task {
            let discovery = await worker.value
            targets = discovery.targets
            let currentVersions = Dictionary(uniqueKeysWithValues: discovery.targets.map { target in
                (target.id, InstalledAppVersionSnapshot(
                    name: target.application.name,
                    version: target.application.version,
                    buildVersion: target.buildVersion
                ))
            })
            versionHistory = ApplicationVersionObservationTracker.record(
                current: currentVersions,
                previous: versionHistory,
                observedAt: .now
            )
            saveVersionHistory()
            inaccessibleLocations = discovery.inaccessibleLocations
            inventoryWasLimited = discovery.wasLimited
            inventoryWasCancelled = discovery.wasCancelled
            loading = false
            scanned = true
            inventoryTask = nil
        }
    }

    private func requestFeedCheck(for target: ApplicationUpdateTarget, url: URL) {
        checkErrors[target.id] = nil
        guard feedNoticeAccepted else {
            pendingFeed = target
            showFeedNotice = true
            return
        }
        checkFeed(for: target, url: url)
    }

    private func checkFeed(for target: ApplicationUpdateTarget, url: URL) {
        guard !checkingIDs.contains(target.id) else { return }
        checkingIDs.insert(target.id)
        Task {
            do {
                let result = try await ApplicationUpdaterService().check(
                    feedURL: url,
                    installedBuildVersion: target.buildVersion
                )
                if let identifier = target.application.bundleIdentifier {
                    checkResults[identifier] = result
                    saveHistory()
                }
                let note = result.outcome == .updateAdvertised
                    ? "An HTTPS app update feed advertised a newer version. The installer was not downloaded."
                    : "An HTTPS app update feed was checked. The installer was not downloaded."
                model.activity.record(title: "App update source checked", files: 1, bytes: 0, note: note, kind: .updateCheck)
            } catch {
                checkErrors[target.id] = error.localizedDescription
            }
            checkingIDs.remove(target.id)
            await ActivityNotificationService.shared.notifyIfEnabled(.appUpdateSourceCheckCompleted)
        }
    }

    private func checkHomebrewUpdates() {
        guard !isCheckingHomebrew else { return }
        isCheckingHomebrew = true
        homebrewError = nil
        Task {
            do {
                let report = try await Task.detached(priority: .utility) {
                    try HomebrewCaskUpdateService().check()
                }.value
                homebrewReport = report
                saveHomebrewReport()
                model.activity.record(
                    title: "Homebrew update source checked",
                    files: 1,
                    bytes: 0,
                    note: "A user-started Homebrew cask update check completed. Mac Cleaner did not install software.",
                    kind: .updateCheck
                )
            } catch {
                homebrewError = error.localizedDescription
            }
            isCheckingHomebrew = false
            await ActivityNotificationService.shared.notifyIfEnabled(.appUpdateSourceCheckCompleted)
        }
    }

    private func copyHomebrewCommand(for update: HomebrewCaskUpdate) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(update.updateCommand, forType: .string) {
            homebrewCopyMessage = "Copied the update command. Mac Cleaner will not run it."
        } else {
            homebrewCopyMessage = "The command could not be copied."
        }
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(checkResults) else { return }
        UserDefaults.standard.set(data, forKey: Self.historyKey)
    }

    private func saveVersionHistory() {
        guard let data = try? JSONEncoder().encode(versionHistory) else { return }
        UserDefaults.standard.set(data, forKey: Self.versionHistoryKey)
    }

    private func saveHomebrewReport() {
        guard let data = try? JSONEncoder().encode(homebrewReport) else { return }
        UserDefaults.standard.set(data, forKey: Self.homebrewHistoryKey)
    }

    private static func loadHistory() -> [String: ApplicationUpdateFeedResult] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let history = try? JSONDecoder().decode([String: ApplicationUpdateFeedResult].self, from: data) else { return [:] }
        return history
    }

    private static func loadVersionHistory() -> [String: InstalledAppVersionHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: versionHistoryKey),
              let history = try? JSONDecoder().decode([String: InstalledAppVersionHistoryEntry].self, from: data) else { return [:] }
        return history
    }

    private static func loadHomebrewReport() -> HomebrewCaskUpdateReport? {
        guard let data = UserDefaults.standard.data(forKey: homebrewHistoryKey) else { return nil }
        return try? JSONDecoder().decode(HomebrewCaskUpdateReport.self, from: data)
    }

    private func openApp(_ target: ApplicationUpdateTarget) {
        NSWorkspace.shared.open(target.application.url)
    }

    private func openAppStore() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.AppStore") else { return }
        NSWorkspace.shared.open(appURL)
    }

    private func openSoftwareUpdate() {
        guard let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") else { return }
        NSWorkspace.shared.open(settingsURL)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
