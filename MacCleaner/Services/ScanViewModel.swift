import AppKit
import Combine
import Foundation

@MainActor
final class ScanViewModel: ObservableObject {
    @Published private(set) var currentResult: ScanResult?
    @Published private(set) var progress = ScanProgress(stage: "Ready to scan", filesVisited: 0, bytesVisited: 0)
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var isPreparingFirstScan = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastTrashResult: TrashResult?
    @Published private(set) var storage = StorageSnapshot.current()
    @Published private(set) var standardFoldersAccessible = false
    @Published private(set) var standardFoldersChecked = false
    @Published private(set) var iCloudDesktopAccessSaved = false
    @Published private(set) var iCloudDesktopAccessStatus: String?
    @Published private(set) var excludedScanPaths: [String]
    @Published private(set) var savedScanFolders: [SavedScanFolder]
    @Published private(set) var scanNoticeAccepted: Bool
    @Published private(set) var scanSetupRequested = false
    @Published private(set) var hasSavedFullDiskReview = false
    @Published private(set) var scanResultPersistenceMessage: String?
    @Published private(set) var appSecurityReport: ApplicationSecurityAuditReport?
    @Published private(set) var appSecurityCheckedAt: Date?
    @Published private var duplicateKeeperChoices: [String: String] = [:]
    @Published var selectedPaths: Set<String> = []
    @Published var minimumSizeMB: Double = UserDefaults.standard.object(forKey: "MacCleaner.minimumSizeMB") as? Double ?? 500 {
        didSet { UserDefaults.standard.set(minimumSizeMB, forKey: "MacCleaner.minimumSizeMB") }
    }
    @Published var oldAgeDays: Int = UserDefaults.standard.object(forKey: "MacCleaner.oldAgeDays") as? Int ?? 180 {
        didSet { UserDefaults.standard.set(oldAgeDays, forKey: "MacCleaner.oldAgeDays") }
    }
    @Published var duplicateKeepPreference: DuplicateKeepPreference = {
        guard let rawValue = UserDefaults.standard.string(forKey: DuplicateKeepPreference.storageKey),
              let preference = DuplicateKeepPreference(rawValue: rawValue) else { return .oldest }
        return preference
    }() {
        didSet { UserDefaults.standard.set(duplicateKeepPreference.rawValue, forKey: DuplicateKeepPreference.storageKey) }
    }
    @Published var trashConfirmationPresented = false

    let activity = ActivityStore()
    private let scanner: any ScanServicing
    private let scanNoticeStore: ScanAccessAcknowledgementStore
    private let scanExclusionStore: ScanExclusionStore
    private let savedScanFolderStore: SavedScanFolderStore
    private let scanResultStore: ScanResultStore
    private let iCloudDesktopBookmarkStore: ICloudDesktopBookmarkStore
    private let fullDiskAccessProbe: @Sendable () -> Bool
    private var scanTask: Task<Void, Never>?
    private var selectedRoot: URL?
    private var folderAccess: ScopedFolderAccess?
    private var iCloudDesktopAccess: ScopedFolderAccess?
    private var diskAccessProbeInFlight = false
    private var appSecurityReviewID: UUID?

    init(
        scanNoticeStore: ScanAccessAcknowledgementStore = ScanAccessAcknowledgementStore(),
        scanExclusionStore: ScanExclusionStore = ScanExclusionStore(),
        savedScanFolderStore: SavedScanFolderStore = SavedScanFolderStore(),
        scanResultStore: ScanResultStore = ScanResultStore(),
        iCloudDesktopBookmarkStore: ICloudDesktopBookmarkStore = ICloudDesktopBookmarkStore(),
        fullDiskAccessProbe: @escaping @Sendable () -> Bool = { FullDiskAccessProbe.hasAccess() },
        scanner: any ScanServicing = FileScanner()
    ) {
        self.scanNoticeStore = scanNoticeStore
        self.scanExclusionStore = scanExclusionStore
        self.savedScanFolderStore = savedScanFolderStore
        self.scanResultStore = scanResultStore
        self.iCloudDesktopBookmarkStore = iCloudDesktopBookmarkStore
        self.fullDiskAccessProbe = fullDiskAccessProbe
        self.scanner = scanner
        scanNoticeAccepted = scanNoticeStore.hasAccepted
        standardFoldersAccessible = false
        iCloudDesktopAccessSaved = iCloudDesktopBookmarkStore.hasBookmark
        excludedScanPaths = scanExclusionStore.paths
        savedScanFolders = savedScanFolderStore.folders
        do {
            if let result = try scanResultStore.load() {
                currentResult = result
                hasSavedFullDiskReview = true
                progress = ScanProgress(
                    stage: "Saved full-disk review ready",
                    filesVisited: result.filesVisited,
                    bytesVisited: result.bytesVisited,
                    entriesVisited: result.entriesVisited
                )
                if standardFoldersAccessible { selectedRoot = URL(fileURLWithPath: "/", isDirectory: true) }
            }
        } catch {
            hasSavedFullDiskReview = scanResultStore.hasSavedResult
            scanResultPersistenceMessage = "Mac Cleaner couldn’t reopen the saved review. Run a new full-disk scan, or clear the saved review in Settings."
        }
    }

    var selectedItems: [ScanItem] {
        guard !selectedPaths.isEmpty else { return [] }
        return currentResult?.items.filter { selectedPaths.contains($0.path) } ?? []
    }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var selectedNeedsExtraConfirmation: Bool {
        guard let root = selectedRoot else { return false }
        return selectedItems.contains { item in
            switch SafeFilePolicy.assess(item, inside: root) {
            case .allowed(let extra): extra
            case .protected: true
            }
        }
    }

    func chooseFolder(for kind: ScanKind) {
        let panel = NSOpenPanel()
        panel.title = "Choose a specific folder to scan"
        panel.message = "Mac Cleaner scans only this folder. Scanning is read-only."
        panel.prompt = "Scan Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.resolvesAliases = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = SafeFilePolicy.accountHome
        guard panel.runModal() == .OK else { return }
        guard let url = panel.url else {
            errorMessage = "No folder was selected. Select a folder and click Scan Folder."
            return
        }
        startScan(at: url, kind: kind)
    }

    func scanDisk(for kind: ScanKind) {
        guard !isScanning, !isCleaning else { return }
        guard scanNoticeAccepted else {
            scanSetupRequested = true
            return
        }
        if standardFoldersChecked && !standardFoldersAccessible {
            errorMessage = "Mac Cleaner couldn't open Documents and Downloads. Turn on Mac Cleaner in System Settings → Privacy & Security → Full Disk Access, then return and try again."
            openFullDiskAccessSettings()
            return
        }
        prepareICloudDesktopAccessForDiskScan()
        startScan(at: URL(fileURLWithPath: "/", isDirectory: true), kind: kind)
    }

    func refreshDiskAccessStatusInBackground() {
        guard scanNoticeAccepted, !isScanning, !diskAccessProbeInFlight else { return }
        diskAccessProbeInFlight = true
        let probe = fullDiskAccessProbe
        Task { [weak self] in
            let accessible = await Task.detached(priority: .utility) { probe() }.value
            guard let self else { return }
            self.diskAccessProbeInFlight = false
            guard self.scanNoticeAccepted else { return }
            self.standardFoldersAccessible = accessible
            self.standardFoldersChecked = true
            if self.currentResult?.rootPath == "/" {
                self.selectedRoot = accessible ? URL(fileURLWithPath: "/", isDirectory: true) : nil
            }
        }
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    func requestICloudDesktopAccess() {
        guard !isScanning, !isCleaning else { return }
        let desktopRoot = SafeFilePolicy.accountHome.appendingPathComponent("Desktop", isDirectory: true)
        iCloudDesktopBookmarkStore.markAccessRequested()
        showICloudDesktopAccessPanel(for: desktopRoot)
    }

    func forgetICloudDesktopAccess() {
        guard !isScanning, !isCleaning else { return }
        iCloudDesktopAccess?.stop()
        iCloudDesktopAccess = nil
        iCloudDesktopBookmarkStore.remove()
        iCloudDesktopAccessSaved = false
        iCloudDesktopAccessStatus = "iCloud Desktop access was forgotten. Its files will stay out of future scans until you allow access again."
    }

    func addScanExclusion(_ folderURL: URL) throws {
        excludedScanPaths = try scanExclusionStore.add(folderURL)
    }

    func removeScanExclusion(_ path: String) {
        excludedScanPaths = scanExclusionStore.remove(path)
    }

    func addSavedScanFolder(_ folderURL: URL) throws {
        savedScanFolders = try savedScanFolderStore.add(folderURL)
    }

    func removeSavedScanFolder(_ path: String) {
        savedScanFolders = savedScanFolderStore.remove(path)
    }

    func scanSavedFolder(_ path: String) {
        guard !isScanning, !isCleaning else { return }
        do {
            guard let resolution = try savedScanFolderStore.resolve(path) else {
                errorMessage = "That saved folder is no longer available. Remove it and add the folder again."
                return
            }
            startScan(at: resolution.url, kind: .smart)
            guard isScanning, resolution.isStale else { return }
            do {
                savedScanFolders = try savedScanFolderStore.refresh(path, with: resolution.url)
            } catch {
                errorMessage = "The scan started, but Mac Cleaner could not refresh the saved folder access. Remove and add the shortcut again after the scan."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearScanSetupRequest() {
        scanSetupRequested = false
    }

    func acceptScanNoticeAndStart(includePhotosAccess: Bool, onScanStarted: @escaping () -> Void) {
        guard !isPreparingFirstScan else { return }
        scanNoticeStore.accept()
        scanNoticeAccepted = true
        scanSetupRequested = false
        isPreparingFirstScan = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isPreparingFirstScan = false }
            if FirstRunPermissionPolicy.shouldRequestPhotosAccess(
                includePhotos: includePhotosAccess,
                currentState: PhotoLibraryAccess.currentAuthorization
            ) {
                _ = await PhotoLibraryAccess.requestAuthorization()
            }
            self.scanDisk(for: .smart)
            if self.isScanning { onScanStarted() }
        }
    }

    func borrowDiskAccess() -> URL? {
        guard scanNoticeAccepted else { return nil }
        if !isScanning { refreshDiskAccessStatusInBackground() }
        guard !standardFoldersChecked || standardFoldersAccessible else { return nil }
        return URL(fileURLWithPath: "/", isDirectory: true)
    }

    func startScan(at folder: URL, kind: ScanKind) {
        guard !isScanning, !isCleaning else { return }
        if folderAccess?.url.standardizedFileURL.path != folder.standardizedFileURL.path {
            folderAccess?.stop()
            folderAccess = folder.standardizedFileURL.path == "/" ? nil : ScopedFolderAccess(url: folder)
        }
        selectedRoot = folder
        if folder.standardizedFileURL.path != "/" {
            iCloudDesktopAccess?.stop()
            iCloudDesktopAccess = nil
        }
        scanTask?.cancel()
        errorMessage = nil
        currentResult = nil
        lastTrashResult = nil
        if SmartScanSecurityReviewPolicy.shouldRunAppSecurity(kind: kind, root: folder) {
            appSecurityReport = nil
            appSecurityCheckedAt = nil
        }
        duplicateKeeperChoices.removeAll()
        selectedPaths.removeAll()
        isScanning = true
        progress = ScanProgress(stage: "Starting scan", filesVisited: 0, bytesVisited: 0)
        let request = ScanRequest(
            root: folder,
            kind: kind,
            minimumFileSizeBytes: Int64(max(1, minimumSizeMB) * 1_000_000),
            oldFileAgeDays: max(1, oldAgeDays),
            scanEntireDisk: folder.standardizedFileURL.path == "/",
            excludedPaths: Set(excludedScanPaths),
            duplicateKeepPreference: duplicateKeepPreference
        )
        scanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isScanning = false
                scanTask = nil
            }
            do {
                let result = try await scanner.scan(request) { [weak self] update in
                    Task { @MainActor [weak self] in
                        self?.progress = update
                    }
                }
                currentResult = result
                selectedRoot = folder
                if result.cloudDesktopAccessUnavailable == true {
                    iCloudDesktopAccessStatus = "macOS still hasn't opened iCloud Desktop. Allow Desktop Access once in Settings, then scan again."
                } else if let count = result.cloudFilesLocallyAvailable {
                    iCloudDesktopAccessStatus = "Checked \(count.formatted()) local iCloud Desktop files as read-only."
                }
                if result.rootPath == "/" {
                    await persistFullDiskReview(result)
                }
                storage = StorageSnapshot.current()
                if SmartScanSecurityReviewPolicy.shouldRunAppSecurity(kind: kind, root: folder) {
                    await runAppSecurityReview(after: result)
                }
                activity.record(
                    title: "\(kind.title) completed",
                    files: result.items.count,
                    bytes: result.items.reduce(0) { $0 + $1.size },
                    note: "\(result.filesVisited) files inspected; \(result.skippedItems) items could not be read; \(result.excludedLocations.count) excluded folders applied.",
                    kind: .scan
                )
                await ActivityNotificationService.shared.notifyIfEnabled(.scanCompleted)
            } catch is CancellationError {
                progress = ScanProgress(stage: "Scan cancelled", filesVisited: progress.filesVisited, bytesVisited: progress.bytesVisited)
                selectedRoot = nil
                folderAccess?.stop()
                folderAccess = nil
                iCloudDesktopAccess?.stop()
                iCloudDesktopAccess = nil
            } catch {
                errorMessage = error.localizedDescription
                progress = ScanProgress(stage: "Scan failed", filesVisited: progress.filesVisited, bytesVisited: progress.bytesVisited)
                selectedRoot = nil
                folderAccess?.stop()
                folderAccess = nil
                iCloudDesktopAccess?.stop()
                iCloudDesktopAccess = nil
            }
        }
    }

    func cacheAppSecurityReport(_ report: ApplicationSecurityAuditReport, checkedAt: Date = .now) {
        appSecurityReport = report
        appSecurityCheckedAt = checkedAt
    }

    private func runAppSecurityReview(after scanResult: ScanResult) async {
        let reviewID = UUID()
        appSecurityReviewID = reviewID
        progress = ScanProgress(
            stage: "Preparing app signature and startup review",
            filesVisited: scanResult.filesVisited,
            bytesVisited: scanResult.bytesVisited,
            entriesVisited: scanResult.entriesVisited
        )

        let progressHandler: @Sendable (ApplicationSecurityAuditProgress) -> Void = { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isScanning,
                      self.appSecurityReviewID == reviewID else { return }
                let stage: String
                switch update.phase {
                case .applications:
                    stage = "Verifying \(update.applicationName) · \(update.completed.formatted()) of \(update.total.formatted()) apps"
                case .startupDefinitions:
                    stage = "Reviewing startup items · \(update.completed.formatted()) of \(update.total.formatted()) locations"
                }
                self.progress = ScanProgress(
                    stage: stage,
                    filesVisited: scanResult.filesVisited,
                    bytesVisited: scanResult.bytesVisited,
                    entriesVisited: scanResult.entriesVisited
                )
            }
        }
        let auditTask = Task.detached(priority: .utility) {
            ApplicationSecurityAuditService().scan(
                roots: ApplicationSecurityAuditService.standardApplicationRoots,
                startupLocations: ApplicationSecurityAuditService.standardStartupLocations(),
                isCancelled: { Task.isCancelled },
                progress: progressHandler
            )
        }
        let report = await withTaskCancellationHandler {
            await auditTask.value
        } onCancel: {
            auditTask.cancel()
        }

        appSecurityReviewID = nil
        cacheAppSecurityReport(report)
        progress = ScanProgress(
            stage: report.wasCancelled ? "App Security review stopped · file results are ready" : "App Security review complete",
            filesVisited: scanResult.filesVisited,
            bytesVisited: scanResult.bytesVisited,
            entriesVisited: scanResult.entriesVisited
        )
        let summary = ApplicationSecurityActivitySummary(report: report)
        activity.record(title: summary.title, files: summary.checkedApps, bytes: 0, note: summary.note, kind: .securityCheck)
    }

    private func prepareICloudDesktopAccessForDiskScan() {
        let desktopRoot = SafeFilePolicy.accountHome.appendingPathComponent("Desktop", isDirectory: true)
        if activateSavedICloudDesktopAccess(for: desktopRoot) { return }
        if iCloudDesktopBookmarkStore.hasAskedForAccess {
            iCloudDesktopAccessStatus = "Saved Desktop access isn't available. The scan will check local files it can read; use Allow Desktop Access in Settings if Desktop is missing from the results."
        } else {
            iCloudDesktopAccessStatus = nil
        }
    }

    private func activateSavedICloudDesktopAccess(for expectedRoot: URL) -> Bool {
        if iCloudDesktopAccess?.accessStarted == true { return true }
        guard let savedURL = try? iCloudDesktopBookmarkStore.resolve(),
              Self.sameResolvedLocation(savedURL, expectedRoot) else { return false }
        let access = ScopedFolderAccess(url: savedURL)
        iCloudDesktopAccess?.stop()
        iCloudDesktopAccess = access
        iCloudDesktopAccessSaved = iCloudDesktopBookmarkStore.hasBookmark
        iCloudDesktopAccessStatus = "Read-only Desktop access is saved."
        return true
    }

    private func showICloudDesktopAccessPanel(for expectedRoot: URL) {
        let panel = NSOpenPanel()
        panel.title = "Allow read-only access to Desktop"
        panel.message = "Choose Desktop once so Mac Cleaner can check files already stored on this Mac. Cloud-only items are not downloaded, and Desktop results stay read-only."
        panel.prompt = "Allow Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.resolvesAliases = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = expectedRoot.deletingLastPathComponent()
        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            iCloudDesktopAccessStatus = "Desktop access wasn't granted. The rest of the Mac can still be scanned; use Allow Desktop Access in Settings to try again."
            return
        }
        guard Self.sameResolvedLocation(selectedURL, expectedRoot) else {
            iCloudDesktopAccessStatus = "Select the Desktop folder to include its local files in a full Mac scan."
            return
        }

        let access = ScopedFolderAccess(url: selectedURL)
        iCloudDesktopAccess?.stop()
        iCloudDesktopAccess = access.accessStarted ? access : nil
        do {
            try iCloudDesktopBookmarkStore.save(selectedURL)
            iCloudDesktopAccessSaved = true
            iCloudDesktopAccessStatus = "Read-only Desktop access is saved. Scans include local copies and report any locations macOS blocks."
        } catch {
            iCloudDesktopAccessSaved = access.accessStarted
            iCloudDesktopAccessStatus = access.accessStarted
                ? "Desktop access works for this session, but macOS couldn't save it for future scans."
                : "The folder was selected, but macOS couldn't save the access permission. The scan will report any Desktop locations it can't read."
        }
    }

    private static func sameResolvedLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    func closeReview() {
        guard !isScanning, !isCleaning else { return }
        currentResult = nil
        selectedRoot = nil
        duplicateKeeperChoices.removeAll()
        selectedPaths.removeAll()
        folderAccess?.stop()
        folderAccess = nil
        iCloudDesktopAccess?.stop()
        iCloudDesktopAccess = nil
        progress = ScanProgress(stage: "Ready to scan", filesVisited: 0, bytesVisited: 0)
    }

    func showNotice(_ message: String) {
        errorMessage = message
    }

    func forgetSavedFullDiskReview() {
        do {
            try scanResultStore.clear()
            hasSavedFullDiskReview = false
            scanResultPersistenceMessage = nil
            if currentResult?.rootPath == "/" {
                currentResult = nil
                selectedRoot = nil
                duplicateKeeperChoices.removeAll()
                selectedPaths.removeAll()
                folderAccess?.stop()
                folderAccess = nil
            }
        } catch {
            scanResultPersistenceMessage = "The saved review could not be cleared. \(error.localizedDescription)"
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    func toggleSelection(for item: ScanItem) {
        guard !isCleaning else { return }
        if selectedPaths.contains(item.path) {
            selectedPaths.remove(item.path)
            return
        }
        if duplicateKeeperPath(for: item) == item.path { return }
        guard let root = selectedRoot else { return }
        if case .protected(let reason) = SafeFilePolicy.assess(item, inside: root) {
            errorMessage = reason
            return
        }
        if let groupID = item.duplicateGroupID,
           let result = currentResult {
            let alreadySelected = result.items.filter { $0.duplicateGroupID == groupID && selectedPaths.contains($0.path) }.count
            guard alreadySelected < item.duplicateGroupCount - 1 else { return }
        }
        selectedPaths.insert(item.path)
    }

    func duplicateKeeperPath(for item: ScanItem) -> String? {
        guard let groupID = item.duplicateGroupID else { return nil }
        return duplicateKeeperChoices[groupID] ?? item.suggestedKeepPath
    }

    func isSuggestedDuplicateKeeper(for item: ScanItem) -> Bool {
        guard let groupID = item.duplicateGroupID else { return false }
        return duplicateKeeperChoices[groupID] == nil
    }

    func chooseDuplicateKeeper(for item: ScanItem) {
        guard !isCleaning,
              let groupID = item.duplicateGroupID,
              let root = selectedRoot,
              let result = currentResult else { return }
        let group = result.items.filter { $0.duplicateGroupID == groupID }
        guard group.count > 1, group.contains(where: { $0.path == item.path }) else { return }

        duplicateKeeperChoices[groupID] = item.path
        let eligiblePaths = Set(group.compactMap { candidate -> String? in
            if case .allowed = SafeFilePolicy.assess(candidate, inside: root) { return candidate.path }
            return nil
        })
        selectedPaths = DuplicateKeepSelection.selectingAlternatives(
            in: group,
            keepingPath: item.path,
            from: selectedPaths,
            eligiblePaths: eligiblePaths
        )
    }

    func selectAllEligible(from visibleItems: [ScanItem]? = nil) {
        guard !isCleaning, let result = currentResult, let root = selectedRoot else { return }
        let visiblePaths = Set((visibleItems ?? result.items).map(\.path))
        var selection = selectedPaths.subtracting(visiblePaths)
        for item in result.items where visiblePaths.contains(item.path) {
            guard item.categories.allSatisfy({ $0 == .cacheCandidate || $0 == .aiCacheCandidate }),
                  SafeFilePolicy.isInside(item.path, root: root.path),
                  !SafeFilePolicy.isEssentialSystemLocation(item.path),
                  !SafeFilePolicy.containsProtectedPathComponent(item.path),
                  !SafeFilePolicy.requiresExtraConfirmation(path: item.path, categories: item.categories),
                  item.duplicateGroupID == nil else { continue }
            selection.insert(item.path)
        }
        selectedPaths = selection
    }

    func clearSelection() {
        guard !isCleaning else { return }
        selectedPaths.removeAll()
    }

    func requestTrashSelected() {
        guard !isCleaning, !selectedItems.isEmpty else { return }
        trashConfirmationPresented = true
    }

    func moveSelectedToTrash() {
        guard !isCleaning, let root = selectedRoot else { return }
        let items = selectedItems
        guard !items.isEmpty else { return }
        let allCandidates = currentResult?.items ?? []
        isCleaning = true
        selectedPaths.removeAll()
        let service = TrashService()
        let operation = Task.detached(priority: .utility) {
            service.moveToTrash(items, allCandidates: allCandidates, inside: root)
        }
        Task { [weak self] in
            let result = await operation.value
            guard let self else { return }
            defer { self.isCleaning = false }
            self.lastTrashResult = result
            if let previous = self.currentResult {
                self.currentResult = previous.removingItems(at: Set(result.moved))
                if self.currentResult?.rootPath == "/", let updated = self.currentResult {
                    await self.persistFullDiskReview(updated)
                }
            }
            let summary = result.failures.isEmpty ? "Moved to Trash; nothing was permanently deleted." : "Some items could not be moved. Review the status for details."
            self.activity.record(title: "Cleanup reviewed", files: result.moved.count, bytes: result.bytesMoved, note: summary, kind: .cleanup)
            self.storage = StorageSnapshot.current()
            await ActivityNotificationService.shared.notifyIfEnabled(.cleanupCompleted)
        }
    }

    func refreshStorage() {
        storage = StorageSnapshot.current()
    }

    private func persistFullDiskReview(_ result: ScanResult) async {
        guard result.rootPath == "/" else { return }
        do {
            let store = scanResultStore
            try await Task.detached(priority: .utility) {
                try store.save(result)
            }.value
            hasSavedFullDiskReview = true
            scanResultPersistenceMessage = nil
        } catch {
            hasSavedFullDiskReview = scanResultStore.hasSavedResult
            scanResultPersistenceMessage = "This review is available until Mac Cleaner closes, but it couldn’t be saved for next time. \(error.localizedDescription)"
        }
    }
}

struct ScanAccessAcknowledgementStore {
    private let key = "MacCleaner.scanNoticeAcceptedVersion"
    private let currentVersion = 4
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasAccepted: Bool {
        defaults.integer(forKey: key) >= currentVersion
    }

    func accept() {
        defaults.set(currentVersion, forKey: key)
    }
}

struct ICloudDesktopBookmarkResolution {
    let url: URL
    let isStale: Bool
}

struct ICloudDesktopBookmarkStore {
    typealias BookmarkResolver = (Data) throws -> ICloudDesktopBookmarkResolution

    private let bookmarkKey = "MacCleaner.iCloudDesktopReadBookmark"
    private let askedKey = "MacCleaner.iCloudDesktopAccessAsked"
    private let defaults: UserDefaults
    private let createBookmark: (URL) throws -> Data
    private let resolveBookmark: BookmarkResolver

    init(
        defaults: UserDefaults = .standard,
        createBookmark: @escaping (URL) throws -> Data = { url in
            try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        resolveBookmark: @escaping BookmarkResolver = { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return ICloudDesktopBookmarkResolution(url: url, isStale: isStale)
        }
    ) {
        self.defaults = defaults
        self.createBookmark = createBookmark
        self.resolveBookmark = resolveBookmark
    }

    var hasBookmark: Bool {
        defaults.data(forKey: bookmarkKey) != nil
    }

    var hasAskedForAccess: Bool {
        defaults.bool(forKey: askedKey)
    }

    func markAccessRequested() {
        defaults.set(true, forKey: askedKey)
    }

    func save(_ url: URL) throws {
        defaults.set(try createBookmark(url), forKey: bookmarkKey)
    }

    func resolve() throws -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        let resolution = try resolveBookmark(data)
        if resolution.isStale { try save(resolution.url) }
        return resolution.url
    }

    func remove() {
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: askedKey)
    }
}

private final class ScopedFolderAccess {
    let url: URL
    private(set) var accessStarted: Bool

    init(url: URL, accessAlreadyStarted: Bool = false) {
        self.url = url
        accessStarted = accessAlreadyStarted || url.startAccessingSecurityScopedResource()
    }

    func stop() {
        guard accessStarted else { return }
        url.stopAccessingSecurityScopedResource()
        accessStarted = false
    }

    deinit {
        stop()
    }
}
