import AppKit
import SwiftUI

struct ApplicationSecurityView: View {
    @ObservedObject var model: ScanViewModel
    @State private var findings: [ApplicationSignatureFinding] = []
    @State private var startupFindings: [StartupSecurityReviewFinding] = []
    @State private var query = ""
    @State private var onlyReview = false
    @State private var loading = false
    @State private var scanned = false
    @State private var inaccessibleLocations = 0
    @State private var skippedStartupItems = 0
    @State private var inventoryWasLimited = false
    @State private var diskAccessUnavailable = false
    @State private var checkedAt: Date?
    @State private var auditWasCancelled = false
    @State private var scanTask: Task<ApplicationSecurityAuditReport, Never>?
    @State private var trustChecks: [String: ApplicationTrustCheck] = [:]
    @State private var trustCheckTasks: [String: Task<ApplicationTrustCheck, Never>] = [:]
    @StateObject private var scanProgress = ApplicationSecurityAuditProgressState()

    private var filteredFindings: [ApplicationSignatureFinding] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return findings.filter { finding in
            let matchesFilter = !onlyReview || finding.status.requiresReview
            let matchesQuery = normalizedQuery.isEmpty
                || finding.application.name.localizedCaseInsensitiveContains(normalizedQuery)
                || (finding.application.bundleIdentifier?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                || (finding.teamIdentifier?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
            return matchesFilter && matchesQuery
        }
    }

    private var matchingCount: Int {
        findings.filter { $0.status == .signatureMatches || $0.status == .signatureMatchesWithoutTeamID }.count
    }

    private var missingCount: Int {
        findings.filter { $0.status == .noSignature }.count
    }

    private var couldNotVerifyCount: Int {
        findings.filter { $0.status == .couldNotValidate || $0.status == .couldNotInspect }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("App Security").font(.largeTitle.bold())
                    Text("Verify app signatures, sealed files, and embedded code.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if loading {
                    Button("Cancel Check") { scanTask?.cancel() }
                        .buttonStyle(.bordered)
                } else {
                    Button(scanned ? "Check Again" : "Verify App Bundles", action: scan)
                        .buttonStyle(.borderedProminent)
                        .tint(MacCleanerTheme.accent)
                }
            }

            HStack(spacing: 12) {
                summaryCard(title: "Bundles verified", count: matchingCount, symbol: "checkmark.shield")
                summaryCard(title: "No signature", count: missingCount, symbol: "questionmark.shield")
                summaryCard(title: "Could not verify", count: couldNotVerifyCount, symbol: "exclamationmark.shield")
            }

            Label(
                "macOS checks each app's signature, sealed resources, and embedded code. This does not confirm developer reputation, notarization, or whether an app is malware. A missing or invalid signature alone is not proof that an app is harmful.",
                systemImage: "info.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))

            Label(
                "The optional code and certificate trust check may contact Apple to check revocation and notarization. It is not a malware scan.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if loading {
                if let progress = scanProgress.progress {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    Text(progress.phase == .applications
                         ? "Verifying \(progress.applicationName) · \(progress.completed) of \(progress.total) apps"
                         : "Checking \(progress.applicationName) · location \(progress.completed) of \(progress.total)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Cancel takes effect after the current check finishes.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView("Finding installed apps…")
                }
                Spacer()
            } else if !scanned {
                ContentUnavailableView(
                    "Review apps and startup items",
                    systemImage: "checkmark.shield",
                    description: Text("Mac Cleaner checks app signatures, readable startup definitions, and helpers bundled inside installed apps. It does not change files.")
                )
                Spacer()
            } else {
                if auditWasCancelled {
                    Label("This check was stopped. Results include only apps and startup items checked before you cancelled.", systemImage: "stop.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if inventoryWasLimited {
                    Label("The app scan reached its safety limit. Results may not include every installed app.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Toggle("Show apps that need a closer look", isOn: $onlyReview)
                        .toggleStyle(.switch)
                    Spacer()
                    TextField("Search apps", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }

                if inaccessibleLocations > 0 || skippedStartupItems > 0 || diskAccessUnavailable || inventoryWasLimited {
                    Label("Some app or startup locations could not be checked. The results may be incomplete.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        startupReviewSection
                        if filteredFindings.isEmpty {
                            let emptyTitle = auditWasCancelled && findings.isEmpty
                                ? "Check stopped before any apps were verified"
                                : findings.isEmpty
                                    ? "No app bundles found"
                                    : onlyReview
                                        ? "No apps need a closer look"
                                        : "No apps match this search"
                            let emptyDescription = auditWasCancelled && findings.isEmpty
                                ? "Run Verify App Bundles again to check the installed apps."
                                : findings.isEmpty
                                    ? "No apps were found in the standard Applications folders."
                                    : onlyReview
                                        ? "No signature issues were found in this result. Turn off the filter to see all apps."
                                        : "Try a different app name, bundle ID, or Team ID."
                            ContentUnavailableView(
                                emptyTitle,
                                systemImage: "checkmark.shield",
                                description: Text(emptyDescription)
                            )
                        } else {
                            ForEach(filteredFindings) { finding in
                                findingRow(finding)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }

                if let checkedAt {
                    Text("Checked \(checkedAt.formatted(date: .abbreviated, time: .shortened)) · \(findings.count) apps")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(28)
        .task {
            guard !scanned && !loading else { return }
            if let report = model.appSecurityReport,
               let checkedAt = model.appSecurityCheckedAt {
                display(report, checkedAt: checkedAt)
            } else {
                scan()
            }
        }
        .onDisappear {
            scanTask?.cancel()
            trustCheckTasks.values.forEach { $0.cancel() }
        }
    }

    private func summaryCard(title: String, count: Int, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(MacCleanerTheme.accent)
            Text("\(count)")
                .font(.title.bold().monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(14)
        .cleanerCard()
    }

    @ViewBuilder
    private var startupReviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Startup items to review")
                    .font(.headline)
                Spacer()
                Text("\(startupFindings.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("This read-only check reviews user and shared launch definitions, plus launch helpers inside installed apps. macOS approval details are available for some older definitions; registration status for another app’s bundled helpers is not available here. Signature findings are context, not malware verdicts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if startupFindings.isEmpty {
                Label(
                    "No checked startup items need this follow-up review.",
                    systemImage: "checkmark.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                ForEach(startupFindings) { finding in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "power")
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(finding.item.label).fontWeight(.semibold)
                                Spacer()
                                Text(finding.item.mechanism)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(finding.reasons, id: \.self) { reason in
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let path = finding.item.program {
                                Text(path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([finding.item.locationURL])
                        }
                    }
                    .padding(12)
                    .cleanerCard()
                }
            }
            if skippedStartupItems > 0 {
                Text("\(skippedStartupItems) startup item\(skippedStartupItems == 1 ? "" : "s") could not be read or parsed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .cleanerCard()
    }

    private func findingRow(_ finding: ApplicationSignatureFinding) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: finding.application.url.path))
                .resizable()
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(finding.application.name).fontWeight(.semibold)
                    Spacer()
                    Text(finding.status.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(finding.status.requiresReview ? .orange : MacCleanerTheme.accent)
                }
                Text(finding.status.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let teamIdentifier = finding.teamIdentifier, !teamIdentifier.isEmpty {
                    Text("Team ID: \(teamIdentifier)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                if let bundleIdentifier = finding.application.bundleIdentifier {
                    Text(bundleIdentifier)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Button {
                        checkCodeTrust(for: finding.application)
                    } label: {
                        Label(
                            trustCheckTasks[finding.id] == nil ? "Check code trust" : "Checking…",
                            systemImage: "checkmark.shield"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(loading || trustCheckTasks[finding.id] != nil)

                    if let check = trustChecks[finding.id] {
                        Label(check.status.title, systemImage: check.status.symbol)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(check.status == .validated ? MacCleanerTheme.accent : Color.secondary)
                    }
                }
                if let check = trustChecks[finding.id] {
                    Text(check.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if check.hasStapledNotarizationTicket == true {
                        Label("A notarization ticket is attached to this app.", systemImage: "checkmark.seal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([finding.application.url])
            }
        }
        .padding(14)
        .cleanerCard()
    }

    private func scan() {
        guard !loading else { return }
        loading = true
        scanned = false
        findings.removeAll()
        startupFindings.removeAll()
        trustCheckTasks.values.forEach { $0.cancel() }
        trustCheckTasks.removeAll()
        trustChecks.removeAll()
        inaccessibleLocations = 0
        skippedStartupItems = 0
        inventoryWasLimited = false
        diskAccessUnavailable = false
        checkedAt = nil
        auditWasCancelled = false
        scanProgress.progress = nil
        let roots = ApplicationSecurityAuditService.standardApplicationRoots
        let access = model.borrowDiskAccess()
        diskAccessUnavailable = access == nil
        let startupLocations = ApplicationSecurityAuditService.standardStartupLocations()
        let progressState = scanProgress
        let task = Task.detached(priority: .utility) {
            defer { access?.stopAccessingSecurityScopedResource() }
            return ApplicationSecurityAuditService().scan(
                roots: roots,
                startupLocations: startupLocations,
                isCancelled: { Task.isCancelled }
            ) { progress in
                Task { @MainActor in progressState.progress = progress }
            }
        }
        scanTask = task
        Task { @MainActor in
            let report = await task.value
            let completedAt = Date.now
            model.cacheAppSecurityReport(report, checkedAt: completedAt)
            display(report, checkedAt: completedAt)
            scanTask = nil
            let summary = ApplicationSecurityActivitySummary(report: report)
            model.activity.record(
                title: summary.title,
                files: summary.checkedApps,
                bytes: 0,
                note: summary.note,
                kind: .securityCheck
            )
            if !report.wasCancelled {
                await ActivityNotificationService.shared.notifyIfEnabled(.appSecurityCheckCompleted)
            }
        }
    }

    private func display(_ report: ApplicationSecurityAuditReport, checkedAt date: Date) {
        findings = report.findings
        startupFindings = report.startupFindings
        skippedStartupItems = report.skippedStartupItems
        inaccessibleLocations = report.inaccessibleLocations
        inventoryWasLimited = report.wasLimited
        diskAccessUnavailable = !model.standardFoldersAccessible
        auditWasCancelled = report.wasCancelled
        checkedAt = date
        loading = false
        scanned = true
        scanProgress.progress = nil
    }

    private func checkCodeTrust(for application: InstalledApplication) {
        let id = application.id
        guard trustCheckTasks[id] == nil else { return }
        let appURL = application.url
        let task = Task.detached(priority: .utility) {
            ApplicationTrustCheckService().check(appURL: appURL, isCancelled: { Task.isCancelled })
        }
        trustCheckTasks[id] = task
        Task { @MainActor in
            let check = await task.value
            trustChecks[id] = check
            trustCheckTasks[id] = nil
        }
    }
}

@MainActor
private final class ApplicationSecurityAuditProgressState: ObservableObject {
    @Published var progress: ApplicationSecurityAuditProgress?
}
