import Foundation
import Darwin

struct LocalMacOSUpdateItem: Equatable, Identifiable, Sendable {
    let title: String
    let version: String?

    var id: String { "\(title)|\(version ?? "")" }
}

enum LocalMacOSUpdateState: Equatable, Sendable {
    case upToDate
    case updatesAvailable([LocalMacOSUpdateItem])
    case notReported
    case timedOut
}

struct LocalMacOSUpdateReport: Equatable, Sendable {
    let state: LocalMacOSUpdateState
    let checkedAt: Date
}

enum LocalMacOSUpdateProbeResult: Equatable, Sendable {
    case completed(output: Data, status: Int32)
    case failed
    case timedOut
}

/// Runs Apple's list-only update check after the user asks for it. It never installs or downloads updates.
struct LocalMacOSUpdateService: Sendable {
    typealias Probe = @Sendable () -> LocalMacOSUpdateProbeResult

    private let probe: Probe

    init(probe: @escaping Probe = { Self.runListCheck() }) {
        self.probe = probe
    }

    func report(checkedAt: Date = .now) async -> LocalMacOSUpdateReport {
        let probe = self.probe
        return await Task.detached(priority: .utility) {
            Self.parse(probe(), checkedAt: checkedAt)
        }.value
    }

    static func parse(
        _ result: LocalMacOSUpdateProbeResult,
        checkedAt: Date = .now
    ) -> LocalMacOSUpdateReport {
        let state: LocalMacOSUpdateState
        switch result {
        case .timedOut:
            state = .timedOut
        case .failed:
            state = .notReported
        case let .completed(output, status):
            guard status == 0 else {
                return LocalMacOSUpdateReport(state: .notReported, checkedAt: checkedAt)
            }

            let text = String(decoding: output, as: UTF8.self)
            let items = availableUpdates(in: text)
            if !items.isEmpty {
                state = .updatesAvailable(items)
            } else if reportsNoUpdates(text) {
                state = .upToDate
            } else {
                state = .notReported
            }
        }
        return LocalMacOSUpdateReport(state: state, checkedAt: checkedAt)
    }

    private static func availableUpdates(in output: String) -> [LocalMacOSUpdateItem] {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let titledItems: [LocalMacOSUpdateItem] = lines.compactMap { line -> LocalMacOSUpdateItem? in
            guard let titleRange = line.range(of: "Title:", options: .caseInsensitive) else { return nil }
            let details = line[titleRange.upperBound...]
            let versionRange = details.range(of: ", Version:", options: .caseInsensitive)
            let rawTitle = versionRange.map { details[..<$0.lowerBound] }
                ?? details.split(separator: ",", maxSplits: 1).first.map(Substring.init)
            guard let rawTitle else { return nil }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }

            let version = versionRange
                .map { details[$0.upperBound...] }
                .map { $0.split(separator: ",", maxSplits: 1).first.map(String.init) }
                .flatMap { $0 }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            return LocalMacOSUpdateItem(title: title, version: version)
        }

        // Older output formats provide a readable label without a separate title/version line.
        guard titledItems.isEmpty else { return titledItems }
        return lines.compactMap { line -> LocalMacOSUpdateItem? in
            guard let labelRange = line.range(of: "Label:", options: .caseInsensitive) else { return nil }
            let label = line[labelRange.upperBound...]
                .split(separator: ",", maxSplits: 1)
                .first
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            guard !label.isEmpty else { return nil }
            return LocalMacOSUpdateItem(title: label, version: nil)
        }
    }

    private static func reportsNoUpdates(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("no new software available")
            || normalized.contains("no updates are available")
            || normalized.contains("no updates available")
    }

    private static func runListCheck() -> LocalMacOSUpdateProbeResult {
        let process = Process()
        let output = Pipe()
        let outputBuffer = ProcessOutputBuffer()
        let processFinished = DispatchSemaphore(value: 0)
        let outputFinished = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
        process.arguments = ["--list"]
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { _ in processFinished.signal() }

        do {
            try process.run()
        } catch {
            return .failed
        }

        DispatchQueue.global(qos: .utility).async {
            outputBuffer.replace(with: output.fileHandleForReading.readDataToEndOfFile())
            outputFinished.signal()
        }

        guard processFinished.wait(timeout: .now() + .seconds(90)) == .success else {
            if process.isRunning { process.terminate() }
            if processFinished.wait(timeout: .now() + .seconds(2)) == .timedOut, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = processFinished.wait(timeout: .now() + .seconds(2))
            }
            _ = outputFinished.wait(timeout: .now() + .seconds(2))
            return .timedOut
        }

        guard outputFinished.wait(timeout: .now() + .seconds(2)) == .success else { return .failed }
        return .completed(output: outputBuffer.read(), status: process.terminationStatus)
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func replace(with data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }

    func read() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
