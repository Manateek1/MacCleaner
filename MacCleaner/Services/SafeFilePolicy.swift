import Darwin
import Foundation

enum SafetyAssessment: Equatable {
    case allowed(requiresExtraConfirmation: Bool)
    case protected(String)
}

enum SafeFilePolicy {
    private static let essentialSystemRoots = [
        "/System", "/bin", "/sbin", "/usr", "/etc", "/var/db", "/var/run",
        "/var/log", "/var/vm", "/private/etc", "/private/var/db", "/private/var/run",
        "/private/var/log", "/private/var/vm", "/Library", "/Applications", "/opt"
    ]
    private static let protectedSystemRoots: Set<String> = ["/var", "/private/var"]

    private static let protectedComponents: Set<String> = [
        ".git", ".hg", ".svn", ".ssh", ".gnupg", ".aws", ".azure", ".kube",
        ".codex", ".claude", ".cursor", ".gemini", ".vscode", ".config", "projects",
        "keychains", "credentials", "passwords", "cookies", "settings", "webkit", "safari", "chrome", "firefox", "mozilla",
        "messages", "mail", "application support", "preferences", "saved application state",
        "containers", "group containers", "conversations", "history", "sessions",
        "memory", "models", "model", "weights", "auth", "tokens", ".trash", "trash",
        "cloudstorage", "mobile documents", "com.apple.clouddocs", "icloud drive",
        "dropbox", "onedrive", "google drive",
        "node_modules", ".venv", "venv", ".build", ".swiftpm", ".gradle",
        ".rustup", ".cargo", ".nvm", ".pyenv", ".sdkman", ".conda"
    ]

    private static let protectedFileExtensions: Set<String> = ["pem", "key", "p12", "pfx", "mobileprovision"]
    private static let protectedFileNames: Set<String> = [
        "id_rsa", "id_ed25519", "id_ecdsa", "authorized_keys", "known_hosts",
        "login.keychain-db", "secrets.json", "credentials.json"
    ]
    private static let aiToolNames = ["codex", "openai", "claude", "anthropic", "cursor", "copilot", "gemini", "ollama", "lm studio", "lm-studio"]
    private static let cacheNames: Set<String> = ["cache", "caches", "code cache", "gpu cache", "crashpad", "crash reports", "logs", "deriveddata"]
    private static let personalFolders: Set<String> = ["desktop", "documents", "downloads", "pictures", "movies", "music"]

    static func isInside(_ candidatePath: String, root rootPath: String) -> Bool {
        let candidate = URL(fileURLWithPath: candidatePath).standardizedFileURL.path
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        if candidate == root { return false }
        let prefix = root == "/" ? "/" : root + "/"
        return candidate.hasPrefix(prefix)
    }

    static func containsProtectedPathComponent(_ path: String) -> Bool {
        containsProtectedPathComponent(path, allowingComponents: [])
    }

    static func containsProtectedModelInventoryPathComponent(_ path: String) -> Bool {
        containsProtectedPathComponent(path, allowingComponents: ["model", "models", "weights"])
    }

    static func shouldSkipModelInventoryDirectory(_ path: String, homeDirectory: URL = accountHome) -> Bool {
        if containsProtectedModelInventoryPathComponent(path) { return true }
        let personalDocumentsPath = homeDirectory.appendingPathComponent("Documents", isDirectory: true).standardizedFileURL.path
        return URL(fileURLWithPath: path).standardizedFileURL.path != personalDocumentsPath
            && containsVersionControlMetadata(in: path)
    }

    private static func containsProtectedPathComponent(_ path: String, allowingComponents: Set<String>) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents.map { $0.lowercased() }
        let containsSimulatorDeviceData = components.indices.dropLast().contains { index in
            components[index] == "coresimulator" && components[index + 1] == "devices"
        }
        if containsSimulatorDeviceData { return true }
        if components.contains(where: { protectedComponents.contains($0) && !allowingComponents.contains($0) }) { return true }
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        return protectedFileNames.contains(name) || protectedFileExtensions.contains(fileExtension) || name == ".env" || name.hasPrefix(".env.")
    }

    static var accountHome: URL {
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    static func isOtherUserAccountPath(_ path: String, homeDirectory: URL = accountHome) -> Bool {
        let homeComponents = homeDirectory.standardizedFileURL.pathComponents
        let candidateComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard let usersIndex = homeComponents.lastIndex(of: "Users"),
              usersIndex + 1 < homeComponents.count,
              usersIndex + 1 < candidateComponents.count,
              Array(candidateComponents.prefix(usersIndex + 1)) == Array(homeComponents.prefix(usersIndex + 1)) else {
            return false
        }

        let currentAccount = homeComponents[usersIndex + 1]
        let candidateAccount = candidateComponents[usersIndex + 1]
        return candidateAccount.caseInsensitiveCompare("Shared") != .orderedSame
            && candidateAccount.caseInsensitiveCompare(currentAccount) != .orderedSame
    }

    static func isInsideCurrentAccountLibrary(_ path: String, homeDirectory: URL = accountHome) -> Bool {
        let libraryPath = homeDirectory.appendingPathComponent("Library", isDirectory: true).standardizedFileURL.path
        let candidatePath = URL(fileURLWithPath: path).standardizedFileURL.path
        return candidatePath == libraryPath || isInside(candidatePath, root: libraryPath)
    }

    static func isReadOnlyCurrentAccountLibraryItem(
        path: String,
        categories: [FindingCategory],
        homeDirectory: URL = accountHome
    ) -> Bool {
        guard isInsideCurrentAccountLibrary(path, homeDirectory: homeDirectory) else { return false }
        let supportedCategories: Set<FindingCategory> = [.largeFile, .oldFile, .cacheCandidate, .aiCacheCandidate]
        guard !categories.isEmpty, categories.allSatisfy(supportedCategories.contains) else { return true }

        let recognizedCache = categories.contains(.cacheCandidate)
            && isCacheOrLogCandidate(path, homeDirectory: homeDirectory)
        let recognizedAICache = categories.contains(.aiCacheCandidate) && isAIAppCacheCandidate(path)
        return !recognizedCache && !recognizedAICache
    }

    static func shouldSkipDirectory(_ path: String, homeDirectory: URL = accountHome) -> Bool {
        if containsProtectedPathComponent(path) { return true }
        let personalDocumentsPath = homeDirectory.appendingPathComponent("Documents", isDirectory: true).standardizedFileURL.path
        return URL(fileURLWithPath: path).standardizedFileURL.path != personalDocumentsPath
            && containsVersionControlMetadata(in: path)
    }

    static func isEssentialSystemLocation(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if protectedSystemRoots.contains(standardized) { return true }
        return essentialSystemRoots.contains { root in
            standardized == root || standardized.hasPrefix(root + "/")
        }
    }

    static func containsVersionControlMetadata(in directoryPath: String) -> Bool {
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true).standardizedFileURL.path
        for marker in [".git", ".hg", ".svn"] {
            let metadataPath = directory == "/" ? "/\(marker)" : "\(directory)/\(marker)"
            var metadataInfo = Darwin.stat()
            if metadataPath.withCString({ Darwin.lstat($0, &metadataInfo) }) == 0 {
                return true
            }
        }
        return false
    }

    static func isInsideDevelopmentRepository(_ path: String, homeDirectory: URL = accountHome) -> Bool {
        let personalDocumentsPath = homeDirectory.appendingPathComponent("Documents", isDirectory: true).standardizedFileURL.path
        var directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        // Bound the walk so an unexpected parent URL can never loop forever.
        let maximumAncestors = directory.pathComponents.count + 1
        for _ in 0..<maximumAncestors {
            if directory.path != personalDocumentsPath && containsVersionControlMetadata(in: directory.path) { return true }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return false }
            directory = parent
        }
        return false
    }

    static func isCacheOrLogCandidate(_ path: String, homeDirectory: URL = accountHome) -> Bool {
        cacheReviewDetails(for: path, homeDirectory: homeDirectory) != nil
            || URL(fileURLWithPath: path).standardizedFileURL.pathComponents
                .map { $0.lowercased() }
                .contains(where: cacheNames.contains)
    }

    static func cacheReviewDetails(for path: String, homeDirectory: URL = accountHome) -> CacheReviewDetails? {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = homeDirectory.standardizedFileURL
        let profiles: [(URL, CacheReviewDetails)] = [
            (
                home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true),
                CacheReviewDetails(
                    sourceApplication: "Xcode",
                    summary: "Xcode keeps temporary build products here so it can build projects faster. Your project files stay in place, but a later build may take longer.",
                    consequence: "Your projects and source files stay in place. Xcode may need to rebuild these temporary products, which can make the next build take longer.",
                    reason: "Identified as Xcode's Derived Data build folder, which stores generated build products and related working files."
                )
            ),
            (
                home.appendingPathComponent("Library/Developer/CoreSimulator/Caches", isDirectory: true),
                CacheReviewDetails(
                    sourceApplication: "Simulator",
                    summary: "Simulator keeps temporary working files here to speed up app tests. Your virtual devices and their data stay in place, but a future simulator run may take longer.",
                    consequence: "This does not remove virtual devices or the data saved inside them. Simulator can rebuild these cache files, and a later test run may take longer.",
                    reason: "Identified as the local cache folder used by Apple's Simulator tools."
                )
            ),
            (
                home.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true),
                CacheReviewDetails(
                    sourceApplication: "Homebrew",
                    summary: "Homebrew keeps downloaded packages here so it can reuse them. Installed apps stay in place, but a future install may need to download packages again.",
                    consequence: "Installed Homebrew apps are not removed. A future install or upgrade may need to download package files again.",
                    reason: "Identified as Homebrew's download cache."
                )
            ),
            (
                home.appendingPathComponent("Library/Caches/pip", isDirectory: true),
                CacheReviewDetails(
                    sourceApplication: "pip",
                    summary: "pip keeps downloaded packages and built wheels here to speed up Python installs. Removing them can make a future install take longer.",
                    consequence: "Python projects and installed packages stay in place. pip may need to download packages or rebuild cached wheels again.",
                    reason: "Identified as pip's default macOS package cache folder."
                )
            ),
            (
                home.appendingPathComponent(".npm/_cacache", isDirectory: true),
                CacheReviewDetails(
                    sourceApplication: "npm",
                    summary: "npm keeps verified package download data here so future installs can reuse it. Project files and installed dependencies stay in place, but npm may need to fetch package data again.",
                    consequence: "Project files and installed dependencies are not removed. npm may download package data again, so a future install can take longer.",
                    reason: "Identified as npm's verified content cache inside its default cache folder."
                )
            )
        ]

        return profiles.first { root, _ in
            let rootPath = root.standardizedFileURL.path
            return candidate == rootPath || isInside(candidate, root: rootPath)
        }?.1
    }

    static func isAIAppCacheCandidate(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents.map { $0.lowercased() }
        guard components.contains(where: { component in aiToolNames.contains(where: component.contains) }) else { return false }
        guard components.contains(where: cacheNames.contains) else { return false }
        return !components.contains(where: protectedComponents.contains)
    }

    static func requiresExtraConfirmation(path: String, categories: [FindingCategory]) -> Bool {
        let lowRiskOnly = categories.allSatisfy { $0 == .cacheCandidate || $0 == .aiCacheCandidate }
        let isPersonal = URL(fileURLWithPath: path).pathComponents.map { $0.lowercased() }.contains(where: personalFolders.contains)
        return !lowRiskOnly || isPersonal
    }

    static func assess(
        _ item: ScanItem,
        inside rootURL: URL,
        homeDirectory: URL = accountHome,
        localVolumeCheck: @Sendable (URL) -> Bool = { SafeFilePolicy.isLocalVolume($0) }
    ) -> SafetyAssessment {
        let requestedRoot = rootURL.standardizedFileURL.path
        let root = SafeFileAccess.canonicalDirectoryPath(requestedRoot) ?? requestedRoot
        let path = URL(fileURLWithPath: item.path).standardizedFileURL.path
        guard isInside(path, root: root) else { return .protected("The item is outside the folder selected for this scan.") }
        guard localVolumeCheck(URL(fileURLWithPath: path)) else {
            return .protected("Files on network volumes are outside the local scan and cleanup scope.")
        }
        guard item.isCloudManaged != true else {
            return .protected("This iCloud Drive item is view-only because moving it could sync the change to your other devices.")
        }
        guard !isOtherUserAccountPath(path, homeDirectory: homeDirectory) else {
            return .protected("Files in another local account are view-only and cannot be moved to Trash from this account.")
        }
        guard !isEssentialSystemLocation(path) else { return .protected("Essential macOS locations cannot be cleaned.") }
        guard !containsProtectedPathComponent(path) else { return .protected("This path may contain credentials, personal history, or development data.") }
        guard !isReadOnlyCurrentAccountLibraryItem(
            path: path,
            categories: item.categories,
            homeDirectory: homeDirectory
        ) else {
            return .protected("App Library files can contain settings or state the app needs, so this item stays read-only.")
        }
        guard !isInsideDevelopmentRepository(path) else { return .protected("Files inside development repositories are protected.") }
        guard hasNoSymlinkedParent(path: path, root: root) else { return .protected("The path contains a symbolic link or changed since scanning.") }
        guard let current = identity(at: path) else { return .protected("The item is no longer a regular file.") }
        guard current == item.identity else { return .protected("The file changed since scanning. Scan again before cleanup.") }
        guard current.linkCount == 1 else { return .protected("This file has hard links, so recoverable space cannot be estimated safely.") }
        return .allowed(requiresExtraConfirmation: requiresExtraConfirmation(path: path, categories: item.categories))
    }

    static func isLocalVolume(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]) else { return false }
        return values.volumeIsLocal == true
    }

    static func hasCurrentDuplicateSurvivor(
        groupID: String,
        candidates: [ScanItem],
        selectedPaths: Set<String>,
        inside rootURL: URL
    ) -> Bool {
        candidates.contains { candidate in
            guard candidate.duplicateGroupID == groupID,
                  !selectedPaths.contains(candidate.path) else { return false }
            if case .allowed = assess(candidate, inside: rootURL) { return true }
            return false
        }
    }

    static func hasNoSymlinkedParent(path: String, root: String) -> Bool {
        var rootInfo = Darwin.stat()
        let rootResult = root.withCString { Darwin.lstat($0, &rootInfo) }
        guard rootResult == 0, rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return false }

        let relative = String(path.dropFirst(root == "/" ? 1 : root.count + 1))
        var current = URL(fileURLWithPath: root, isDirectory: true)
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component))
            var info = Darwin.stat()
            let result = current.path.withCString { Darwin.lstat($0, &info) }
            guard result == 0, info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else { return false }
            if current.path != path && info.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) { return false }
        }
        return true
    }

    private static func identity(at path: String) -> FileIdentity? {
        SafeFileAccess.identity(at: path)
    }
}

enum ICloudDesktopPolicy {
    static func shouldInspectDesktop(for scanRoot: URL, scanEntireDisk: Bool, accountHome: URL) -> Bool {
        guard !scanEntireDisk else { return true }
        let desktop = accountHome.appendingPathComponent("Desktop", isDirectory: true).standardizedFileURL.path
        let root = scanRoot.standardizedFileURL.path
        return root == desktop
            || SafeFilePolicy.isInside(root, root: desktop)
            || SafeFilePolicy.isInside(desktop, root: root)
    }

    static func iCloudDesktopRoot(accountHome: URL) -> URL? {
        let desktop = accountHome.appendingPathComponent("Desktop", isDirectory: true).standardizedFileURL
        var info = Darwin.stat()
        guard desktop.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var isICloudDesktop = false
        coordinator.coordinate(
            readingItemAt: desktop,
            options: .immediatelyAvailableMetadataOnly,
            error: &coordinationError
        ) { coordinatedDesktop in
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isUbiquitousItemKey]
            if let values = try? coordinatedDesktop.resourceValues(forKeys: keys),
               values.isDirectory == true,
               values.isUbiquitousItem == true {
                isICloudDesktop = true
            }
        }
        return coordinationError == nil && isICloudDesktop ? desktop : nil
    }

    static func contains(_ candidate: URL, inside root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || SafeFilePolicy.isInside(candidatePath, root: rootPath)
    }

    static func isLocallyAvailable(
        isUbiquitous: Bool?,
        downloadStatus: URLUbiquitousItemDownloadingStatus?,
        isDownloading: Bool?
    ) -> Bool {
        guard let isUbiquitous else { return false }
        guard isUbiquitous else { return true }
        guard isDownloading != true else { return false }
        return downloadStatus == .current || downloadStatus == .downloaded
    }

    static func isCurrentLocalCopy(
        isUbiquitous: Bool?,
        downloadStatus: URLUbiquitousItemDownloadingStatus?,
        isDownloading: Bool?
    ) -> Bool {
        guard let isUbiquitous else { return false }
        guard isUbiquitous else { return true }
        return downloadStatus == .current && isDownloading != true
    }

    static func isAvailableForReadOnlyPreview(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        return isCurrentLocalCopy(
            isUbiquitous: values.isUbiquitousItem,
            downloadStatus: values.ubiquitousItemDownloadingStatus,
            isDownloading: values.ubiquitousItemIsDownloading
        )
    }
}

struct TrashFailure: Sendable {
    let path: String
    let reason: String
}

struct TrashResult: Sendable {
    let moved: [String]
    let failures: [TrashFailure]
    let bytesMoved: Int64
}

struct TrashService: Sendable {
    private let trashOperation: @Sendable (URL) throws -> URL?

    init(trashOperation: @escaping @Sendable (URL) throws -> URL? = { url in
        var resultingItemURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingItemURL)
        return resultingItemURL as URL?
    }) {
        self.trashOperation = trashOperation
    }

    func moveToTrash(_ items: [ScanItem], allCandidates: [ScanItem], inside rootURL: URL) -> TrashResult {
        var moved: [String] = []
        var failures: [TrashFailure] = []
        var bytes: Int64 = 0
        let grouped = Dictionary(grouping: allCandidates.compactMap { item -> (String, ScanItem)? in
            guard let id = item.duplicateGroupID else { return nil }
            return (id, item)
        }, by: { $0.0 })
        let selectedByGroup = Dictionary(grouping: items.compactMap { item -> String? in item.duplicateGroupID }, by: { $0 })

        for (groupID, selection) in selectedByGroup {
            let paths = Set(items.filter { $0.duplicateGroupID == groupID }.map(\.path))
            let hasSurvivor = SafeFilePolicy.hasCurrentDuplicateSurvivor(
                groupID: groupID,
                candidates: allCandidates,
                selectedPaths: paths,
                inside: rootURL
            )
            if selection.count >= (grouped[groupID]?.count ?? 0) || !hasSurvivor {
                for item in items where item.duplicateGroupID == groupID {
                    failures.append(TrashFailure(path: item.path, reason: "At least one unchanged, accessible copy from an exact duplicate group must remain."))
                }
            }
        }

        let blockedDuplicatePaths = Set(failures.map(\.path))
        for item in items where !blockedDuplicatePaths.contains(item.path) {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var moveFailure: String?
            var movedIdentityMatched = false
            coordinator.coordinate(writingItemAt: item.url, options: .forMoving, error: &coordinationError) { coordinatedURL in
                guard coordinatedURL.standardizedFileURL.path == item.path else {
                    moveFailure = "The file location changed while Mac Cleaner prepared it. Scan again before cleanup."
                    return
                }
                switch SafeFilePolicy.assess(item, inside: rootURL) {
                case .protected(let reason):
                    moveFailure = reason
                case .allowed:
                    do {
                        guard let trashedURL = try trashOperation(coordinatedURL) else {
                            moveFailure = "Mac Cleaner could not verify the item it moved to Trash. Check Trash before continuing."
                            return
                        }
                        guard SafeFileAccess.identity(at: trashedURL.path) == item.identity else {
                            moveFailure = "The file changed while Mac Cleaner prepared it. Check Trash and restore anything you did not mean to move."
                            return
                        }
                        movedIdentityMatched = true
                    } catch {
                        moveFailure = error.localizedDescription
                    }
                }
            }
            if let coordinationError {
                failures.append(TrashFailure(path: item.path, reason: coordinationError.localizedDescription))
            } else if movedIdentityMatched {
                moved.append(item.path)
                bytes += item.size
            } else {
                failures.append(TrashFailure(path: item.path, reason: moveFailure ?? "Mac Cleaner could not verify the file before moving it."))
            }
        }
        return TrashResult(moved: moved, failures: failures, bytesMoved: bytes)
    }
}
