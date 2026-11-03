import Foundation

enum ApplicationUpdateSource: Sendable {
    case sparkleFeed(URL)
    case appStore
    case appleSoftwareUpdate
    case builtInUpdater
    case unsupportedFeed

    var title: String {
        switch self {
        case .sparkleFeed(let url): "Sparkle feed · \(url.host ?? "publisher")"
        case .appStore: "Mac App Store"
        case .appleSoftwareUpdate: "Apple Software Update"
        case .builtInUpdater: "No supported feed found"
        case .unsupportedFeed: "Feed not checked"
        }
    }
}

struct ApplicationUpdateTarget: Identifiable, Sendable {
    let application: InstalledApplication
    let buildVersion: String?
    let source: ApplicationUpdateSource

    var id: String { application.id }
}

struct ApplicationUpdateDiscoveryResult: Sendable {
    let targets: [ApplicationUpdateTarget]
    let inaccessibleLocations: Int
    let wasLimited: Bool
    let wasCancelled: Bool
}

enum ApplicationUpdateFeedOutcome: String, Codable, Sendable {
    case updateAdvertised
    case noNewerVersion
    case versionCouldNotBeCompared
}

struct ApplicationUpdateFeedResult: Codable, Sendable {
    let checkedAt: Date
    let sourceHost: String
    let installedBuildVersion: String?
    let advertisedBuildVersion: String?
    let advertisedDisplayVersion: String?
    let outcome: ApplicationUpdateFeedOutcome
}

struct ApplicationUpdateVersionChange: Equatable, Sendable {
    let previousBuildVersion: String
    let currentBuildVersion: String
}

enum ApplicationUpdateVersionTracker {
    static func change(
        from previousBuildVersion: String?,
        to currentBuildVersion: String?
    ) -> ApplicationUpdateVersionChange? {
        guard let previousBuildVersion,
              let currentBuildVersion,
              let comparison = ApplicationUpdaterService.compareVersions(previousBuildVersion, currentBuildVersion),
              comparison != 0 else { return nil }
        return ApplicationUpdateVersionChange(
            previousBuildVersion: previousBuildVersion,
            currentBuildVersion: currentBuildVersion
        )
    }
}

enum ApplicationUpdateError: LocalizedError {
    case insecureFeed
    case redirectedToAnotherHost
    case httpStatus(Int)
    case feedTooLarge
    case invalidFeed
    case noVersionInformation

    var errorDescription: String? {
        switch self {
        case .insecureFeed:
            "This app does not list a secure HTTPS update feed. Open its own updater instead."
        case .redirectedToAnotherHost:
            "The feed redirected to another website, so Mac Cleaner stopped the check. Open the app's own updater instead."
        case .httpStatus(let code):
            "The update feed returned an error (\(code)). Try the app's own updater."
        case .feedTooLarge:
            "The update feed is larger than Mac Cleaner can safely review. Open the app's own updater instead."
        case .invalidFeed:
            "The app's update source did not return a readable Sparkle feed. Open the app's own updater instead."
        case .noVersionInformation:
            "The feed did not include a version Mac Cleaner could compare. Open the app's own updater instead."
        }
    }
}

struct SparkleFeedItem: Equatable, Sendable {
    let buildVersion: String
    let displayVersion: String?
    let minimumSystemVersion: String?
}

struct SparkleAppcastParser: Sendable {
    func parse(_ data: Data) -> [SparkleFeedItem]? {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        return delegate.items.isEmpty ? nil : delegate.items
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        private(set) var items: [SparkleFeedItem] = []
        private var currentItem: [String: String]?
        private var captureKey: String?
        private var capturedText = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let name = qName?.isEmpty == false ? qName! : elementName
            if name == "item" {
                currentItem = [:]
                return
            }
            guard currentItem != nil else { return }

            if name == "enclosure" {
                for (key, value) in attributeDict {
                    switch normalizedName(key) {
                    case "version": currentItem?["version"] = value
                    case "shortversionstring": currentItem?["displayVersion"] = value
                    case "minimumsystemversion": currentItem?["minimumSystemVersion"] = value
                    default: break
                    }
                }
            }

            guard let key = textKey(for: name) else { return }
            captureKey = key
            capturedText = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard captureKey != nil else { return }
            capturedText += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let name = qName?.isEmpty == false ? qName! : elementName
            if let captureKey, textKey(for: name) == captureKey {
                let value = capturedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { currentItem?[captureKey] = value }
                self.captureKey = nil
                capturedText = ""
            }
            guard name == "item", let currentItem else { return }
            if let version = currentItem["version"] {
                items.append(SparkleFeedItem(
                    buildVersion: version,
                    displayVersion: currentItem["displayVersion"],
                    minimumSystemVersion: currentItem["minimumSystemVersion"]
                ))
            }
            self.currentItem = nil
        }

        private func textKey(for name: String) -> String? {
            switch normalizedName(name) {
            case "version": "version"
            case "shortversionstring": "displayVersion"
            case "minimumsystemversion": "minimumSystemVersion"
            default: nil
            }
        }

        private func normalizedName(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
        }
    }
}

struct ApplicationUpdaterService: Sendable {
    private static let maximumFeedBytes = 1_000_000

    func discover(
        roots: [URL],
        maximumVisitedEntries: Int = 250_000,
        maximumApplications: Int = 20_000,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> ApplicationUpdateDiscoveryResult {
        let inventory = ApplicationInventory().scan(
            roots: roots,
            includeSizes: false,
            maximumVisitedEntries: maximumVisitedEntries,
            maximumApplications: maximumApplications,
            isCancelled: isCancelled
        )
        let targets = inventory.applications.map { application in
            let info = Bundle(url: application.url)?.infoDictionary ?? [:]
            let feedValue = info["SUFeedURL"] as? String
            let profileFeed = info["SUEnableSystemProfiling"] as? Bool == true
            let source: ApplicationUpdateSource

            if profileFeed, feedValue != nil {
                source = .unsupportedFeed
            } else if let feedValue {
                if let feedURL = URL(string: feedValue), Self.isSecureFeedURL(feedURL) {
                    source = .sparkleFeed(feedURL)
                } else {
                    source = .unsupportedFeed
                }
            } else if FileManager.default.fileExists(atPath: application.url.appendingPathComponent("Contents/_MASReceipt/receipt").path) {
                source = .appStore
            } else if application.url.path.hasPrefix("/System/Applications/")
                        || (application.bundleIdentifier?.hasPrefix("com.apple.") ?? false) {
                source = .appleSoftwareUpdate
            } else {
                source = .builtInUpdater
            }

            return ApplicationUpdateTarget(
                application: application,
                buildVersion: info["CFBundleVersion"] as? String,
                source: source
            )
        }
        return ApplicationUpdateDiscoveryResult(
            targets: targets,
            inaccessibleLocations: inventory.inaccessibleLocations,
            wasLimited: inventory.wasLimited,
            wasCancelled: inventory.wasCancelled
        )
    }

    func check(feedURL: URL, installedBuildVersion: String?) async throws -> ApplicationUpdateFeedResult {
        guard Self.isSecureFeedURL(feedURL), let originalHost = feedURL.host?.lowercased() else {
            throw ApplicationUpdateError.insecureFeed
        }

        var request = URLRequest(url: feedURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("application/rss+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")
        request.setValue("MacCleaner", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        let redirectGuard = HTTPSFeedRedirectGuard(originalHost: originalHost)
        let session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ApplicationUpdateError.invalidFeed }
        if (300..<400).contains(response.statusCode) {
            throw ApplicationUpdateError.redirectedToAnotherHost
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ApplicationUpdateError.httpStatus(response.statusCode)
        }
        guard response.url?.scheme?.lowercased() == "https",
              response.url?.host?.lowercased() == originalHost else {
            throw ApplicationUpdateError.redirectedToAnotherHost
        }

        var body: [UInt8] = []
        body.reserveCapacity(Self.maximumFeedBytes)
        for try await byte in bytes {
            guard body.count < Self.maximumFeedBytes else { throw ApplicationUpdateError.feedTooLarge }
            body.append(byte)
        }

        guard let feedItems = SparkleAppcastParser().parse(Data(body)) else {
            throw ApplicationUpdateError.invalidFeed
        }
        let currentSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "\(currentSystemVersion.majorVersion).\(currentSystemVersion.minorVersion).\(currentSystemVersion.patchVersion)"
        let compatibleItems = feedItems.filter { item in
            guard Self.compareVersions(item.buildVersion, item.buildVersion) != nil else { return false }
            guard let minimum = item.minimumSystemVersion else { return true }
            guard let comparison = Self.compareVersions(minimum, systemVersion) else { return false }
            return comparison <= 0
        }
        guard let newest = compatibleItems.max(by: { lhs, rhs in
            (Self.compareVersions(lhs.buildVersion, rhs.buildVersion) ?? 0) < 0
        }) else { throw ApplicationUpdateError.noVersionInformation }

        let outcome: ApplicationUpdateFeedOutcome
        if let installedBuildVersion,
           let comparison = Self.compareVersions(newest.buildVersion, installedBuildVersion) {
            outcome = comparison > 0 ? .updateAdvertised : .noNewerVersion
        } else {
            outcome = .versionCouldNotBeCompared
        }

        return ApplicationUpdateFeedResult(
            checkedAt: .now,
            sourceHost: response.url?.host ?? originalHost,
            installedBuildVersion: installedBuildVersion,
            advertisedBuildVersion: newest.buildVersion,
            advertisedDisplayVersion: newest.displayVersion,
            outcome: outcome
        )
    }

    static func isSecureFeedURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
            && url.query == nil
            && url.fragment == nil
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> Int? {
        func components(_ value: String) -> [UInt64]? {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 8 else { return nil }
            var numbers: [UInt64] = []
            for part in parts {
                guard !part.isEmpty, part.allSatisfy(\.isNumber), let number = UInt64(part) else { return nil }
                numbers.append(number)
            }
            return numbers
        }
        guard let left = components(lhs), let right = components(rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart != rightPart { return leftPart > rightPart ? 1 : -1 }
        }
        return 0
    }
}

private final class HTTPSFeedRedirectGuard: NSObject, URLSessionTaskDelegate {
    private let originalHost: String

    init(originalHost: String) {
        self.originalHost = originalHost
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == originalHost else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
