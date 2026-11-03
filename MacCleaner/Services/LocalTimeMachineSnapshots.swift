import Foundation

struct LocalTimeMachineSnapshot: Identifiable, Equatable, Sendable {
    let name: String
    let createdAt: Date

    var id: String { name }
}

struct LocalTimeMachineSnapshotInventory: Equatable, Sendable {
    let snapshots: [LocalTimeMachineSnapshot]
    let checkedAt: Date
}

enum LocalTimeMachineSnapshotError: LocalizedError {
    case commandFailed

    var errorDescription: String? {
        "macOS couldn’t list local Time Machine snapshots. Check Time Machine and disk access, then try again."
    }
}

struct LocalTimeMachineSnapshotService: Sendable {
    private let command: @Sendable () throws -> String

    init() {
        command = { try Self.runReadOnlyCommand() }
    }

    init(command: @escaping @Sendable () throws -> String) {
        self.command = command
    }

    func inventory(checkedAt: Date = .now, timeZone: TimeZone = .current) async throws -> LocalTimeMachineSnapshotInventory {
        let command = self.command
        let output = try await Task.detached(priority: .utility) {
            try command()
        }.value

        return LocalTimeMachineSnapshotInventory(
            snapshots: Self.parse(output, timeZone: timeZone),
            checkedAt: checkedAt
        )
    }

    static func parse(_ output: String, timeZone: TimeZone = .current) -> [LocalTimeMachineSnapshot] {
        let prefix = "com.apple.TimeMachine."
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.isLenient = false

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine in
                let name = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.hasPrefix(prefix) else { return nil }
                var timestamp = String(name.dropFirst(prefix.count))
                if timestamp.hasSuffix(".local") { timestamp.removeLast(".local".count) }
                guard let createdAt = formatter.date(from: timestamp) else { return nil }
                return LocalTimeMachineSnapshot(name: name, createdAt: createdAt)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private static func runReadOnlyCommand() throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", "/"]
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            throw LocalTimeMachineSnapshotError.commandFailed
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            throw LocalTimeMachineSnapshotError.commandFailed
        }
        return text
    }
}
