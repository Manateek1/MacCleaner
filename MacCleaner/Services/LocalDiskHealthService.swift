import Foundation

struct LocalDiskHealthReport: Equatable, Sendable {
    let state: LocalDiskHealthState
    let checkedAt: Date
}

/// Reads only the startup volume's macOS-provided SMART status.
struct LocalDiskHealthService: Sendable {
    typealias DataReader = @Sendable () -> Data?

    private let readData: DataReader

    init() {
        readData = { Self.startupDiskInfo() }
    }

    init(readData: @escaping DataReader) {
        self.readData = readData
    }

    func report(checkedAt: Date = .now) async -> LocalDiskHealthReport {
        let readData = self.readData
        return await Task.detached(priority: .utility) {
            Self.parse(readData(), checkedAt: checkedAt)
        }.value
    }

    static func parse(_ data: Data?, checkedAt: Date = .now) -> LocalDiskHealthReport {
        let state: LocalDiskHealthState
        if let data,
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let information = plist as? [String: Any],
           let status = information["SMARTStatus"] as? String {
            switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "verified": state = .verified
            case "failing": state = .attention
            default: state = .unavailable
            }
        } else {
            state = .unavailable
        }
        return LocalDiskHealthReport(state: state, checkedAt: checkedAt)
    }

    private static func startupDiskInfo() -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", "/"]
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
