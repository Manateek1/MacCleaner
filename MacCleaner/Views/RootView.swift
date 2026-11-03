import AppKit
import Charts
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

enum AppSection: String, CaseIterable, Hashable, Identifiable {
    case overview
    case smartScan
    case largeFiles
    case downloads
    case duplicates
    case similarPhotos
    case junk
    case aiClutter
    case localModels
    case privacyCleanup
    case spaceLens
    case performance
    case maintenance
    case applications
    case appUpdates
    case appSecurity
    case appLeftovers
    case startup
    case deviceBackups
    case xcodeStorage
    case diagnosticReports
    case screenCleaning
    case trash
    case tools
    case permissions
    case activity
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .smartScan: "Smart Scan"
        case .largeFiles: "Large & Old Files"
        case .downloads: "Downloads"
        case .duplicates: "Exact Duplicates"
        case .similarPhotos: "Similar Photos"
        case .junk: "System Junk"
        case .aiClutter: "AI Clutter"
        case .localModels: "Local AI Models"
        case .privacyCleanup: "Privacy Cleanup"
        case .spaceLens: "Space Lens"
        case .performance: "Performance"
        case .maintenance: "Mac Health"
        case .applications: "Applications"
        case .appUpdates: "App Updater"
        case .appSecurity: "App Security"
        case .appLeftovers: "App Leftovers"
        case .startup: "Startup & Background"
        case .deviceBackups: "Device Backups"
        case .xcodeStorage: "Xcode Storage"
        case .diagnosticReports: "Diagnostic Reports"
        case .screenCleaning: "Screen Cleaning Mode"
        case .trash: "Trash"
        case .tools: "My Tools"
        case .permissions: "Privacy & Permissions"
        case .activity: "Activity"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "rectangle.grid.2x2.fill"
        case .smartScan: "sparkles"
        case .largeFiles: "externaldrive.fill"
        case .downloads: "arrow.down.circle"
        case .duplicates: "doc.on.doc"
        case .similarPhotos: "photo.on.rectangle.angled"
        case .junk: "tray.full"
        case .aiClutter: "cpu"
        case .localModels: "shippingbox"
        case .privacyCleanup: "hand.raised.slash"
        case .spaceLens: "square.grid.3x3.fill"
        case .performance: "gauge.with.dots.needle.67percent"
        case .maintenance: "heart.text.square"
        case .applications: "square.stack.3d.up"
        case .appUpdates: "arrow.down.app"
        case .appSecurity: "checkmark.shield"
        case .appLeftovers: "folder.badge.questionmark"
        case .startup: "power"
        case .deviceBackups: "iphone.and.arrow.left.and.arrow.right"
        case .xcodeStorage: "hammer"
        case .diagnosticReports: "doc.text.magnifyingglass"
        case .screenCleaning: "sparkles"
        case .trash: "trash"
        case .tools: "wrench.and.screwdriver"
        case .permissions: "hand.raised"
        case .activity: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }

    var navigationShortcutKey: Character? {
        switch self {
        case .overview: "1"
        case .smartScan: "2"
        case .largeFiles: "3"
        case .duplicates: "4"
        case .similarPhotos: "5"
        case .junk: "6"
        case .tools: "7"
        case .permissions: "8"
        case .activity: "9"
        default: nil
        }
    }

    static var navigationShortcutSections: [AppSection] {
        allCases.filter { $0.navigationShortcutKey != nil }
    }

    var scanKind: ScanKind? {
        switch self {
        case .smartScan: .smart
        case .largeFiles: .largeAndOld
        case .duplicates: .duplicates
        case .junk: .junk
        case .aiClutter: .aiClutter
        case .overview, .downloads, .trash, .localModels, .privacyCleanup, .similarPhotos, .spaceLens, .performance, .maintenance, .applications, .appUpdates, .appSecurity, .appLeftovers, .startup, .deviceBackups, .xcodeStorage, .diagnosticReports, .screenCleaning, .tools, .permissions, .activity, .settings: nil
        }
    }
}

struct RootView: View {
    @ObservedObject var model: ScanViewModel
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var navigation: AppNavigationModel
    @State private var showSetup = false

    var body: some View {
        NavigationSplitView {
            List {
                Section("GET STARTED") {
                    sidebarRow(.overview)
                    sidebarRow(.smartScan)
                }
                Section("REVIEW FILES") {
                    sidebarRow(.largeFiles)
                    sidebarRow(.duplicates)
                    sidebarRow(.similarPhotos)
                    sidebarRow(.junk)
                    sidebarRow(.aiClutter)
                    sidebarRow(.localModels)
                    sidebarRow(.privacyCleanup)
                    sidebarRow(.spaceLens)
                    sidebarRow(.deviceBackups)
                }
                Section("SYSTEM") {
                    sidebarRow(.performance)
                    sidebarRow(.maintenance)
                    sidebarRow(.applications)
                    sidebarRow(.appUpdates)
                    sidebarRow(.appSecurity)
                    sidebarRow(.appLeftovers)
                    sidebarRow(.startup)
                }
                Section("MORE") {
                    sidebarRow(.tools)
                    sidebarRow(.permissions)
                    sidebarRow(.activity)
                    sidebarRow(.settings)
                }
            }
            .listStyle(.sidebar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sidebar-navigation")
            .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 300)
        } detail: {
            Group {
                switch navigation.selectedSection ?? .overview {
                case .overview:
                    DashboardView(model: model, section: $navigation.selectedSection)
                case .smartScan:
                    ScanWorkspaceView(
                        model: model,
                        kind: .smart,
                        onOpenAppSecurity: { navigation.selectedSection = .appSecurity }
                    )
                case .largeFiles:
                    ScanWorkspaceView(model: model, kind: .largeAndOld)
                case .downloads:
                    ScanWorkspaceView(
                        model: model,
                        kind: .smart,
                        titleOverride: "Downloads",
                        subtitleOverride: "Scan the accessible parts of your Mac, then review findings from Downloads only.",
                        initialLocation: .downloads
                    )
                case .duplicates:
                    ScanWorkspaceView(model: model, kind: .duplicates)
                case .similarPhotos:
                    SimilarPhotosView(model: model)
                case .junk:
                    ScanWorkspaceView(model: model, kind: .junk)
                case .aiClutter:
                    ScanWorkspaceView(model: model, kind: .aiClutter)
                case .localModels:
                    LocalAIModelsView(model: model, onOpenOverview: { navigation.selectedSection = .overview })
                case .privacyCleanup:
                    BrowserPrivacyCleanupView(model: model, onOpenOverview: { navigation.selectedSection = .overview })
                case .spaceLens:
                    SpaceLensView(model: model, section: $navigation.selectedSection)
                case .performance:
                    PerformanceView(monitor: monitor)
                case .maintenance:
                    MacHealthMaintenanceView(monitor: monitor, onNavigate: { navigation.selectedSection = $0 })
                case .applications:
                    ApplicationsView(model: model)
                case .appUpdates:
                    ApplicationUpdaterView(model: model)
                case .appSecurity:
                    ApplicationSecurityView(model: model)
                case .appLeftovers:
                    ApplicationLeftoversView(model: model)
                case .startup:
                    StartupView(model: model)
                case .deviceBackups:
                    DeviceBackupsView(model: model, onOpenOverview: { navigation.selectedSection = .overview })
                case .xcodeStorage:
                    XcodeArchiveInventoryView(model: model, onOpenOverview: { navigation.selectedSection = .overview })
                case .diagnosticReports:
                    DiagnosticReportsView(model: model, onOpenOverview: { navigation.selectedSection = .overview })
                case .screenCleaning:
                    ScreenCleaningModeView()
                case .trash:
                    TrashReviewView()
                case .tools:
                    MyToolsView(onOpenTool: { navigation.selectedSection = $0 })
                case .permissions:
                    PermissionsView(
                        model: model,
                        onOpenSmartScan: { navigation.selectedSection = .smartScan },
                        onOpenSimilarPhotos: { navigation.selectedSection = .similarPhotos },
                        onOpenAppUpdater: { navigation.selectedSection = .appUpdates }
                    )
                case .activity:
                    ActivityView(store: model.activity)
                case .settings:
                    SettingsView(
                        model: model,
                        onScanStarted: { navigation.selectedSection = .smartScan },
                        onShowPermissions: { navigation.selectedSection = .permissions }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MacCleanerTheme.canvas)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("section-content-\((navigation.selectedSection ?? .overview).rawValue)")
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .foregroundStyle(MacCleanerTheme.accent)
                    Text("Mac Cleaner")
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            if !model.scanNoticeAccepted { showSetup = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.scanNoticeAccepted,
               navigation.selectedSection == .permissions,
               !model.isScanning {
                model.refreshDiskAccessStatusInBackground()
            }
        }
        .onChange(of: model.scanSetupRequested) { _, requested in
            if requested {
                showSetup = true
                model.clearScanSetupRequest()
            }
        }
        .sheet(isPresented: $showSetup) {
            SetupGuideView(model: model, onScanStarted: {
                showSetup = false
                navigation.selectedSection = .smartScan
            }, onDismiss: {
                showSetup = false
            })
        }
    }

    private func sidebarRow(_ item: AppSection) -> some View {
        Button {
            navigation.selectedSection = item
        } label: {
            Label(item.title, systemImage: item.symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .foregroundStyle(navigation.selectedSection == Optional(item) ? MacCleanerTheme.accent : MacCleanerTheme.secondaryText)
                .background(
                    navigation.selectedSection == Optional(item) ? MacCleanerTheme.accentSoft : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("sidebar-section-\(item.rawValue)")
    }
}

struct SetupGuideView: View {
    @ObservedObject var model: ScanViewModel
    let onScanStarted: () -> Void
    let onDismiss: () -> Void
    @State private var acknowledged = false
    @State private var includePhotosAccess = false

    init(model: ScanViewModel, onScanStarted: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.model = model
        self.onScanStarted = onScanStarted
        self.onDismiss = onDismiss
        _acknowledged = State(initialValue: model.scanNoticeAccepted)
        _includePhotosAccess = State(initialValue: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.title).foregroundStyle(MacCleanerTheme.accent)
                    .frame(width: 54, height: 54)
                    .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 4) {
                Text("One guided setup").font(.title2.weight(.semibold))
                    Text("Agree once, enable access in macOS once, then scan without choosing folders.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            }

            VStack(alignment: .leading, spacing: 14) {
                Label("Full Disk Access lets Mac Cleaner check local folders across your Mac for large files, exact duplicates, and recognized temporary files. The scan is read-only.", systemImage: "doc.text.magnifyingglass")
                Label("This version is not confined to its own app folder so it can use Full Disk Access. It can read protected local files while that permission is on; the scan itself does not change them.", systemImage: "lock.shield")
                Label("Nothing moves until you select files and confirm. Cleanup moves selected items to Trash.", systemImage: "checkmark.shield")
                Label("macOS controls access. Your account Library is checked for file sizes and known caches; app data stays read-only. Other local accounts are checked read-only outside their Library. Local iCloud Desktop files can appear as read-only results; cloud-only files are not downloaded. Other iCloud Drive areas, network drives, protected system areas, and other accounts' Library data are skipped. Connected local external drives are included when accessible.", systemImage: "lock.shield")
                Label("If Desktop is stored in iCloud, macOS may ask you to choose Desktop once so Mac Cleaner can read local copies. This access is saved when macOS allows it and can be forgotten in Settings.", systemImage: "icloud")
                Label("The latest full-disk review is saved on this Mac so it can be reopened after a restart. It includes file names and paths, stays local, and can be cleared in Settings.", systemImage: "externaldrive.badge.timemachine")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 14))

            Toggle(isOn: $includePhotosAccess) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up Photos Library access now")
                        .font(.callout.weight(.medium))
                    Text("Optional. Similar Photos reads local previews. Chosen photos are removed only after another confirmation and may sync if iCloud Photos is on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(model.isPreparingFirstScan)

            Toggle("I understand and agree to let Mac Cleaner read accessible local disk locations to find cleanup candidates.", isOn: $acknowledged)
                .toggleStyle(.checkbox)
                .font(.callout)
                .disabled(model.isPreparingFirstScan)

            Text(model.standardFoldersChecked
                ? (model.standardFoldersAccessible
                    ? "Documents and Downloads are accessible. Mac Cleaner will scan the whole Mac directly; any other protected locations will be reported. Photos access stays off unless you turn on the optional setting above."
                    : "Turn on Mac Cleaner under Full Disk Access in System Settings, then return here. Mac Cleaner will reuse that choice on future scans. Photos access stays off unless you turn on the optional setting above.")
                : "After you accept this notice, Mac Cleaner checks whether Full Disk Access is already on. It won't read your files before you continue.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open Full Disk Access Settings") {
                model.openFullDiskAccessSettings()
            }
            .buttonStyle(.link)

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Button("Not Now", action: onDismiss)
                    .disabled(model.isPreparingFirstScan)
                Spacer()
                Button(model.isPreparingFirstScan ? "Preparing Access…" : "Set Up and Scan") {
                    model.acceptScanNoticeAndStart(
                        includePhotosAccess: includePhotosAccess,
                        onScanStarted: onScanStarted
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(MacCleanerTheme.accent)
                .disabled(!acknowledged || model.isPreparingFirstScan || model.isScanning || model.isCleaning)
            }
        }
        .padding(26)
        .frame(width: 580)
    }
}

private struct DashboardView: View {
    @ObservedObject var model: ScanViewModel
    @Binding var section: AppSection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Make space, safely.")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(MacCleanerTheme.primaryText)
                    Text("Find files to review across your Mac. Nothing moves until you choose and confirm.")
                        .font(.title3)
                        .foregroundStyle(MacCleanerTheme.secondaryText)
                }

                HStack(alignment: .top, spacing: 16) {
                    smartScanCard
                        .frame(maxWidth: .infinity)
                    storageCard
                        .frame(width: 320)
                }

                VStack(alignment: .leading, spacing: 13) {
                    Text("Common tasks")
                        .font(.headline)
                        .foregroundStyle(MacCleanerTheme.primaryText)
                    HStack(spacing: 12) {
                        DashboardShortcut(
                            title: "Large & old files",
                            detail: "Review what is taking up room",
                            symbol: "externaldrive",
                            action: { section = .largeFiles }
                        )
                        DashboardShortcut(
                            title: "Exact duplicates",
                            detail: "Keep one copy of each match",
                            symbol: "doc.on.doc",
                            action: { section = .duplicates }
                        )
                        DashboardShortcut(
                            title: "System junk",
                            detail: "Review caches, logs, and reports",
                            symbol: "tray.full",
                            action: { section = .junk }
                        )
                    }
                }

                HStack(spacing: 13) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.title3)
                        .foregroundStyle(MacCleanerTheme.accent)
                        .frame(width: 42, height: 42)
                        .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("You stay in control")
                            .font(.subheadline.weight(.semibold))
                        Text("Scans are read-only. Selected files go to Trash only after you confirm.")
                            .font(.callout)
                            .foregroundStyle(MacCleanerTheme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                .padding(15)
                .cleanerCard(cornerRadius: 16)

                recentActivity
            }
            .padding(28)
            .frame(maxWidth: 1060, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var smartScanCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("SMART SCAN", systemImage: "sparkles")
                .font(.caption.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(MacCleanerTheme.accent)

            Text("A quick, safe check")
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .foregroundStyle(MacCleanerTheme.primaryText)

            Text("Look for duplicates, large and old files, and recognized caches in one review.")
                .font(.callout)
                .foregroundStyle(MacCleanerTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button {
                section = .smartScan
                model.scanDisk(for: .smart)
            } label: {
                Label("Scan this Mac", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(MacCleanerTheme.accent)
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 218, alignment: .leading)
        .background(
            LinearGradient(
                colors: [MacCleanerTheme.accentSoft, MacCleanerTheme.accentWash],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(MacCleanerTheme.accent.opacity(0.10), lineWidth: 1)
        }
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("STORAGE", systemImage: "internaldrive")
                    .font(.caption.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(MacCleanerTheme.secondaryText)
                Spacer()
                Button {
                    model.refreshStorage()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(MacCleanerTheme.secondaryText)
                .help("Refresh storage information")
                .accessibilityLabel("Refresh storage information")
            }
            if model.storage.totalBytes > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.storage.availableBytes.formattedByteCount)
                        .font(.system(size: 27, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(MacCleanerTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("available")
                        .font(.callout)
                        .foregroundStyle(MacCleanerTheme.secondaryText)
                }

                ProgressView(value: min(1, max(0, model.storage.usedFraction)))
                    .tint(model.storage.usedFraction > 0.9 ? .orange : MacCleanerTheme.accent)
                    .scaleEffect(x: 1, y: 1.35, anchor: .center)
                    .padding(.vertical, 3)

                VStack(alignment: .leading, spacing: 5) {
                    storageMetric("Used", value: model.storage.usedBytes.formattedByteCount)
                    storageMetric("Total", value: model.storage.totalBytes.formattedByteCount)
                }
            } else {
                Text("Storage capacity isn’t available right now.")
                    .font(.callout)
                    .foregroundStyle(MacCleanerTheme.secondaryText)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 218, alignment: .topLeading)
        .cleanerCard()
    }

    private func storageMetric(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(MacCleanerTheme.secondaryText)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
    }

    private var recentActivity: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(MacCleanerTheme.secondaryText)
            VStack(alignment: .leading, spacing: 3) {
                Text("Recent activity")
                    .font(.subheadline.weight(.semibold))
                if let latest = model.activity.entries.first {
                    Text("\(latest.title) · \(latest.date, style: .relative)")
                        .font(.callout)
                        .foregroundStyle(MacCleanerTheme.secondaryText)
                        .lineLimit(1)
                } else {
                    Text("Your private scan summaries appear here.")
                        .font(.callout)
                        .foregroundStyle(MacCleanerTheme.secondaryText)
                }
            }
            Spacer()
            Button("View") { section = .activity }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

private struct DashboardShortcut: View {
    let title: String
    let detail: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MacCleanerTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MacCleanerTheme.primaryText)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(MacCleanerTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MacCleanerTheme.secondaryText.opacity(0.7))
                    .padding(.top, 3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .cleanerCard(cornerRadius: 16)
    }
}

struct ScanWorkspaceView: View {
    @ObservedObject var model: ScanViewModel
    let kind: ScanKind
    var onOpenAppSecurity: () -> Void = {}
    var titleOverride: String? = nil
    var subtitleOverride: String? = nil
    var initialLocation: FindingLocation? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(titleOverride ?? kind.title)
                            .font(.system(size: 27, weight: .semibold, design: .rounded))
                            .foregroundStyle(MacCleanerTheme.primaryText)
                        Text(subtitleOverride ?? kind.subtitle)
                            .font(.callout)
                            .foregroundStyle(MacCleanerTheme.secondaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        Button {
                            model.scanDisk(for: kind)
                        } label: {
                            Label("Scan This Mac", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(MacCleanerTheme.accent)
                        .disabled(model.isScanning || model.isCleaning)

                        Button("Scan a specific folder…") {
                            model.chooseFolder(for: kind)
                        }
                        .buttonStyle(.link)
                        .disabled(model.isScanning || model.isCleaning)
                    }
                }
                if kind == .largeAndOld {
                    HStack(spacing: 22) {
                        HStack(spacing: 8) {
                            Text("Minimum size")
                                .foregroundStyle(MacCleanerTheme.secondaryText)
                            Slider(value: $model.minimumSizeMB, in: 50...2000, step: 50)
                                .frame(width: 145)
                            Text("\(Int(model.minimumSizeMB)) MB")
                                .monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                        }
                        HStack(spacing: 8) {
                            Text("Older than")
                                .foregroundStyle(MacCleanerTheme.secondaryText)
                            Picker("Age", selection: $model.oldAgeDays) {
                                Text("90 days").tag(90)
                                Text("180 days").tag(180)
                                Text("365 days").tag(365)
                            }
                            .labelsHidden()
                            .frame(width: 110)
                        }
                    }
                    .font(.callout)
                    .padding(12)
                    .background(MacCleanerTheme.canvas, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                if model.isScanning {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(MacCleanerTheme.accent)
                        Text("\(model.progress.stage) · \(model.progress.entriesVisited.formatted()) items checked · \(model.progress.filesVisited.formatted()) files inspected · \(model.progress.bytesVisited.formattedByteCount)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(MacCleanerTheme.secondaryText)
                        Spacer()
                        Button("Cancel scan") { model.cancelScan() }.buttonStyle(.link)
                    }
                }
                if model.isCleaning {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(MacCleanerTheme.accent)
                        Text("Rechecking selected files and moving eligible items to Trash…")
                            .font(.callout)
                            .foregroundStyle(MacCleanerTheme.secondaryText)
                    }
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let result = model.currentResult {
                    if result.wasTruncated {
                        Label("Partial scan: reached the \(result.entryLimit.formatted())-item safety limit for files and folders. Some locations were not checked.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    HStack(spacing: 18) {
                        Label("\(result.entriesVisited.formatted()) files and folders checked", systemImage: "doc.text.magnifyingglass")
                        Label("\(result.items.count.formatted()) findings", systemImage: "list.bullet")
                        if result.skippedItems > 0 {
                            Label("\(result.skippedItems.formatted()) locations not checked", systemImage: "lock")
                        }
                        if !result.excludedLocations.isEmpty {
                            Label("\(result.excludedLocations.count.formatted()) excluded", systemImage: "folder.badge.minus")
                        }
                        Spacer()
                        Text(result.rootPath == "/"
                             ? "Scope: accessible areas on this Mac"
                             : "Scope: \(result.rootPath)")
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.tertiary).help(result.rootPath)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    if let message = model.scanResultPersistenceMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(Color.orange)
                            .textSelection(.enabled)
                    } else if result.rootPath == "/", model.hasSavedFullDiskReview {
                        Label("Saved review from \(result.finishedAt.formatted(date: .abbreviated, time: .shortened)) · available after restart", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if result.rootPath == "/" {
                        Text("Desktop, Documents, Downloads, shared files, your account Library, accessible local account folders, selected system cache and log folders, and connected external drives are included when accessible. Normal app data in your Library is view-only; only recognized caches and logs can be reviewed for Trash. iCloud Desktop files already stored on this Mac appear as read-only results; Mac Cleaner does not download cloud-only files, hash iCloud items for duplicate matching, or move iCloud items to Trash. Other iCloud Drive areas, network drives, protected system areas, protected app data, and folders you excluded in Settings are skipped. Other account files and system-wide cache and log files are view-only; older reports in your account's standard DiagnosticReports folder have a separate review.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if kind == .smart, result.rootPath == "/" {
                        appSecuritySummary
                    }
                    if let count = result.cloudFilesLocallyAvailable {
                        Label("\(count.formatted()) local iCloud Desktop files checked. These results are read-only.", systemImage: "icloud.and.arrow.down")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if result.cloudDesktopAccessUnavailable == true {
                        HStack(spacing: 8) {
                            Label("macOS blocked access to iCloud Desktop. Allow its read-only access once to include local files.", systemImage: "lock.icloud")
                                .font(.caption).foregroundStyle(.orange)
                            Button("Allow Desktop Access") { model.requestICloudDesktopAccess() }
                                .buttonStyle(.link)
                        }
                    }
                    if let count = result.cloudFilesNotLocallyAvailable, count > 0 {
                        Label("\(count.formatted()) iCloud Drive items were not stored on this Mac and were skipped without downloading.", systemImage: "icloud.slash")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !result.excludedLocations.isEmpty {
                        DisclosureGroup("Show excluded folders (\(result.excludedLocations.count.formatted()))") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(result.excludedLocations, id: \.self) { path in
                                    Text(path).font(.caption.monospaced()).textSelection(.enabled)
                                }
                                Text("Exclusions apply to this scan's summary and future scans until removed in Settings.")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.top, 5)
                        }
                        .font(.caption)
                    }
                    if result.skippedItems > 0 {
                        DisclosureGroup("Review \(result.skippedItems.formatted()) locations the scan could not open") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(result.displayedSkippedLocations.enumerated()), id: \.offset) { _, path in
                                    Text(path).font(.caption.monospaced()).textSelection(.enabled)
                                }
                                if result.omittedSkippedLocationCount > 0 {
                                    Text("\(result.omittedSkippedLocationCount.formatted()) additional locations could not be opened and are included in the count above.")
                                        .font(.caption)
                                }
                                if result.skippedItems > result.skippedLocations.count {
                                    Text("Only the first \(result.skippedLocations.count.formatted()) paths are stored in this summary.")
                                        .font(.caption)
                                }
                                Text("For additional access, open System Settings → Privacy & Security → Full Disk Access. macOS can still protect some locations.")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.top, 5)
                        }
                        .font(.caption)
                    }
                }
            }
            .padding(20)
            .cleanerCard()
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)

            if let result = model.currentResult {
                if result.items.isEmpty {
                    VStack(spacing: 8) {
                        ContentUnavailableView(
                            model.lastTrashResult == nil ? "No matches in checked locations" : "Review complete",
                            systemImage: model.lastTrashResult == nil ? "checkmark.circle" : "trash.circle",
                            description: Text(model.lastTrashResult == nil
                                ? "No files matched the scan rules in the locations that could be checked. Review any skipped locations above."
                            : "The updated review has no remaining matching files.")
                        )
                        if let trash = model.lastTrashResult {
                            VStack(spacing: 4) {
                                Text("\(trash.moved.count) moved to Trash · \(trash.bytesMoved.formattedByteCount) · \(trash.failures.count) not moved.")
                                Text("Nothing was permanently deleted.")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Close review") { model.closeReview() }.buttonStyle(.link)
                    }
                } else {
                    ScanResultList(model: model, result: result, initialLocation: initialLocation)
                }
            } else if !model.isScanning {
                folderPrompt
            } else {
                Spacer()
            }
        }
        .confirmationDialog(
            "Move selected items to Trash?",
            isPresented: $model.trashConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Move \(model.selectedItems.count) Items to Trash", role: .destructive) {
                model.moveSelectedToTrash()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            if model.selectedNeedsExtraConfirmation {
                Text("\(model.selectedItems.count) selected items (\(model.selectedBytes.formattedByteCount)) include personal files or items that may have changed. Review paths above; protected or changed files will be blocked. Eligible files move to Trash and remain recoverable there.")
            } else {
                Text("\(model.selectedItems.count) selected items (\(model.selectedBytes.formattedByteCount)) will be moved to Trash. Nothing will be permanently deleted.")
            }
        }
    }

    @ViewBuilder
    private var appSecuritySummary: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "checkmark.shield")
                .font(.title3)
                .foregroundStyle(MacCleanerTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                if let report = model.appSecurityReport {
                    let summary = ApplicationSecurityActivitySummary(report: report)
                    Text(summary.title)
                        .font(.callout.weight(.semibold))
                    Text(summary.note)
                        .font(.caption)
                        .foregroundStyle(MacCleanerTheme.secondaryText)
                    if report.inaccessibleLocations > 0 || report.skippedStartupItems > 0 || report.wasLimited {
                        Text("Some app or startup locations could not be checked. Review the details before drawing conclusions.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("Signature checks provide context; this is not a malware scan.")
                        .font(.caption)
                        .foregroundStyle(MacCleanerTheme.secondaryText)
                } else if model.isScanning {
                    Text("App Security review runs after the file scan.")
                        .font(.callout.weight(.semibold))
                    Text("It checks app signatures and readable startup items. No files are changed.")
                        .font(.caption)
                        .foregroundStyle(MacCleanerTheme.secondaryText)
                } else {
                    Text("This saved file review has no App Security results.")
                        .font(.callout.weight(.semibold))
                    Text("Open App Security for a separate read-only check of installed apps and startup items.")
                        .font(.caption)
                        .foregroundStyle(MacCleanerTheme.secondaryText)
                }
            }
            Spacer(minLength: 8)
            Button("Review App Security", action: onOpenAppSecurity)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var folderPrompt: some View {
        VStack(spacing: 13) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(MacCleanerTheme.accent)
                .frame(width: 68, height: 68)
                .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Text("Find files worth a closer look")
                .font(.title2.weight(.semibold))
                .foregroundStyle(MacCleanerTheme.primaryText)

            Text(kind == .smart
                 ? "Scan accessible files across your Mac, including Desktop, Documents, and Downloads, for items to review. Local iCloud Desktop files appear as read-only results; cloud-only files are not downloaded. Protected operating-system areas are skipped."
                 : "Scan accessible files across your Mac for this type of item. Full Disk Access must be enabled in macOS. Nothing moves unless you select items and confirm.")
                .font(.callout)
                .foregroundStyle(MacCleanerTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button {
                model.scanDisk(for: kind)
            } label: {
                Label("Scan This Mac", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(MacCleanerTheme.accent)
            .padding(.top, 3)

            Button("Or scan a specific folder…") {
                model.chooseFolder(for: kind)
            }
            .buttonStyle(.link)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FilePreviewTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private enum FindingSortOrder: String, CaseIterable, Identifiable {
    case largestFirst
    case oldestFirst
    case newestFirst
    case leastRecentlyAccessed
    case mostRecentlyAccessed
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .largestFirst: "Largest first"
        case .oldestFirst: "Oldest first"
        case .newestFirst: "Newest first"
        case .leastRecentlyAccessed: "Least recently accessed"
        case .mostRecentlyAccessed: "Most recently accessed"
        case .name: "Name"
        }
    }

    var usesAccessDate: Bool {
        self == .leastRecentlyAccessed || self == .mostRecentlyAccessed
    }

    var dateLabel: String { usesAccessDate ? "Last accessed" : "Modified" }
}

private struct QuickLookPreviewSheet: View {
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
            QuickLookPreviewView(url: url)
                .frame(minWidth: 620, minHeight: 440)
        }
    }
}

private struct QuickLookPreviewView: NSViewRepresentable {
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

private struct SpaceFolder: Identifiable, Sendable {
    let path: String
    let bytes: Int64
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    func relativePath(from rootPath: String) -> String {
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

private struct SpaceBreadcrumb: Identifiable, Sendable {
    let path: String
    let name: String
    var id: String { path }
}

private struct SpaceTypeSummary: Identifiable {
    let type: SpaceFileType
    let bytes: Int64
    let count: Int

    var id: String { type.rawValue }
}

private struct SpaceLensView: View {
    @ObservedObject var model: ScanViewModel
    @Binding var section: AppSection?

    var body: some View {
        Group {
            if model.isScanning {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("\(model.progress.stage) · \(model.progress.filesVisited.formatted()) files checked")
                        .foregroundStyle(.secondary)
                    Button("Cancel scan") { model.cancelScan() }
                }
            } else if let result = model.currentResult, let space = result.space {
                SpaceLensResultsView(model: model, result: result, space: space, section: $section)
                    .id(result.finishedAt)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.largeTitle).foregroundStyle(MacCleanerTheme.accent)
                    Text("See where your space goes").font(.title2.weight(.semibold))
                    Text("Run a scan to explore the sizes of the folders it can check.")
                        .foregroundStyle(.secondary)
                    Button("Scan This Mac") { model.scanDisk(for: .smart) }
                        .buttonStyle(.borderedProminent).tint(MacCleanerTheme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct SpaceLensResultsView: View {
    @ObservedObject var model: ScanViewModel
    let result: ScanResult
    let space: SpaceSnapshot
    @Binding var section: AppSection?
    @State private var currentPath: String
    @State private var folderFilter = ""
    @State private var folders: [SpaceFolder] = []
    @State private var findingsByPath: [String: ScanItem] = [:]
    @State private var directoryContents: SpaceLensDirectoryContents?
    @State private var directoryError: String?
    @State private var isLoadingDirectory = false
    @State private var fileFilter = ""
    @State private var visibleFileLimit = 100
    @State private var directoryReloadID = 0
    @State private var directoryRequestID = UUID()
    @State private var previewTarget: FilePreviewTarget?

    private var fileTypeSummaries: [SpaceTypeSummary] {
        let bytesByType = space.fileTypeBytes[currentPath] ?? [:]
        let countsByType = space.fileTypeCounts[currentPath] ?? [:]
        return SpaceFileType.allCases.compactMap { type in
            guard let bytes = bytesByType[type], bytes > 0 else { return nil }
            return SpaceTypeSummary(type: type, bytes: bytes, count: countsByType[type] ?? 0)
        }
        .sorted { $0.bytes == $1.bytes ? $0.type.title < $1.type.title : $0.bytes > $1.bytes }
    }

    init(model: ScanViewModel, result: ScanResult, space: SpaceSnapshot, section: Binding<AppSection?>) {
        self.model = model
        self.result = result
        self.space = space
        _section = section
        _currentPath = State(initialValue: result.rootPath)
    }

    private var normalizedFolderFilter: String {
        folderFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedFileFilter: String {
        fileFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredFolders: [SpaceFolder] { folders }

    private var breadcrumbs: [SpaceBreadcrumb] {
        let rootPath = URL(fileURLWithPath: result.rootPath, isDirectory: true).standardizedFileURL.path
        let current = URL(fileURLWithPath: currentPath, isDirectory: true).standardizedFileURL.path
        guard current == rootPath || SafeFilePolicy.isInside(current, root: rootPath) else {
            return [SpaceBreadcrumb(path: rootPath, name: URL(fileURLWithPath: rootPath).lastPathComponent)]
        }

        let rootName = rootPath == "/" ? "Macintosh HD" : URL(fileURLWithPath: rootPath).lastPathComponent
        var result = [SpaceBreadcrumb(path: rootPath, name: rootName)]
        guard current != rootPath else { return result }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        var accumulatedPath = rootPath
        for component in current.dropFirst(prefix.count).split(separator: "/") {
            accumulatedPath = URL(fileURLWithPath: accumulatedPath, isDirectory: true)
                .appendingPathComponent(String(component), isDirectory: true)
                .standardizedFileURL.path
            result.append(SpaceBreadcrumb(path: accumulatedPath, name: String(component)))
        }
        return result
    }

    private var filteredFiles: [SpaceLensFile] {
        guard !normalizedFileFilter.isEmpty else { return directoryContents?.files ?? [] }
        return (directoryContents?.files ?? []).filter {
            $0.name.localizedCaseInsensitiveContains(normalizedFileFilter)
                || $0.fileType.title.localizedCaseInsensitiveContains(normalizedFileFilter)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Space Lens").font(.system(size: 27, weight: .semibold, design: .rounded))
                        Text("Explore the space used by files this scan could check.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review selected (\(model.selectedItems.count))") { section = resultSection }
                        .disabled(model.selectedItems.isEmpty)
                }

                HStack {
                    Button {
                        let parent = URL(fileURLWithPath: currentPath, isDirectory: true).deletingLastPathComponent().standardizedFileURL.path
                        if currentPath != result.rootPath { currentPath = parent }
                    } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(currentPath == result.rootPath)
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(Array(breadcrumbs.enumerated()), id: \.element.path) { index, crumb in
                                if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                                if index == breadcrumbs.count - 1 {
                                    Text(crumb.name).font(.callout.weight(.medium)).lineLimit(1)
                                } else {
                                    Button(crumb.name) {
                                        currentPath = crumb.path
                                        folderFilter = ""
                                        fileFilter = ""
                                    }
                                    .buttonStyle(.link)
                                    .lineLimit(1)
                                }
                            }
                        }
                    }
                    .help(currentPath)
                    .frame(maxWidth: 520, alignment: .leading)
                    Spacer()
                    Text((space.folderBytes[currentPath] ?? 0).formattedByteCount)
                        .font(.headline.monospacedDigit())
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: currentPath)])
                    } label: { Image(systemName: "arrow.up.right.square") }
                    .help("Reveal folder in Finder")
                    .accessibilityLabel("Show \(URL(fileURLWithPath: currentPath).lastPathComponent) in Finder")
                }

                SpaceTreemap(folders: folders, total: space.folderBytes[currentPath] ?? 0,
                             directBytes: space.directFileBytes[currentPath] ?? 0) { path in
                    currentPath = path
                    folderFilter = ""
                }
                .frame(height: 185)

                if !fileTypeSummaries.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("File types in this location").font(.headline)
                        ForEach(fileTypeSummaries) { summary in
                            VStack(spacing: 5) {
                                HStack(spacing: 8) {
                                    Label(summary.type.title, systemImage: summary.type.symbol)
                                    Spacer()
                                    Text("\(summary.count.formatted()) files")
                                        .foregroundStyle(.secondary)
                                    Text(summary.bytes.formattedByteCount)
                                        .fontWeight(.medium)
                                        .monospacedDigit()
                                }
                                ProgressView(
                                    value: Double(summary.bytes),
                                    total: Double(max(space.folderBytes[currentPath] ?? 1, 1))
                                )
                                .tint(MacCleanerTheme.accent)
                            }
                            .font(.caption)
                        }
                        Text("Sizes include only files checked in this scan.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .cleanerCard()
                }

                Text(result.wasTruncated
                     ? "Partial map: the scan reached its file limit. Sizes cover only files checked."
                     : "Sizes are logical file sizes for checked files. Skipped, protected, and cloud locations are not included.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Text("Folders").font(.headline)
                    Spacer()
                    TextField("Search folders below", text: $folderFilter)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }
                Text(normalizedFolderFilter.isEmpty
                     ? "Showing folders directly inside this location."
                     : "Search checks matching folders at any depth below this location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if filteredFolders.isEmpty {
                    Text(normalizedFolderFilter.isEmpty ? "No scanned subfolders here." : "No matching scanned folders below this location.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredFolders) { folder in
                            Button {
                                currentPath = folder.path
                                folderFilter = ""
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Label(folder.name, systemImage: "folder.fill")
                                        if !normalizedFolderFilter.isEmpty {
                                            Text(folder.relativePath(from: currentPath))
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                    Spacer()
                                    Text(folder.bytes.formattedByteCount).monospacedDigit()
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                                .padding(10).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(MacCleanerTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }

                let directCount = space.directFileCounts[currentPath] ?? 0
                Text("\(directCount.formatted()) checked \(directCount == 1 ? "file" : "files") directly in this folder · \((space.directFileBytes[currentPath] ?? 0).formattedByteCount)")
                    .font(.callout).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Files in this folder").font(.headline)
                        Spacer()
                        if let directoryContents {
                            Text("\(directoryContents.files.count.formatted()) files")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Text("Preview any file here. Only files marked “Found by scan” can be selected for Trash review.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Search files here", text: $fileFilter)
                        .textFieldStyle(.roundedBorder)

                    if isLoadingDirectory {
                        ProgressView("Reading file names and sizes…")
                            .padding(.vertical, 10)
                    } else if let directoryError {
                        ContentUnavailableView("Folder unavailable", systemImage: "folder.badge.questionmark", description: Text(directoryError))
                        Button("Try again") { directoryReloadID += 1 }
                            .buttonStyle(.bordered)
                    } else if let directoryContents {
                        if directoryContents.wasTruncated {
                            Label("This folder is very large. Showing files from the first \(directoryContents.entriesVisited.formatted()) entries; open a smaller folder to see more.", systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if directoryContents.skippedItems > 0 {
                            Text("\(directoryContents.skippedItems.formatted()) items were skipped because they are protected or could not be read.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if filteredFiles.isEmpty {
                            Text(normalizedFileFilter.isEmpty ? "No readable files were found directly in this folder." : "No files match your search.")
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                        } else {
                            LazyVStack(spacing: 7) {
                                ForEach(Array(filteredFiles.prefix(visibleFileLimit))) { file in
                                    spaceLensFileRow(file)
                                }
                            }
                            if filteredFiles.count > visibleFileLimit {
                                Button("Show 100 more (\((filteredFiles.count - visibleFileLimit).formatted()) remaining)") {
                                    visibleFileLimit += 100
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding(14)
                .cleanerCard()
            }
            .padding(28)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: fileFilter) { _, _ in visibleFileLimit = 100 }
        .task(id: "\(currentPath)::\(normalizedFolderFilter)::\(result.items.count)") {
            let path = currentPath
            let normalizedFilter = normalizedFolderFilter
            let allFolders = space.folderBytes
            let allItems = result.items
            findingsByPath = [:]
            let operation = Task.detached(priority: .utility) { () -> ([SpaceFolder], [String: ScanItem]) in
                var children: [SpaceFolder] = []
                for (index, entry) in allFolders.enumerated() {
                    if index.isMultiple(of: 2048) && Task.isCancelled { return ([], [:]) }
                    guard entry.key != path,
                          SafeFilePolicy.isInside(entry.key, root: path) else { continue }
                    let folderURL = URL(fileURLWithPath: entry.key, isDirectory: true).standardizedFileURL
                    let isDirectChild = folderURL.deletingLastPathComponent().standardizedFileURL.path == path
                    let matchesSearch = normalizedFilter.isEmpty
                        ? isDirectChild
                        : folderURL.lastPathComponent.localizedCaseInsensitiveContains(normalizedFilter)
                    if matchesSearch { children.append(SpaceFolder(path: entry.key, bytes: entry.value)) }
                }
                children.sort { $0.bytes == $1.bytes ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.bytes > $1.bytes }
                var direct: [String: ScanItem] = [:]
                for item in allItems {
                    if Task.isCancelled { return ([], [:]) }
                    if URL(fileURLWithPath: item.path).deletingLastPathComponent().standardizedFileURL.path == path {
                        direct[item.path] = item
                    }
                }
                return (children, direct)
            }
            let data = await withTaskCancellationHandler {
                await operation.value
            } onCancel: {
                operation.cancel()
            }
            guard !Task.isCancelled else { return }
            folders = data.0
            findingsByPath = data.1
        }
        .task(id: "\(currentPath)::\(directoryReloadID)") {
            let path = currentPath
            let rootPath = result.rootPath
            let requestID = UUID()
            directoryRequestID = requestID
            directoryContents = nil
            directoryError = nil
            isLoadingDirectory = true

            let operation = Task.detached(priority: .utility) {
                try SpaceLensDirectoryReader.readFiles(
                    in: URL(fileURLWithPath: path, isDirectory: true),
                    within: URL(fileURLWithPath: rootPath, isDirectory: true)
                )
            }
            do {
                let contents = try await withTaskCancellationHandler {
                    try await operation.value
                } onCancel: {
                    operation.cancel()
                }
                guard !Task.isCancelled, directoryRequestID == requestID else { return }
                directoryContents = contents
                visibleFileLimit = 100
                isLoadingDirectory = false
            } catch is CancellationError {
                return
            } catch let error as SpaceLensDirectoryError {
                guard !Task.isCancelled, directoryRequestID == requestID else { return }
                switch error {
                case .outsideScannedLocation:
                    directoryError = "For safety, Mac Cleaner only browses unprotected folders inside this scan."
                case .cannotReadFolder:
                    directoryError = "macOS could not read this folder. Check its access in Finder and try again."
                }
                isLoadingDirectory = false
            } catch {
                guard !Task.isCancelled, directoryRequestID == requestID else { return }
                directoryError = "Mac Cleaner couldn’t read this folder. Try again or open it in Finder."
                isLoadingDirectory = false
            }
        }
        .sheet(item: $previewTarget) { target in QuickLookPreviewSheet(url: target.url) }
    }

    @ViewBuilder
    private func spaceLensFileRow(_ file: SpaceLensFile) -> some View {
        let finding = findingsByPath[file.path]
        let isSelected = finding.map { model.selectedPaths.contains($0.path) } ?? false
        let isKeeper = finding.map { model.duplicateKeeperPath(for: $0) == $0.path } ?? false

        HStack(spacing: 10) {
            if let finding {
                Button { model.toggleSelection(for: finding) } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : (isKeeper ? "lock.circle" : "circle"))
                        .font(.title3)
                        .foregroundStyle(isSelected ? MacCleanerTheme.accent : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(model.isCleaning || isKeeper || SafeFilePolicy.isEssentialSystemLocation(finding.path))
                .help(isKeeper ? "Keep one copy of this exact-duplicate group." : "Select this scan finding for Trash review.")
                .accessibilityLabel(
                    isKeeper ? "Kept copy: \(file.name)" : (isSelected ? "Deselect \(file.name)" : "Select \(file.name)")
                )
                .accessibilityHint(isKeeper ? "This copy stays so at least one exact duplicate remains." : "Adds or removes this file from the Trash review.")
            } else {
                Image(systemName: file.fileType.symbol)
                    .font(.title3)
                    .foregroundStyle(MacCleanerTheme.accent)
                    .frame(width: 22)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).lineLimit(1).textSelection(.enabled)
                Text(finding?.plainLanguageSummary ?? "\(file.fileType.title) · Modified \(file.modifiedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if finding != nil {
                Label("Found by scan", systemImage: "checkmark.seal")
                    .font(.caption).foregroundStyle(MacCleanerTheme.accent)
            }
            Text(file.size.formattedByteCount)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button("Preview") { previewTarget = FilePreviewTarget(url: file.url) }
                .disabled(model.isScanning || model.isCleaning)
                .help("Preview this file with Quick Look")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Reveal this file in Finder")
            .accessibilityLabel("Show \(file.name) in Finder")
        }
        .padding(10)
        .cleanerCard(cornerRadius: 10)
    }

    private var resultSection: AppSection {
        switch result.kind {
        case .smart: .smartScan
        case .largeAndOld: .largeFiles
        case .duplicates: .duplicates
        case .junk: .junk
        case .aiClutter: .aiClutter
        }
    }
}

private struct SpaceTreemap: View {
    let folders: [SpaceFolder]
    let total: Int64
    let directBytes: Int64
    let openFolder: (String) -> Void

    private struct Tile: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
        let path: String?
    }

    private var tiles: [Tile] {
        var result = folders.prefix(12).map { Tile(id: $0.path, title: $0.name, bytes: $0.bytes, path: $0.path) }
        if directBytes > 0 { result.append(Tile(id: "direct-files", title: "Files here", bytes: directBytes, path: nil)) }
        let represented = result.reduce(Int64(0)) { $0 + $1.bytes }
        if total > represented { result.append(Tile(id: "other-folders", title: "Other folders", bytes: total - represented, path: nil)) }
        return result.filter { $0.bytes > 0 }
    }

    var body: some View {
        GeometryReader { geometry in
            let visible = tiles
            let available = max(0, geometry.size.width - CGFloat(max(0, visible.count - 1)) * 3)
            HStack(spacing: 3) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, tile in
                    let width = total > 0 ? available * CGFloat(Double(tile.bytes) / Double(total)) : 0
                    Button {
                        if let path = tile.path { openFolder(path) }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            if width > 70 {
                                Text(tile.title).font(.caption.weight(.semibold)).lineLimit(2)
                                Text(tile.bytes.formattedByteCount).font(.caption2.monospacedDigit())
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(width > 70 ? 9 : 0)
                        .background(MacCleanerTheme.accent.opacity(0.12 + Double(index % 4) * 0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(tile.path == nil)
                    .frame(width: max(0, width), height: geometry.size.height)
                    .help("\(tile.title): \(tile.bytes.formattedByteCount)")
                }
            }
        }
    }
}

private struct ScanResultList: View {
    @ObservedObject var model: ScanViewModel
    let result: ScanResult
    let initialLocation: FindingLocation?
    @State private var searchText = ""
    @State private var categoryFilter: FindingCategory?
    @State private var locationFilter: FindingLocation?
    @State private var previewTarget: FilePreviewTarget?
    @State private var sortOrder = FindingSortOrder.largestFirst
    @State private var groupByFileType = false
    @State private var visibleItems: [ScanItem] = []
    @State private var visibleLimit = 500
    @State private var isFiltering = true
    @State private var categoryCounts: [FindingCategory: Int] = [:]
    @State private var locationCounts: [FindingLocation: Int] = [:]
    @State private var visiblePotentialBytes: Int64?

    init(model: ScanViewModel, result: ScanResult, initialLocation: FindingLocation? = nil) {
        self.model = model
        self.result = result
        self.initialLocation = initialLocation
        _locationFilter = State(initialValue: initialLocation)
    }

    private struct ReviewQuery: Hashable {
        let finishedAt: Date
        let count: Int
        let search: String
        let category: FindingCategory?
        let location: FindingLocation?
        let order: FindingSortOrder
        let groupByFileType: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("REVIEW FINDINGS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(visibleItems.count.formatted()) shown of \(result.items.count.formatted()) · \(visiblePotentialBytes.map { $0.formattedByteCount } ?? "Calculating…") potential space to review")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if !model.selectedPaths.isEmpty {
                    Text("\(model.selectedItems.count) selected · \(model.selectedBytes.formattedByteCount)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button("Select low-risk shown") { model.selectAllEligible(from: visibleItems) }
                    .buttonStyle(.link)
                    .disabled(model.isCleaning || isFiltering)
                    .help("Select only low-risk temporary files currently shown by the search and filters.")
                Button("Clear") { model.clearSelection() }.buttonStyle(.link).disabled(model.selectedPaths.isEmpty || model.isCleaning)
                Button("Close review") { model.closeReview() }.buttonStyle(.link).disabled(model.isCleaning)
                Button {
                    model.requestTrashSelected()
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(model.selectedPaths.isEmpty || model.isCleaning)
            }
            .padding(.horizontal, 22).padding(.vertical, 13)

            HStack(spacing: 12) {
                TextField("Search names or locations", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 340)
                Picker("Category", selection: $categoryFilter) {
                    Text("All categories (\(result.items.count))").tag(nil as FindingCategory?)
                    ForEach(FindingCategory.allCases) { category in
                        let count = categoryCounts[category] ?? 0
                        if count > 0 {
                            Text("\(category.title) (\(count))").tag(Optional(category))
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                Picker("Sort", selection: $sortOrder) {
                    ForEach(FindingSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .labelsHidden()
                .frame(width: 155)
                Picker("Group", selection: $groupByFileType) {
                    Text("List").tag(false)
                    Text("By file type").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 140)
                .help("Group results by filename extension. Files without an extension are grouped together.")
                Spacer()
                Text(result.items.contains(where: { $0.duplicateGroupID != nil })
                     ? "Choose a copy to keep. Other accessible copies are checked for review; Trash requires confirmation."
                     : "Nothing moves until you confirm.")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(3).multilineTextAlignment(.trailing)
                    .frame(maxWidth: 320, alignment: .trailing)
            }
            .padding(.horizontal, 22).padding(.bottom, 12)

            if result.rootPath == "/" {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("Review findings by location")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Button {
                            locationFilter = nil
                        } label: {
                            Label("All locations · \(result.items.count)", systemImage: "externaldrive")
                        }
                        .buttonStyle(.bordered)
                        .tint(locationFilter == nil ? MacCleanerTheme.accent : Color.gray)
                        ForEach(FindingLocation.allCases) { location in
                            let count = locationCounts[location, default: 0]
                            if count > 0 {
                                Button {
                                    locationFilter = location
                                } label: {
                                    Label("\(location.title) · \(count)", systemImage: location.symbol)
                                }
                                .buttonStyle(.bordered)
                                .tint(locationFilter == location ? MacCleanerTheme.accent : Color.gray)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                }
                .padding(.bottom, 10)
            }

            if let trash = model.lastTrashResult {
                HStack(spacing: 8) {
                    Image(systemName: trash.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trash.failures.isEmpty ? MacCleanerTheme.accent : .orange)
                    Text("\(trash.moved.count) moved to Trash · \(trash.bytesMoved.formattedByteCount) · \(trash.failures.count) not moved")
                        .font(.caption)
                    Spacer()
                    if trash.failures.isEmpty {
                        Text("Nothing was permanently deleted")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(11).background(.quaternary.opacity(0.6))
                if !trash.failures.isEmpty {
                    DisclosureGroup("Show failed items (\(trash.failures.count))") {
                        ForEach(trash.failures, id: \.path) { failure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.reason).font(.caption.weight(.medium))
                                Text(failure.path).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.bottom, 10)
                }
            }

            List {
                if groupByFileType {
                    ForEach(visibleFileTypeGroups) { group in
                        Section(header: Text("\(group.title) · \(group.count)")) {
                            ForEach(group.items) { item in
                                findingRow(item)
                            }
                        }
                    }
                } else {
                    ForEach(Array(visibleItems.prefix(visibleLimit))) { item in
                        findingRow(item)
                    }
                }
                if isFiltering {
                    ProgressView("Organizing findings…")
                } else if visibleItems.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if visibleItems.count > visibleLimit {
                    Button("Show 500 more (\(visibleItems.count - visibleLimit) remaining)") {
                        visibleLimit += 500
                    }
                }
            }
            .listStyle(.inset)
        }
        .sheet(item: $previewTarget) { target in
            QuickLookPreviewSheet(url: target.url)
        }
        .task(id: result.finishedAt) {
            let items = result.items
            let homeDirectory = SafeFilePolicy.accountHome
            let summary = await Task.detached(priority: .utility) { () -> ([FindingCategory: Int], [FindingLocation: Int]) in
                var counts: [FindingCategory: Int] = [:]
                var locations: [FindingLocation: Int] = [:]
                for item in items {
                    for category in item.categories { counts[category, default: 0] += 1 }
                    let location = FindingLocation.classify(item.path, homeDirectory: homeDirectory)
                    locations[location, default: 0] += 1
                }
                return (counts, locations)
            }.value
            guard !Task.isCancelled else { return }
            categoryCounts = summary.0
            locationCounts = summary.1
        }
        .onChange(of: result.finishedAt) { _, _ in
            locationFilter = initialLocation
        }
        .task(id: ReviewQuery(finishedAt: result.finishedAt, count: result.items.count, search: searchText, category: categoryFilter, location: locationFilter, order: sortOrder, groupByFileType: groupByFileType)) {
            isFiltering = true
            visibleLimit = 500
            let items = result.items
            let query = searchText
            let category = categoryFilter
            let location = locationFilter
            let homeDirectory = SafeFilePolicy.accountHome
            let order = sortOrder
            let shouldGroupByFileType = groupByFileType
            let operation = Task.detached(priority: .utility) { () -> ([ScanItem], Int64) in
                var matches: [ScanItem] = []
                var bytes: Int64 = 0
                for (index, item) in items.enumerated() {
                    if index.isMultiple(of: 2048) && Task.isCancelled { return ([], 0) }
                    let matchesCategory = category.map(item.categories.contains) ?? true
                    let matchesLocation = location.map { $0.contains(item.path, homeDirectory: homeDirectory) } ?? true
                    let matchesSearch = query.isEmpty || item.name.localizedCaseInsensitiveContains(query)
                        || item.path.localizedCaseInsensitiveContains(query) || item.sourceApplication.localizedCaseInsensitiveContains(query)
                    if matchesCategory && matchesLocation && matchesSearch {
                        matches.append(item)
                        if item.duplicateGroupID == nil || item.path != item.suggestedKeepPath { bytes += item.size }
                    }
                }
                if order != .largestFirst || shouldGroupByFileType {
                    matches.sort { lhs, rhs in
                        if shouldGroupByFileType && lhs.fileTypeKey != rhs.fileTypeKey {
                            if lhs.fileTypeKey.isEmpty != rhs.fileTypeKey.isEmpty {
                                return !lhs.fileTypeKey.isEmpty
                            }
                            return lhs.fileTypeKey.localizedStandardCompare(rhs.fileTypeKey) == .orderedAscending
                        }
                        switch order {
                        case .largestFirst:
                            if lhs.size != rhs.size { return lhs.size > rhs.size }
                        case .oldestFirst:
                            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
                        case .newestFirst:
                            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
                        case .leastRecentlyAccessed:
                            if lhs.lastAccessedAt != rhs.lastAccessedAt {
                                return (lhs.lastAccessedAt ?? .distantFuture) < (rhs.lastAccessedAt ?? .distantFuture)
                            }
                        case .mostRecentlyAccessed:
                            if lhs.lastAccessedAt != rhs.lastAccessedAt {
                                return (lhs.lastAccessedAt ?? .distantPast) > (rhs.lastAccessedAt ?? .distantPast)
                            }
                        case .name:
                            let comparison = lhs.name.localizedStandardCompare(rhs.name)
                            if comparison != .orderedSame { return comparison == .orderedAscending }
                        }
                        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                    }
                }
                return (matches, bytes)
            }
            let (matches, bytes) = await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
            guard !Task.isCancelled else { return }
            visibleItems = matches
            visiblePotentialBytes = bytes
            isFiltering = false
        }
    }

    private var visibleFileTypeGroups: [FindingTypeGroup] {
        let grouped = Dictionary(grouping: visibleItems, by: \.fileTypeKey)
        let keys = grouped.keys.sorted { lhs, rhs in
            if lhs.isEmpty != rhs.isEmpty { return !lhs.isEmpty }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        var remaining = visibleLimit
        var groups: [FindingTypeGroup] = []
        for key in keys where remaining > 0 {
            guard let items = grouped[key] else { continue }
            let visibleGroupItems = Array(items.prefix(remaining))
            guard !visibleGroupItems.isEmpty else { continue }
            let title = items.first?.fileTypeTitle ?? "Files"
            groups.append(FindingTypeGroup(key: key, title: title, count: items.count, items: visibleGroupItems))
            remaining -= visibleGroupItems.count
        }
        return groups
    }

    private func findingRow(_ item: ScanItem) -> some View {
        let keeperPath = model.duplicateKeeperPath(for: item)
        return FindingRow(
            item: item,
            sortOrder: sortOrder,
            selected: model.selectedPaths.contains(item.path),
            viewOnlyLabel: SafeFilePolicy.isEssentialSystemLocation(item.path)
                ? "System location — view only"
                : (item.isCloudManaged == true
                    ? "iCloud Drive — view only"
                    : (SafeFilePolicy.isOtherUserAccountPath(item.path)
                        ? "Another account — view only"
                        : (SafeFilePolicy.isReadOnlyCurrentAccountLibraryItem(path: item.path, categories: item.categories)
                            ? "App data — view only"
                            : nil))),
            isDuplicateKeeper: keeperPath == item.path,
            isSuggestedKeeper: model.isSuggestedDuplicateKeeper(for: item),
            chooseAsKeeper: { model.chooseDuplicateKeeper(for: item) },
            preview: {
                if item.isCloudManaged == true,
                   !ICloudDesktopPolicy.isAvailableForReadOnlyPreview(item.url) {
                    model.showNotice("This iCloud Drive item no longer has a current local copy, so Mac Cleaner did not open it or request a download.")
                    return
                }
                previewTarget = FilePreviewTarget(url: item.url)
            }
        ) {
            model.toggleSelection(for: item)
        }
        .listRowSeparator(.visible)
    }
}

private struct FindingTypeGroup: Identifiable {
    let key: String
    let title: String
    let count: Int
    let items: [ScanItem]

    var id: String { key }
}

private struct FindingRow: View {
    let item: ScanItem
    let sortOrder: FindingSortOrder
    let selected: Bool
    let viewOnlyLabel: String?
    let isDuplicateKeeper: Bool
    let isSuggestedKeeper: Bool
    let chooseAsKeeper: () -> Void
    let preview: () -> Void
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDuplicateKeeper ? "Keeping \(item.name)" : (selected ? "Deselect \(item.name)" : "Select \(item.name)"))
            .disabled(viewOnlyLabel != nil || isDuplicateKeeper)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                    ForEach(item.categories, id: \.self) { category in
                        Text(category.title.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(0.5)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.11), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer(minLength: 10)
                    Text(item.size.formattedByteCount).font(.callout.monospacedDigit().weight(.medium))
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(sortOrder.dateLabel).font(.caption2).foregroundStyle(.tertiary)
                        if let date = sortOrder.usesAccessDate ? item.lastAccessedAt : item.modifiedAt {
                            Text(date, format: .dateTime.year().month(.abbreviated).day())
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Unavailable").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 105, alignment: .trailing)
                }
                Text(item.path).lineLimit(1).truncationMode(.middle)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).help(item.path)
                Text(item.plainLanguageSummary).lineLimit(2)
                    .font(.caption).foregroundStyle(.secondary)
                if let viewOnlyLabel {
                    Label(viewOnlyLabel, systemImage: "lock")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if item.categories.contains(.aiCacheCandidate) {
                        Text("App: \(item.sourceApplication)")
                    }
                    Text(item.consequence).lineLimit(1)
                }
                .font(.caption2).foregroundStyle(.tertiary)
                if item.duplicateGroupID != nil {
                    if isDuplicateKeeper {
                        Label(isSuggestedKeeper ? "Suggested keep" : "Keeping this copy", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.medium)).foregroundStyle(MacCleanerTheme.accent)
                    } else {
                        Button(action: chooseAsKeeper) {
                            Label("Keep this copy", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.link)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(MacCleanerTheme.accent)
                        .help("Keep this copy. Other accessible copies will be checked for review.")
                        .accessibilityLabel("Keep this copy: \(item.name)")
                    }
                }
                if item.safetyNote.hasPrefix("Review carefully") {
                    Label(item.safetyNote, systemImage: "hand.raised.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
                DisclosureGroup("More details") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(item.reasons.enumerated()), id: \.offset) { _, reason in
                            Text(reason)
                        }
                        Text("Source app: \(item.sourceApplication)")
                        Text("Rule match: \(Int(item.confidence * 100))%. This describes how closely the file matched a scan rule; it is not a safety score.")
                        Text(item.consequence)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                Button(action: preview) {
                    Label("Preview", systemImage: "eye")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain).foregroundStyle(MacCleanerTheme.accent)
                .help("Preview this file")
                .accessibilityLabel("Preview \(item.name)")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Reveal in Finder")
                .accessibilityLabel("Show \(item.name) in Finder")
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private struct ActivityView: View {
    @ObservedObject var store: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Activity").font(.system(size: 27, weight: .semibold, design: .rounded))
            Text("Local scan, cleanup, App Security, and update summaries. File names and paths are not stored here.")
                .font(.callout).foregroundStyle(.secondary)
            if store.entries.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "clock.arrow.circlepath", description: Text("Run a scan or App Security check to add a local summary."))
            } else {
                ActivityTrendPanel(entries: store.entries)
                Text("Recent activity").font(.headline)
                List(store.entries) { entry in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: entry.symbol)
                            .foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).font(.body.weight(.medium))
                            Text(entry.note).font(.callout).foregroundStyle(.secondary)
                            Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(entry.itemCountLabel)
                                .font(.callout.monospacedDigit())
                            if entry.bytesAffected > 0 {
                                Text(entry.bytesAffected.formattedByteCount)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.inset)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private extension ActivityEntry {
    var symbol: String {
        switch kind {
        case .scan: "magnifyingglass"
        case .cleanup: "trash"
        case .updateCheck: "arrow.down.app"
        case .securityCheck: "checkmark.shield"
        case .other: "clock.arrow.circlepath"
        }
    }
}

private struct ActivityTrendPanel: View {
    let entries: [ActivityEntry]
    private let calendar = Calendar.current
    @State private var selectedRange = ActivityTrendRange.sevenDays

    private var summary: ActivityTrendSummary {
        ActivityTrendSummary.recent(entries: entries, range: selectedRange, calendar: calendar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(selectedRange.title).font(.headline)
                Spacer()
                Picker("Activity range", selection: $selectedRange) {
                    ForEach(ActivityTrendRange.allCases) { range in
                        Text(range.title.replacingOccurrences(of: "Last ", with: "")).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .accessibilityLabel("Activity time range")
            }

            HStack(spacing: 12) {
                metric(title: "Scans", value: summary.scanCount, symbol: "magnifyingglass")
                metric(title: "Cleanup actions", value: summary.cleanupCount, symbol: "trash")
                metric(title: "Security checks", value: summary.securityCheckCount, symbol: "checkmark.shield")
                metric(title: "Update checks", value: summary.updateCheckCount, symbol: "arrow.down.app")
            }

            if summary.scanCount + summary.cleanupCount + summary.securityCheckCount + summary.updateCheckCount == 0 {
                Text("No scans, cleanup actions, App Security checks, or update checks were recorded in \(selectedRange.title.lowercased()).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                Chart(summary.periods) { period in
                    BarMark(
                        x: .value("Period", period.date),
                        y: .value("Count", period.scans)
                    )
                    .foregroundStyle(by: .value("Activity", "Scans"))
                    .position(by: .value("Activity", "Scans"))

                    BarMark(
                        x: .value("Period", period.date),
                        y: .value("Count", period.cleanupActions)
                    )
                    .foregroundStyle(by: .value("Activity", "Cleanup"))
                    .position(by: .value("Activity", "Cleanup"))

                    BarMark(
                        x: .value("Period", period.date),
                        y: .value("Count", period.securityChecks)
                    )
                    .foregroundStyle(by: .value("Activity", "Security checks"))
                    .position(by: .value("Activity", "Security checks"))

                    BarMark(
                        x: .value("Period", period.date),
                        y: .value("Count", period.updateChecks)
                    )
                    .foregroundStyle(by: .value("Activity", "Update checks"))
                    .position(by: .value("Activity", "Update checks"))
                }
                .chartForegroundStyleScale(
                    domain: ["Scans", "Cleanup", "Security checks", "Update checks"],
                    range: [MacCleanerTheme.accent, .teal, .purple, .orange]
                )
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: selectedRange == .sevenDays ? 7 : 6)) { _ in
                        if selectedRange == .sevenDays {
                            AxisValueLabel(format: .dateTime.weekday(.narrow))
                        } else {
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        }
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
                .frame(height: 150)
                .accessibilityLabel("Bar chart of scans, cleanup actions, App Security checks, and update checks: \(selectedRange.title.lowercased())")
            }

            Text("This chart summarizes locally stored actions. The 90-day view groups actions by week. Mac Cleaner retains up to \(ActivityStore.maximumEntries) summaries; files, names, and paths are not included. A file size sent to Trash is an estimate and may differ from storage macOS frees.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .cleanerCard()
    }

    private func metric(title: String, value: Int, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(MacCleanerTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(value.formatted())
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard(cornerRadius: 12)
    }
}

struct SettingsView: View {
    @ObservedObject var model: ScanViewModel
    var onScanStarted: (() -> Void)? = nil
    var onShowPermissions: (() -> Void)? = nil
    @State private var showSetupGuide = false
    @State private var exclusionError: String?
    @State private var savedFolderError: String?
    @State private var diagnosticsExportError: String?
    @State private var diagnosticsExported = false
    @State private var resetPreferencesConfirmationPresented = false
    @State private var preferencesReset = false
    @AppStorage(MacCleanerAppearancePreference.storageKey)
    private var appearance = MacCleanerAppearancePreference.defaultValue.rawValue
    @AppStorage(MenuBarPreferenceKey.cpu) private var menuBarCPU = true
    @AppStorage(MenuBarPreferenceKey.memory) private var menuBarMemory = true
    @AppStorage(MenuBarPreferenceKey.storage) private var menuBarStorage = true
    @AppStorage(MenuBarPreferenceKey.battery) private var menuBarBattery = true
    @AppStorage(MenuBarPreferenceKey.network) private var menuBarNetwork = false
    @AppStorage(MenuBarPreferenceKey.uptime) private var menuBarUptime = false
    @AppStorage(ProcessActivityDisplayLimit.storageKey)
    private var processActivityDisplayLimit = ProcessActivityDisplayLimit.defaultValue.rawValue
    @AppStorage(SimilarPhotosPreference.storageKey)
    private var similarPhotosMatchTolerance = SimilarPhotosPreference.defaultValue
    @AppStorage(ActivityNotificationKind.scanCompleted.preferenceKey) private var scanNotificationsEnabled = false
    @AppStorage(ActivityNotificationKind.cleanupCompleted.preferenceKey) private var cleanupNotificationsEnabled = false
    @AppStorage(ActivityNotificationKind.appUpdateSourceCheckCompleted.preferenceKey) private var appUpdateSourceCheckNotificationsEnabled = false
    @AppStorage(ActivityNotificationKind.appSecurityCheckCompleted.preferenceKey) private var appSecurityCheckNotificationsEnabled = false
    @AppStorage(ActivityNotificationKind.macHealthCheckCompleted.preferenceKey) private var macHealthCheckNotificationsEnabled = false
    @State private var notificationAuthorization = ActivityNotificationAuthorization.notDetermined
    @State private var isUpdatingNotifications = false
    @State private var notificationMessage: String?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Mac Cleaner appearance", selection: $appearance) {
                    ForEach(MacCleanerAppearancePreference.allCases) { preference in
                        Text(preference.title).tag(preference.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text(appearanceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Keyboard shortcuts") {
                ForEach(AppSection.navigationShortcutSections) { item in
                    HStack {
                        Text(item.title)
                        Spacer()
                        Text(item.navigationShortcutKey.map { "⌘" + String($0) } ?? "")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("These work from anywhere in Mac Cleaner. Press Command-comma to open Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("File review") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Large file threshold")
                        Spacer()
                        Text("\(Int(model.minimumSizeMB)) MB").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $model.minimumSizeMB, in: 50...2000, step: 50)
                }
                Picker("Older than", selection: $model.oldAgeDays) {
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                    Text("365 days").tag(365)
                }
                Picker("Suggested duplicate to keep", selection: $model.duplicateKeepPreference) {
                    ForEach(DuplicateKeepPreference.allCases) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                Text("This only changes the suggested copy. You can choose a different one in each duplicate group before cleanup.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Similar Photos") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Match tolerance")
                        Spacer()
                        Text(SimilarPhotosPreference.label(for: similarPhotosMatchTolerance))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $similarPhotosMatchTolerance,
                        in: SimilarPhotosPreference.allowedRange,
                        step: 1
                    )
                    .accessibilityLabel("Similar photo match tolerance")
                    .accessibilityValue(SimilarPhotosPreference.label(for: similarPhotosMatchTolerance))
                }
                Text("Strict finds fewer, closer matches. More matches may include photos from different moments, so preview each suggestion before choosing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Scan exclusions") {
                Text("Exclude folders and everything inside them from future scans. Adding an exclusion stores only its folder path; Mac Cleaner does not read its files.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.excludedScanPaths.isEmpty {
                    Text("No folders are excluded.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.excludedScanPaths, id: \.self) { path in
                        HStack(spacing: 10) {
                            Image(systemName: "folder.badge.minus")
                                .foregroundStyle(MacCleanerTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .font(.callout.weight(.medium))
                                Text(path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("Remove") { model.removeScanExclusion(path) }
                                .disabled(model.isScanning || model.isCleaning)
                        }
                    }
                }
                Button("Choose folders to exclude…", action: chooseScanExclusions)
                    .disabled(model.isScanning || model.isCleaning)
                if let exclusionError {
                    Label(exclusionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Saved scan folders") {
                Text("Save folders you scan often. Mac Cleaner stores a macOS folder bookmark so you can run Smart Scan again without choosing the folder each time. Removing a shortcut only removes its saved access.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.savedScanFolders.isEmpty {
                    Text("No folders are saved.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.savedScanFolders) { folder in
                        HStack(spacing: 10) {
                            Image(systemName: "folder.badge.gearshape")
                                .foregroundStyle(MacCleanerTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.name)
                                    .font(.callout.weight(.medium))
                                Text(folder.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("Scan") {
                                model.scanSavedFolder(folder.path)
                                if model.isScanning { onScanStarted?() }
                            }
                            .disabled(model.isScanning || model.isCleaning)
                            Button("Remove") { model.removeSavedScanFolder(folder.path) }
                                .disabled(model.isScanning || model.isCleaning)
                        }
                    }
                }
                Button("Save a folder…", action: chooseSavedScanFolder)
                    .disabled(model.isScanning || model.isCleaning)
                if let savedFolderError {
                    Label(savedFolderError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let error = model.errorMessage, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            Section("Privacy") {
                Label("Your scan notice is saved on this Mac. Full Disk Access is managed in System Settings and can be turned off there.", systemImage: "folder.badge.gearshape")
                Label("Known credentials, sensitive app data, and cloud-synced folders are excluded from Smart Scan.", systemImage: "hand.raised")
                Label("Scans are read-only. Cleanup moves selected files to Trash after a second confirmation.", systemImage: "trash.circle")
                Label("Activity history stores summaries only, without file names or paths.", systemImage: "lock.shield")
                if let onShowPermissions {
                    Button("Review Privacy & Permissions", action: onShowPermissions)
                }
            }
            Section("Saved scan review") {
                Text("The latest full-disk review is stored in Mac Cleaner’s private app storage on this Mac. File names and paths are included so you can reopen and preview findings after a restart. Nothing is uploaded. Clear the saved review whenever you like.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.hasSavedFullDiskReview {
                    Label(model.scanResultPersistenceMessage == nil
                        ? "A full-disk review is saved on this Mac."
                        : "A previously saved full-disk review is available to clear.", systemImage: "checkmark.circle")
                        .font(.callout)
                    Button("Forget saved full-disk review", role: .destructive) {
                        model.forgetSavedFullDiskReview()
                    }
                    .disabled(model.isScanning || model.isCleaning)
                } else {
                    Text("No saved full-disk review.")
                        .foregroundStyle(.secondary)
                }
                if let message = model.scanResultPersistenceMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            Section("Notifications") {
                Text("Choose which local checks can alert you when they finish. Alerts never contain file names or paths. macOS asks for permission only the first time you turn a notification on.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("When a scan finishes", isOn: $scanNotificationsEnabled)
                    .disabled(isUpdatingNotifications)
                    .onChange(of: scanNotificationsEnabled) { _, enabled in
                        guard enabled else { return }
                        enableNotification(.scanCompleted)
                    }
                Toggle("When a cleanup review finishes", isOn: $cleanupNotificationsEnabled)
                    .disabled(isUpdatingNotifications)
                    .onChange(of: cleanupNotificationsEnabled) { _, enabled in
                        guard enabled else { return }
                        enableNotification(.cleanupCompleted)
                    }
                Toggle("When an app update source check finishes", isOn: $appUpdateSourceCheckNotificationsEnabled)
                    .disabled(isUpdatingNotifications)
                    .onChange(of: appUpdateSourceCheckNotificationsEnabled) { _, enabled in
                        guard enabled else { return }
                        enableNotification(.appUpdateSourceCheckCompleted)
                    }
                Toggle("When an App Security check finishes", isOn: $appSecurityCheckNotificationsEnabled)
                    .disabled(isUpdatingNotifications)
                    .onChange(of: appSecurityCheckNotificationsEnabled) { _, enabled in
                        guard enabled else { return }
                        enableNotification(.appSecurityCheckCompleted)
                    }
                Toggle("When a Mac Health check finishes", isOn: $macHealthCheckNotificationsEnabled)
                    .disabled(isUpdatingNotifications)
                    .onChange(of: macHealthCheckNotificationsEnabled) { _, enabled in
                        guard enabled else { return }
                        enableNotification(.macHealthCheckCompleted)
                    }
                if let notificationMessage {
                    Label(notificationMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                    if notificationAuthorization == .denied {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                        }
                    }
                }
            }
            Section("Menu bar indicators") {
                Text("Choose which readings appear when you open the Mac Cleaner menu bar panel.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("CPU activity", isOn: $menuBarCPU)
                Toggle("Memory and pressure", isOn: $menuBarMemory)
                Toggle("Storage", isOn: $menuBarStorage)
                Toggle("Battery", isOn: $menuBarBattery)
                Toggle("Network transfer rates", isOn: $menuBarNetwork)
                Toggle("Time since restart", isOn: $menuBarUptime)
            }
            Section("Performance") {
                Picker("Process list size", selection: $processActivityDisplayLimit) {
                    ForEach(ProcessActivityDisplayLimit.allCases) { limit in
                        Text(limit.title).tag(limit.rawValue)
                    }
                }
                Text("Choose how many of the highest CPU or memory readings to show in Performance. This only changes the list; it does not change what Mac Cleaner scans.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Disk access") {
                HStack {
                    Label(
                        model.standardFoldersAccessible
                            ? "Documents and Downloads are accessible"
                            : (model.standardFoldersChecked ? "Full Disk Access may be needed" : "Disk access hasn't been checked yet"),
                        systemImage: model.standardFoldersAccessible ? "checkmark.circle" : "lock"
                    )
                    Spacer()
                    Button("Open System Settings") { model.openFullDiskAccessSettings() }
                        .disabled(model.isScanning || model.isCleaning)
                }
                Text("Mac Cleaner checks whether it can open Documents and Downloads, then scans the Mac directly without asking you to choose each folder. Scans are read-only; selected files go to Trash only after you confirm. Full Disk Access is managed in System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Label(
                    model.iCloudDesktopAccessSaved
                        ? "iCloud Desktop access is saved (read-only)"
                        : (model.iCloudDesktopAccessStatus ?? "iCloud Desktop access hasn't been granted"),
                    systemImage: model.iCloudDesktopAccessSaved ? "checkmark.icloud" : "lock.icloud"
                )
                Text("macOS may require one separate folder choice for Desktop. Mac Cleaner checks only files already stored on this Mac and never moves iCloud Desktop items to Trash.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Allow Desktop Access") { model.requestICloudDesktopAccess() }
                    if model.iCloudDesktopAccessSaved {
                        Button("Forget Desktop Access") { model.forgetICloudDesktopAccess() }
                            .disabled(model.isScanning || model.isCleaning)
                    }
                }
                if let message = model.iCloudDesktopAccessStatus {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Button(model.scanNoticeAccepted ? "Review scan and access details" : "Review and accept scan access") { showSetupGuide = true }
            }
            Section("Diagnostics") {
                Text("The report includes app and macOS versions, scan totals, and scan settings. It leaves out file contents, file names and paths, account names, and excluded-folder names.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Export Diagnostics…", action: exportDiagnostics)
                if diagnosticsExported {
                    Label("Diagnostics report saved.", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let diagnosticsExportError {
                    Label(diagnosticsExportError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Scheduled scans") {
                Text("Scheduled scans are planned and are not enabled in this build.")
                    .foregroundStyle(.secondary)
            }
            Section("Reset preferences") {
                Text("Restore default appearance, file-review settings, tool favorites, notification choices, process list size, and menu-bar readings. Saved access, exclusions, folder shortcuts, activity history, and files stay unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Restore Defaults", role: .destructive) {
                    resetPreferencesConfirmationPresented = true
                }
                .disabled(model.isScanning || model.isCleaning)
                if preferencesReset {
                    Label("Preferences restored.", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("About Mac Cleaner") {
                Label("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development Build")", systemImage: "info.circle")
                Text("Mac Cleaner scans locally. Your files stay on your Mac unless you choose and confirm a move to Trash.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .confirmationDialog(
            "Restore Mac Cleaner defaults?",
            isPresented: $resetPreferencesConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Restore Defaults", role: .destructive) {
                model.minimumSizeMB = 500
                model.oldAgeDays = 180
                model.duplicateKeepPreference = .oldest
                SettingsPreferenceReset().restoreDefaults()
                preferencesReset = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This changes appearance, file-review settings, favorites, notification choices, process list size, and menu-bar readings. Full Disk Access, exclusions, saved scan folders, activity history, and files will not change.")
        }
        .sheet(isPresented: $showSetupGuide) {
            SetupGuideView(model: model, onScanStarted: {
                showSetupGuide = false
                onScanStarted?()
            }, onDismiss: { showSetupGuide = false })
        }
        .task {
            notificationAuthorization = await ActivityNotificationService.shared.authorizationStatus()
            if notificationAuthorization == .denied,
               scanNotificationsEnabled || cleanupNotificationsEnabled || appUpdateSourceCheckNotificationsEnabled || appSecurityCheckNotificationsEnabled || macHealthCheckNotificationsEnabled {
                notificationMessage = "macOS currently blocks Mac Cleaner notifications. Change this in System Settings → Notifications."
            }
        }
    }

    private func enableNotification(_ kind: ActivityNotificationKind) {
        guard !isUpdatingNotifications else { return }
        isUpdatingNotifications = true
        notificationMessage = nil
        Task {
            let result = await ActivityNotificationService.shared.enable(kind)
            notificationAuthorization = await ActivityNotificationService.shared.authorizationStatus()
            isUpdatingNotifications = false
            switch result {
            case .enabled:
                notificationMessage = nil
            case .denied:
                if kind == .scanCompleted { scanNotificationsEnabled = false }
                if kind == .cleanupCompleted { cleanupNotificationsEnabled = false }
                if kind == .appUpdateSourceCheckCompleted { appUpdateSourceCheckNotificationsEnabled = false }
                if kind == .appSecurityCheckCompleted { appSecurityCheckNotificationsEnabled = false }
                if kind == .macHealthCheckCompleted { macHealthCheckNotificationsEnabled = false }
                notificationMessage = "Notifications are off. macOS remembers your choice; to enable them later, use System Settings → Notifications → Mac Cleaner."
            case .failed:
                if kind == .scanCompleted { scanNotificationsEnabled = false }
                if kind == .cleanupCompleted { cleanupNotificationsEnabled = false }
                if kind == .appUpdateSourceCheckCompleted { appUpdateSourceCheckNotificationsEnabled = false }
                if kind == .appSecurityCheckCompleted { appSecurityCheckNotificationsEnabled = false }
                if kind == .macHealthCheckCompleted { macHealthCheckNotificationsEnabled = false }
                notificationMessage = "Mac Cleaner couldn’t update notification access. Try again from this setting."
            }
        }
    }

    private func chooseScanExclusions() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folders to Exclude from Scans"
        panel.message = "These folders and everything inside them will be skipped. Their files are not read when you add them."
        panel.prompt = "Exclude Folders"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.resolvesAliases = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = SafeFilePolicy.accountHome
        guard panel.runModal() == .OK else { return }

        exclusionError = nil
        for folder in panel.urls {
            do {
                try model.addScanExclusion(folder)
            } catch ScanExclusionError.cannotExcludeDiskRoot {
                exclusionError = "Macintosh HD cannot be excluded. Choose a folder inside it."
            } catch {
                exclusionError = "That folder could not be saved as an exclusion."
            }
        }
    }

    private var appearanceDescription: String {
        switch MacCleanerAppearancePreference.resolve(appearance) {
        case .system:
            "Follow the appearance set in macOS System Settings."
        case .light:
            "Use the clean, light appearance across Mac Cleaner windows and the menu bar panel."
        case .dark:
            "Use the dark appearance across Mac Cleaner windows and the menu bar panel."
        }
    }

    private func chooseSavedScanFolder() {
        let panel = NSOpenPanel()
        panel.title = "Save a Folder for Future Scans"
        panel.message = "Choose a folder. Mac Cleaner saves access to that folder so you can scan it again later."
        panel.prompt = "Save Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.resolvesAliases = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = SafeFilePolicy.accountHome
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        savedFolderError = nil
        do {
            try model.addSavedScanFolder(folder)
        } catch {
            savedFolderError = error.localizedDescription
        }
    }

    private func exportDiagnostics() {
        diagnosticsExportError = nil
        diagnosticsExported = false

        let panel = NSSavePanel()
        panel.title = "Export Mac Cleaner Diagnostics"
        panel.message = "Save a redacted report containing only app details, scan totals, and scan settings."
        panel.prompt = "Export"
        panel.nameFieldStringValue = "MacCleaner-Diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development Build"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let macOSVersion = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        #if arch(arm64)
        let architecture = "Apple silicon"
        #elseif arch(x86_64)
        let architecture = "Intel"
        #else
        let architecture = "Other"
        #endif
        let report = MacCleanerDiagnosticsExportService.makeReport(
            appVersion: version,
            appBuild: build,
            macOSVersion: macOSVersion,
            processorArchitecture: architecture,
            scanNoticeAccepted: model.scanNoticeAccepted,
            standardFoldersAccessible: model.standardFoldersAccessible,
            minimumFileSizeMB: Int(model.minimumSizeMB),
            olderFileThresholdDays: model.oldAgeDays,
            lastScan: model.currentResult
        )

        do {
            try MacCleanerDiagnosticsExportService.encode(report).write(to: destination, options: .atomic)
            diagnosticsExported = true
        } catch {
            diagnosticsExportError = "The report could not be saved. Choose a location with enough free space and try again."
        }
    }
}
