import Foundation
import Darwin
import ServiceManagement
import Security

enum StartupSignatureStatus: Equatable, Sendable {
    case verified
    case unsigned
    case invalid
    case unavailable

    var title: String {
        switch self {
        case .verified: "Signature verified"
        case .unsigned: "No code signature"
        case .invalid: "Signature did not verify"
        case .unavailable: "Signature could not be checked"
        }
    }
}

struct StartupSignatureAssessment: Equatable, Sendable {
    let status: StartupSignatureStatus
    let teamIdentifier: String?

    var description: String {
        guard status == .verified, let teamIdentifier, !teamIdentifier.isEmpty else {
            return status.title
        }
        return "Signature verified · Team \(teamIdentifier)"
    }
}

struct StartupItem: Identifiable, Sendable {
    let locationURL: URL
    let label: String
    let program: String?
    let mechanism: String
    let associatedApp: String?
    let purpose: String
    let configuration: String
    let launchConditions: [String]
    let authorization: String
    let signatureAssessment: StartupSignatureAssessment?
    var signing: String? { signatureAssessment?.description }
    var id: String { locationURL.path }
}

struct StartupInventoryResult: Sendable {
    let items: [StartupItem]
    let skipped: Int
    let wasCancelled: Bool
}

struct StartupInventoryProgress: Sendable {
    let currentLocation: Int
    let totalLocations: Int
    let mechanism: String
}

struct StartupInventory: Sendable {
    static func standardLocations(homeDirectory: URL = SafeFilePolicy.accountHome) -> [(url: URL, mechanism: String)] {
        let home = homeDirectory.standardizedFileURL
        return [
            (home.appendingPathComponent("Library/LaunchAgents", isDirectory: true), "User launch agent"),
            (home.appendingPathComponent("Library/LaunchDaemons", isDirectory: true), "User launch daemon"),
            (URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true), "Shared launch agent"),
            (URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true), "Shared launch daemon"),
            (URL(fileURLWithPath: "/System/Library/LaunchAgents", isDirectory: true), "Apple launch agent"),
            (URL(fileURLWithPath: "/System/Library/LaunchDaemons", isDirectory: true), "Apple launch daemon")
        ]
    }

    static func standardApplicationRoots(homeDirectory: URL = SafeFilePolicy.accountHome) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.standardizedFileURL.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true)
        ]
    }

    func scan(
        locations: [(url: URL, mechanism: String)],
        applicationBundles: [URL] = [],
        isCancelled: @Sendable () -> Bool = { Task.isCancelled },
        progress: @Sendable (StartupInventoryProgress) -> Void = { _ in }
    ) -> StartupInventoryResult {
        let fm = FileManager.default
        var items: [StartupItem] = []
        var skipped = 0
        var wasCancelled = false
        var seenApplicationPaths = Set<String>()
        let uniqueApplicationBundles = applicationBundles
            .filter { seenApplicationPaths.insert($0.path).inserted }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let totalLocations = locations.count + uniqueApplicationBundles.count
        for (locationIndex, location) in locations.enumerated() {
            guard !isCancelled() else { wasCancelled = true; break }
            progress(StartupInventoryProgress(
                currentLocation: locationIndex + 1,
                totalLocations: totalLocations,
                mechanism: location.mechanism
            ))
            var locationStat = Darwin.stat()
            guard location.url.path.withCString({ Darwin.lstat($0, &locationStat) }) == 0 else {
                if errno != ENOENT { skipped += 1 }
                continue
            }
            guard locationStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  SafeFilePolicy.hasNoSymlinkedParent(path: location.url.path, root: "/") else {
                skipped += 1
                continue
            }
            let urls: [URL]
            do { urls = try fm.contentsOfDirectory(at: location.url, includingPropertiesForKeys: nil, options: []) }
            catch { skipped += 1; continue }
            for url in urls where url.pathExtension.lowercased() == "plist" {
                guard !isCancelled() else { wasCancelled = true; break }
                guard let item = launchDefinition(at: url, mechanism: location.mechanism, parentApplication: nil) else {
                    skipped += 1
                    continue
                }
                items.append(item)
            }
            if wasCancelled { break }
        }

        if !wasCancelled {
            for (bundleIndex, applicationURL) in uniqueApplicationBundles.enumerated() {
                guard !isCancelled() else { wasCancelled = true; break }
                progress(StartupInventoryProgress(
                    currentLocation: locations.count + bundleIndex + 1,
                    totalLocations: totalLocations,
                    mechanism: "Installed app helpers"
                ))
                guard isOrdinaryDirectory(applicationURL),
                      let applicationBundle = Bundle(url: applicationURL),
                      let applicationIdentifier = applicationBundle.bundleIdentifier else {
                    skipped += 1
                    continue
                }
                let applicationName = displayName(of: applicationBundle, at: applicationURL)
                let isAppleApplication = applicationIdentifier.hasPrefix("com.apple.")
                    || applicationURL.path.hasPrefix("/System/Applications/")
                    || applicationURL.path.hasPrefix("/System/Library/CoreServices/")
                let mechanismPrefix = isAppleApplication ? "Apple app-bundled" : "App-bundled"

                let bundledDefinitionFolders: [(String, String)] = [
                    ("Contents/Library/LaunchAgents", "\(mechanismPrefix) launch agent"),
                    ("Contents/Library/LaunchDaemons", "\(mechanismPrefix) launch daemon")
                ]
                for (relativePath, mechanism) in bundledDefinitionFolders {
                    guard !isCancelled() else { wasCancelled = true; break }
                    let folderURL = applicationURL.appendingPathComponent(relativePath, isDirectory: true)
                    switch directoryEntries(at: folderURL) {
                    case .absent:
                        continue
                    case .unreadable:
                        skipped += 1
                    case let .listed(urls):
                        for url in urls where url.pathExtension.lowercased() == "plist" {
                            guard !isCancelled() else { wasCancelled = true; break }
                            guard let item = launchDefinition(
                                at: url,
                                mechanism: mechanism,
                                parentApplication: applicationName
                            ) else {
                                skipped += 1
                                continue
                            }
                            items.append(item)
                        }
                    }
                    if wasCancelled { break }
                }
                guard !wasCancelled else { break }

                let loginItemsURL = applicationURL.appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
                switch directoryEntries(at: loginItemsURL) {
                case .absent:
                    continue
                case .unreadable:
                    skipped += 1
                case let .listed(urls):
                    for helperURL in urls where helperURL.pathExtension.lowercased() == "app" {
                        guard !isCancelled() else { wasCancelled = true; break }
                        guard let item = bundledLoginItem(
                            at: helperURL,
                            parentApplication: applicationName,
                            mechanism: "\(mechanismPrefix) login item"
                        ) else {
                            skipped += 1
                            continue
                        }
                        items.append(item)
                    }
                }
                if wasCancelled { break }
            }
        }
        return StartupInventoryResult(
            items: items.sorted {
                let comparison = $0.label.localizedStandardCompare($1.label)
                return comparison == .orderedSame
                    ? $0.locationURL.path.localizedStandardCompare($1.locationURL.path) == .orderedAscending
                    : comparison == .orderedAscending
            },
            skipped: skipped,
            wasCancelled: wasCancelled
        )
    }

    private enum DirectoryEntries {
        case absent
        case listed([URL])
        case unreadable
    }

    private func directoryEntries(at url: URL) -> DirectoryEntries {
        var stat = Darwin.stat()
        guard url.path.withCString({ Darwin.lstat($0, &stat) }) == 0 else {
            return errno == ENOENT ? .absent : .unreadable
        }
        guard stat.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              SafeFilePolicy.hasNoSymlinkedParent(path: url.path, root: "/") else {
            return .unreadable
        }
        do {
            return .listed(try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []))
        } catch {
            return .unreadable
        }
    }

    private func isOrdinaryDirectory(_ url: URL) -> Bool {
        var stat = Darwin.stat()
        return url.path.withCString({ Darwin.lstat($0, &stat) }) == 0
            && stat.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && SafeFilePolicy.hasNoSymlinkedParent(path: url.path, root: "/")
    }

    private func displayName(of bundle: Bundle, at url: URL) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func launchDefinition(at url: URL, mechanism: String, parentApplication: String?) -> StartupItem? {
        var stat = Darwin.stat()
        guard url.path.withCString({ Darwin.lstat($0, &stat) }) == 0,
              stat.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), stat.st_size <= 1_000_000,
              SafeFilePolicy.hasNoSymlinkedParent(path: url.path, root: "/"),
              let data = try? Data(contentsOf: url), data.count <= 1_000_000,
              let dictionary = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            return nil
        }
        let label = (dictionary["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        let candidate = (dictionary["Program"] as? String) ?? (dictionary["ProgramArguments"] as? [String])?.first
        let program = candidate.flatMap { $0.hasPrefix("/") && !$0.contains("\0") ? $0 : nil }
        let referencedApplication = applicationName(referencedBy: program)
        let associatedApplication = parentApplication ?? referencedApplication
        let purpose = declaredPurpose(in: dictionary)
            ?? associatedApplication.map { "Background helper associated with \($0)." }
            ?? (program == nil ? nil : "Launches the listed background program.")
            ?? "Purpose is not described in this definition."
        let authorization: String
        if parentApplication != nil {
            authorization = "Registration status unavailable for another app"
        } else {
            switch SMAppService.statusForLegacyPlist(at: url) {
            case .enabled: authorization = "Authorized"
            case .requiresApproval: authorization = "Needs approval"
            case .notRegistered: authorization = "No registration reported"
            case .notFound: authorization = "No authorization record found"
            @unknown default: authorization = "Unavailable"
            }
        }
        return StartupItem(
            locationURL: url,
            label: label,
            program: program,
            mechanism: mechanism,
            associatedApp: associatedApplication,
            purpose: purpose,
            configuration: configurationStatus(in: dictionary),
            launchConditions: launchConditions(in: dictionary, mechanism: mechanism),
            authorization: authorization,
            signatureAssessment: program.map { signatureAssessment(at: $0) }
        )
    }

    private func applicationName(referencedBy program: String?) -> String? {
        guard let program,
              let range = program.range(of: ".app/Contents/", options: .caseInsensitive) else { return nil }
        let appPath = String(program[..<range.lowerBound]) + ".app"
        let appURL = URL(fileURLWithPath: appPath)
        guard let appBundle = Bundle(url: appURL) else { return appURL.deletingPathExtension().lastPathComponent }
        return displayName(of: appBundle, at: appURL)
    }

    private func bundledLoginItem(at helperURL: URL, parentApplication: String, mechanism: String) -> StartupItem? {
        guard isOrdinaryDirectory(helperURL), let helperBundle = Bundle(url: helperURL) else { return nil }
        let helperInfo = helperBundle.infoDictionary ?? [:]
        let helperName = displayName(of: helperBundle, at: helperURL)
        let helperIdentifier = helperBundle.bundleIdentifier
        let label = helperIdentifier ?? helperName
        let executable: String? = (helperInfo["CFBundleExecutable"] as? String).flatMap { value in
            guard !value.isEmpty, !value.contains("/"), !value.contains("\\"), !value.contains("\0") else { return nil }
            return value
        }
        let executableURL = executable.map {
            helperURL.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent($0)
        }
        let program = executableURL?.path
        return StartupItem(
            locationURL: helperURL,
            label: label,
            program: program,
            mechanism: mechanism,
            associatedApp: parentApplication,
            purpose: "Login helper bundled with \(parentApplication).",
            configuration: "Bundled with parent app",
            launchConditions: ["May launch when you sign in if registered"],
            authorization: "Registration status unavailable for another app",
            signatureAssessment: signatureAssessment(at: helperURL.path, isBundle: true)
        )
    }

    private func declaredPurpose(in dictionary: [String: Any]) -> String? {
        for key in ["Comment", "Description"] {
            guard let value = dictionary[key] as? String else { continue }
            let printable = value.components(separatedBy: .controlCharacters).joined(separator: " ")
            let trimmed = printable.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !trimmed.isEmpty { return String(trimmed.prefix(240)) }
        }
        return nil
    }

    private func configurationStatus(in dictionary: [String: Any]) -> String {
        guard let disabled = dictionary["Disabled"] as? Bool else { return "No disabled flag in file" }
        return disabled ? "Disabled in file" : "Enabled in file"
    }

    private func launchConditions(in dictionary: [String: Any], mechanism: String) -> [String] {
        var conditions: [String] = []
        if dictionary["RunAtLoad"] as? Bool == true {
            conditions.append(mechanism.localizedCaseInsensitiveContains("daemon") ? "When macOS starts" : "When you sign in")
        }
        if isEnabledCondition(dictionary["KeepAlive"]) {
            conditions.append("Keeps running while its launch conditions are met")
        }
        if let interval = (dictionary["StartInterval"] as? NSNumber)?.intValue, interval > 0 {
            conditions.append(intervalDescription(interval))
        }
        if isNonEmptyCondition(dictionary["StartCalendarInterval"]) {
            conditions.append("On a schedule")
        }
        if isNonEmptyCondition(dictionary["WatchPaths"]) {
            conditions.append("When a watched file changes")
        }
        if isNonEmptyCondition(dictionary["QueueDirectories"]) {
            conditions.append("When queued files are available")
        }
        if isNonEmptyCondition(dictionary["MachServices"]) || isNonEmptyCondition(dictionary["Sockets"]) {
            conditions.append("When another app requests its service")
        }
        if conditions.isEmpty { conditions.append("Started on demand by macOS") }
        return conditions
    }

    private func intervalDescription(_ seconds: Int) -> String {
        if seconds.isMultiple(of: 86_400) {
            let count = seconds / 86_400
            return "Roughly every \(count.formatted()) day\(count == 1 ? "" : "s")"
        }
        if seconds.isMultiple(of: 3_600) {
            let count = seconds / 3_600
            return "Roughly every \(count.formatted()) hour\(count == 1 ? "" : "s")"
        }
        if seconds.isMultiple(of: 60) {
            let count = seconds / 60
            return "Roughly every \(count.formatted()) minute\(count == 1 ? "" : "s")"
        }
        return "Roughly every \(seconds.formatted()) second\(seconds == 1 ? "" : "s")"
    }

    private func isEnabledCondition(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let boolean = value as? Bool { return boolean }
        if let dictionary = value as? [String: Any] { return !dictionary.isEmpty }
        return false
    }

    private func isNonEmptyCondition(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let array = value as? [Any] { return !array.isEmpty }
        if let dictionary = value as? [String: Any] { return !dictionary.isEmpty }
        if let string = value as? String { return !string.isEmpty }
        return false
    }

    private func signatureAssessment(at path: String, isBundle: Bool = false) -> StartupSignatureAssessment {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code else {
            return StartupSignatureAssessment(status: .unavailable, teamIdentifier: nil)
        }
        var validationFlags = kSecCSStrictValidate | kSecCSCheckAllArchitectures
        if isBundle { validationFlags |= kSecCSCheckNestedCode }
        let validity = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: validationFlags), nil)
        guard validity == errSecSuccess else {
            return StartupSignatureAssessment(
                status: validity == errSecCSUnsigned ? .unsigned : .invalid,
                teamIdentifier: nil
            )
        }
        var information: CFDictionary?
        let teamIdentifier: String?
        if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
           let info = information as? [String: Any] {
            teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String
        } else {
            teamIdentifier = nil
        }
        return StartupSignatureAssessment(status: .verified, teamIdentifier: teamIdentifier)
    }
}
