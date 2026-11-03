import Darwin
import Foundation

actor ProcessActivitySampler {
    private struct PreviousSample {
        let cpuTimeNanoseconds: UInt64
        let sampledAt: TimeInterval
    }

    private let maximumCPUInterval: TimeInterval = 4
    private var previousSamples: [String: PreviousSample] = [:]

    func sample(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> ProcessActivityReading {
        guard now.isFinite, now >= 0,
              let (processIDs, wasTruncated) = Self.processIDs() else {
            previousSamples = [:]
            return .unavailable
        }

        let currentUserID = getuid()
        var nextSamples: [String: PreviousSample] = [:]
        var activities: [ProcessActivitySnapshot] = []
        activities.reserveCapacity(min(processIDs.count, 512))

        for processID in processIDs where processID > 0 {
            if Task.isCancelled { break }

            var basicInfo = proc_bsdinfo()
            let basicInfoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            let basicInfoBytes = withUnsafeMutablePointer(to: &basicInfo) { pointer in
                proc_pidinfo(
                    processID,
                    Int32(PROC_PIDTBSDINFO),
                    0,
                    pointer,
                    basicInfoSize
                )
            }
            guard basicInfoBytes == basicInfoSize,
                  basicInfo.pbi_uid == currentUserID else { continue }

            var taskInfo = proc_taskinfo()
            let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let taskInfoBytes = withUnsafeMutablePointer(to: &taskInfo) { pointer in
                proc_pidinfo(
                    processID,
                    Int32(PROC_PIDTASKINFO),
                    0,
                    pointer,
                    taskInfoSize
                )
            }
            guard taskInfoBytes == taskInfoSize,
                  let name = Self.processName(processID) else { continue }

            let (cpuTime, overflow) = taskInfo.pti_total_user.addingReportingOverflow(taskInfo.pti_total_system)
            guard !overflow else { continue }
            let identity = "\(processID):\(basicInfo.pbi_start_tvsec):\(basicInfo.pbi_start_tvusec)"
            let previous = previousSamples[identity]
            let elapsed = previous.map { now - $0.sampledAt }
            let cpuUsage: Double?
            if let previous, let elapsed,
               cpuTime >= previous.cpuTimeNanoseconds,
               elapsed > 0, elapsed <= maximumCPUInterval {
                cpuUsage = ProcessActivityMath.cpuUsagePercent(
                    cpuTimeDeltaNanoseconds: cpuTime - previous.cpuTimeNanoseconds,
                    elapsedSeconds: elapsed
                )
            } else {
                cpuUsage = nil
            }
            nextSamples[identity] = PreviousSample(cpuTimeNanoseconds: cpuTime, sampledAt: now)
            activities.append(ProcessActivitySnapshot(
                processID: processID,
                startedAtSeconds: basicInfo.pbi_start_tvsec,
                startedAtMicroseconds: basicInfo.pbi_start_tvusec,
                name: name,
                cpuUsagePercent: cpuUsage,
                residentMemoryBytes: taskInfo.pti_resident_size
            ))
        }

        previousSamples = nextSamples
        return ProcessActivityReading(processes: activities, isAvailable: true, wasTruncated: wasTruncated)
    }

    private static func processIDs() -> ([pid_t], Bool)? {
        let requiredBytes = Int(proc_listallpids(nil, 0))
        guard requiredBytes > 0 else { return nil }
        let processIDSize = MemoryLayout<pid_t>.size
        let requiredCount = (requiredBytes + processIDSize - 1) / processIDSize
        let capacity = min(maximumProcessCapacity, max(256, requiredCount + 128))
        var processIDs = [pid_t](repeating: 0, count: capacity)
        let bytesWritten = processIDs.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * processIDSize))
        }
        guard bytesWritten > 0 else { return nil }
        let actualCount = min(processIDs.count, Int(bytesWritten) / processIDSize)
        return (Array(processIDs.prefix(actualCount)), Int(bytesWritten) >= capacity * processIDSize)
    }

    private static let maximumProcessCapacity = 8_192

    private static func processName(_ processID: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2)
        let bytesWritten = buffer.withUnsafeMutableBufferPointer { value in
            proc_name(processID, value.baseAddress, UInt32(value.count))
        }
        guard bytesWritten > 0 else { return nil }
        let name = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
