import Foundation

enum ProcessActivityDisplayLimit: Int, CaseIterable, Identifiable, Sendable {
    case five = 5
    case eight = 8
    case twelve = 12

    static let defaultValue: ProcessActivityDisplayLimit = .eight
    static let storageKey = "MacCleaner.processActivityDisplayLimit"

    var id: Int { rawValue }
    var title: String { "Top \(rawValue)" }

    func visibleProcesses(
        in processes: [ProcessActivitySnapshot],
        rankedBy ranking: ProcessActivityRanking
    ) -> [ProcessActivitySnapshot] {
        Array(ranking.ordered(processes).prefix(rawValue))
    }
}

enum ProcessActivityRanking: String, CaseIterable, Identifiable, Sendable {
    case cpu = "CPU"
    case memory = "Memory"

    var id: String { rawValue }

    func ordered(_ processes: [ProcessActivitySnapshot]) -> [ProcessActivitySnapshot] {
        processes.sorted { lhs, rhs in
            switch self {
            case .cpu:
                switch (lhs.cpuUsagePercent, rhs.cpuUsagePercent) {
                case let (left?, right?) where left != right: return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            case .memory:
                if lhs.residentMemoryBytes != rhs.residentMemoryBytes {
                    return lhs.residentMemoryBytes > rhs.residentMemoryBytes
                }
            }
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}

enum ProcessActivityMath {
    static func cpuUsagePercent(cpuTimeDeltaNanoseconds: UInt64, elapsedSeconds: TimeInterval) -> Double? {
        guard elapsedSeconds.isFinite, elapsedSeconds > 0 else { return nil }
        let elapsedNanoseconds = elapsedSeconds * 1_000_000_000
        guard elapsedNanoseconds.isFinite, elapsedNanoseconds > 0 else { return nil }
        let percentage = Double(cpuTimeDeltaNanoseconds) / elapsedNanoseconds * 100
        guard percentage.isFinite, percentage >= 0 else { return nil }
        return percentage
    }
}
