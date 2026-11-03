import Foundation

struct HomebrewCaskUpdate: Codable, Equatable, Identifiable, Sendable {
    let token: String
    let name: String
    let installedVersions: [String]
    let currentVersion: String

    var id: String { token }

    var updateCommand: String {
        "brew upgrade --cask \(token)"
    }
}

struct HomebrewCaskUpdateReport: Codable, Equatable, Sendable {
    let checkedAt: Date
    let updates: [HomebrewCaskUpdate]
}

enum HomebrewCaskUpdateError: LocalizedError, Equatable, Sendable {
    case notInstalled
    case couldNotStart
    case timedOut
    case outputTooLarge
    case commandFailed(Int32)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Homebrew is not installed in a standard location on this Mac."
        case .couldNotStart:
            "Homebrew could not be started. Check that it still works in Terminal."
        case .timedOut:
            "Homebrew did not finish the update check in time. Try again later."
        case .outputTooLarge:
            "Homebrew returned more data than Mac Cleaner can safely review."
        case let .commandFailed(status):
            "Homebrew could not complete its read-only update check (status \(status))."
        case .invalidOutput:
            "Homebrew returned update information Mac Cleaner could not safely understand."
        }
    }
}

/// Checks Homebrew's locally available cask metadata. It never updates Homebrew,
/// downloads packages, or installs an update.
struct HomebrewCaskUpdateService: Sendable {
    static let maximumOutputBytes = 2_000_000
    static let timeoutSeconds = 45

    private let executableOverride: URL?

    init(executableOverride: URL? = nil) {
        self.executableOverride = executableOverride
    }

    func check(checkedAt: Date = .now) throws -> HomebrewCaskUpdateReport {
        guard let executable = executableOverride ?? Self.brewExecutable() else {
            throw HomebrewCaskUpdateError.notInstalled
        }

        let data = try Self.runReadOnlyCheck(executable: executable)
        return try Self.parse(data, checkedAt: checkedAt)
    }

    static func brewExecutable(searchPaths: [String] = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew"
    ]) -> URL? {
        searchPaths
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func parse(_ data: Data, checkedAt: Date = .now) throws -> HomebrewCaskUpdateReport {
        guard data.count <= maximumOutputBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCasks = root["casks"] as? [[String: Any]] else {
            throw HomebrewCaskUpdateError.invalidOutput
        }

        var seenTokens = Set<String>()
        var updates: [HomebrewCaskUpdate] = []
        for rawCask in rawCasks {
            guard let token = string(rawCask["token"]),
                  isSafeToken(token),
                  seenTokens.insert(token).inserted,
                  let currentVersion = string(rawCask["current_version"]),
                  !currentVersion.isEmpty,
                  let installedVersions = stringArray(rawCask["installed_versions"]),
                  !installedVersions.isEmpty else {
                throw HomebrewCaskUpdateError.invalidOutput
            }

            let name = string(rawCask["name"])
                ?? stringArray(rawCask["name"])?.first
                ?? token
            updates.append(HomebrewCaskUpdate(
                token: token,
                name: name,
                installedVersions: installedVersions,
                currentVersion: currentVersion
            ))
        }

        return HomebrewCaskUpdateReport(
            checkedAt: checkedAt,
            updates: updates.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringArray(_ value: Any?) -> [String]? {
        if let value = value as? [String] {
            let cleaned = value.compactMap { string($0) }
            return cleaned.isEmpty ? nil : cleaned
        }
        if let value = string(value) { return [value] }
        return nil
    }

    private static func isSafeToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45 || byte == 46 || byte == 95 || byte == 43 || byte == 64
        }
    }

    private static func runReadOnlyCheck(executable: URL) throws -> Data {
        let process = Process()
        let output = Pipe()
        let control = HomebrewProcessControl(process: process)
        let timeout = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        process.executableURL = executable
        process.arguments = ["outdated", "--cask", "--json=v2"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw HomebrewCaskUpdateError.couldNotStart
        }

        timeout.schedule(deadline: .now() + .seconds(timeoutSeconds))
        timeout.setEventHandler { control.terminateForTimeout() }
        timeout.resume()
        defer { timeout.cancel() }

        var data = Data()
        data.reserveCapacity(32_000)
        var exceededLimit = false
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if data.count + chunk.count > maximumOutputBytes {
                exceededLimit = true
                control.terminateForOutputLimit()
            } else if !exceededLimit {
                data.append(chunk)
            }
        }

        process.waitUntilExit()
        if control.didTimeOut { throw HomebrewCaskUpdateError.timedOut }
        if exceededLimit { throw HomebrewCaskUpdateError.outputTooLarge }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw HomebrewCaskUpdateError.commandFailed(process.terminationStatus)
        }
        return data
    }
}

private final class HomebrewProcessControl: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var timedOut = false

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    init(process: Process) {
        self.process = process
    }

    func terminateForTimeout() {
        lock.lock()
        guard process.isRunning else {
            lock.unlock()
            return
        }
        timedOut = true
        process.terminate()
        lock.unlock()
    }

    func terminateForOutputLimit() {
        lock.lock()
        if process.isRunning { process.terminate() }
        lock.unlock()
    }
}
