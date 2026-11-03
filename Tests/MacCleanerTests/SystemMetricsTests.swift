import XCTest
@testable import MacCleaner

final class SystemMetricsTests: XCTestCase {
    func testCPUUsageUsesCounterDeltas() {
        let previous = CPULoadCounters(totalTicks: 100, idleTicks: 60)
        let current = CPULoadCounters(totalTicks: 200, idleTicks: 110)

        XCTAssertEqual(SystemMetricMath.cpuUsagePercent(previous: previous, current: current), 50)
    }

    func testCPUUsageIsUnavailableWithoutAValidBaseline() {
        let sample = CPULoadCounters(totalTicks: 200, idleTicks: 110)
        let reset = CPULoadCounters(totalTicks: 150, idleTicks: 70)

        XCTAssertNil(SystemMetricMath.cpuUsagePercent(previous: nil, current: sample))
        XCTAssertNil(SystemMetricMath.cpuUsagePercent(previous: sample, current: reset))
    }

    func testProcessCPUUsageUsesNanosecondDeltasAndAllowsMultipleCores() {
        XCTAssertEqual(
            ProcessActivityMath.cpuUsagePercent(cpuTimeDeltaNanoseconds: 500_000_000, elapsedSeconds: 1),
            50
        )
        XCTAssertEqual(
            ProcessActivityMath.cpuUsagePercent(cpuTimeDeltaNanoseconds: 2_000_000_000, elapsedSeconds: 1),
            200
        )
        XCTAssertNil(ProcessActivityMath.cpuUsagePercent(cpuTimeDeltaNanoseconds: 100, elapsedSeconds: 0))
        XCTAssertNil(ProcessActivityMath.cpuUsagePercent(cpuTimeDeltaNanoseconds: 100, elapsedSeconds: .infinity))
    }

    func testProcessActivityRankingSortsCPUAndResidentMemoryWithUnavailableCPULast() {
        func process(_ id: Int32, _ name: String, cpu: Double?, memory: UInt64) -> ProcessActivitySnapshot {
            ProcessActivitySnapshot(
                processID: id,
                startedAtSeconds: 1,
                startedAtMicroseconds: UInt64(id),
                name: name,
                cpuUsagePercent: cpu,
                residentMemoryBytes: memory
            )
        }
        let readings = [
            process(1, "Small CPU", cpu: 12, memory: 900),
            process(2, "Large memory", cpu: 4, memory: 8_000),
            process(3, "Measuring", cpu: nil, memory: 100)
        ]

        XCTAssertEqual(ProcessActivityRanking.cpu.ordered(readings).map(\.name), ["Small CPU", "Large memory", "Measuring"])
        XCTAssertEqual(ProcessActivityRanking.memory.ordered(readings).map(\.name), ["Large memory", "Small CPU", "Measuring"])
    }

    func testProcessActivityDisplayLimitReturnsTheConfiguredHighestRankedRows() {
        let processes = (1...14).map { index in
            ProcessActivitySnapshot(
                processID: Int32(index),
                startedAtSeconds: 1,
                startedAtMicroseconds: UInt64(index),
                name: "Process \(index)",
                cpuUsagePercent: Double(index),
                residentMemoryBytes: UInt64(index)
            )
        }

        let visible = ProcessActivityDisplayLimit.five.visibleProcesses(in: processes, rankedBy: .cpu)

        XCTAssertEqual(visible.count, 5)
        XCTAssertEqual(visible.map(\.name), ["Process 14", "Process 13", "Process 12", "Process 11", "Process 10"])
        XCTAssertEqual(ProcessActivityDisplayLimit.defaultValue, .eight)
    }

    func testProcessSamplerIncludesTheCurrentTestProcessWhenReadable() async throws {
        let sampler = ProcessActivitySampler()
        let processID = Int32(ProcessInfo.processInfo.processIdentifier)

        let first = await sampler.sample()
        XCTAssertTrue(first.isAvailable)
        XCTAssertTrue(first.processes.contains { $0.processID == processID })

        try await Task.sleep(nanoseconds: 50_000_000)
        let second = await sampler.sample()
        let currentProcess = second.processes.first { $0.processID == processID }
        XCTAssertNotNil(currentProcess)
        XCTAssertNotNil(currentProcess?.cpuUsagePercent)
    }

    func testNetworkRatesUseCounterDeltasOverElapsedSeconds() {
        let previous = NetworkByteCounters(receivedBytes: 10_000, sentBytes: 4_000)
        let current = NetworkByteCounters(receivedBytes: 16_000, sentBytes: 5_000)

        let rates = SystemMetricMath.networkTrafficRate(previous: previous, current: current, elapsedSeconds: 2)

        XCTAssertEqual(rates?.downloadBytesPerSecond, 3_000)
        XCTAssertEqual(rates?.uploadBytesPerSecond, 500)
    }

    func testNetworkRatesWaitForBaselineAndRejectResetCountersOrInvalidTime() {
        let previous = NetworkByteCounters(receivedBytes: 10_000, sentBytes: 4_000)
        let current = NetworkByteCounters(receivedBytes: 9_000, sentBytes: 5_000)

        XCTAssertNil(SystemMetricMath.networkTrafficRate(previous: nil, current: previous, elapsedSeconds: 2))
        XCTAssertNil(SystemMetricMath.networkTrafficRate(previous: previous, current: current, elapsedSeconds: 2))
        XCTAssertNil(SystemMetricMath.networkTrafficRate(previous: previous, current: previous, elapsedSeconds: 0))
        XCTAssertNil(SystemMetricMath.networkTrafficRate(previous: previous, current: previous, elapsedSeconds: .infinity))
    }

    func testSwapSnapshotReportsUsedAndAvailableCapacity() {
        let swap = SwapSnapshot(totalBytes: 4_000, usedBytes: 1_500)

        XCTAssertEqual(swap?.totalBytes, 4_000)
        XCTAssertEqual(swap?.usedBytes, 1_500)
        XCTAssertEqual(swap?.availableBytes, 2_500)
        XCTAssertEqual(swap?.usedFraction, 0.375)
    }

    func testSwapSnapshotRejectsMissingOrInconsistentCapacity() {
        XCTAssertNil(SwapSnapshot(totalBytes: 0, usedBytes: 0))
        XCTAssertNil(SwapSnapshot(totalBytes: 1_000, usedBytes: 1_001))
    }

    func testUptimeFormattingUsesPlainDaysHoursAndMinutes() {
        XCTAssertEqual(SystemMetricPresentation.uptimeDescription(seconds: 0), "0m")
        XCTAssertEqual(SystemMetricPresentation.uptimeDescription(seconds: 3_661), "1h 1m")
        XCTAssertEqual(SystemMetricPresentation.uptimeDescription(seconds: 176_400), "2d 1h")
        XCTAssertEqual(SystemMetricPresentation.uptimeDescription(seconds: -.infinity), "Unavailable")
        XCTAssertEqual(SystemMetricPresentation.uptimeDescription(seconds: .greatestFiniteMagnitude), "Unavailable")
    }

    func testBatteryHealthRatingAcceptsOnlyKnownSystemValues() {
        XCTAssertEqual(BatteryHealthRating(systemValue: "Good"), .good)
        XCTAssertEqual(BatteryHealthRating(systemValue: "Fair"), .fair)
        XCTAssertEqual(BatteryHealthRating(systemValue: "Poor"), .poor)
        XCTAssertNil(BatteryHealthRating(systemValue: "Service Recommended"))
        XCTAssertNil(BatteryHealthRating(systemValue: nil))
    }

    func testBatteryServiceWarningAcceptsOnlyDocumentedNonemptyValues() {
        XCTAssertEqual(BatteryServiceCondition(systemValue: "Check Battery"), .checkBattery)
        XCTAssertEqual(BatteryServiceCondition(systemValue: "Permanent Battery Failure"), .permanentFailure)
        XCTAssertNil(BatteryServiceCondition(systemValue: ""))
        XCTAssertNil(BatteryServiceCondition(systemValue: "Normal"))
    }

    func testMemoryPressureEventsAreMappedWithoutGuessingFromMemoryCounts() {
        XCTAssertEqual(MemoryPressureLevel.reported(by: .normal), .normal)
        XCTAssertEqual(MemoryPressureLevel.reported(by: .warning), .warning)
        XCTAssertEqual(MemoryPressureLevel.reported(by: [.warning, .critical]), .critical)
        XCTAssertNil(MemoryPressureLevel.reported(by: []))
    }

    func testMacHealthScoreUsesOnlyAvailableChecksAndPublishedWeights() {
        let battery = BatterySnapshot(
            percentage: 80,
            isCharging: false,
            onExternalPower: false,
            healthRating: .fair,
            healthCondition: nil,
            cycleCount: 280
        )
        let assessment = MacHealthAssessment(
            storage: StorageSnapshot(totalBytes: 1_000, availableBytes: 150),
            memoryPressure: .warning,
            battery: battery
        )

        XCTAssertEqual(assessment.score, 63)
        XCTAssertEqual(assessment.availableCheckCount, 3)
        XCTAssertEqual(assessment.rating, "Needs attention")
        XCTAssertEqual(assessment.checks.map(\.scorePoints), [70, 55, 60, nil, nil, nil, nil, nil, nil])
    }

    func testMacHealthScoreExcludesUnavailableReadings() {
        let assessment = MacHealthAssessment(
            storage: StorageSnapshot(totalBytes: 1_000, availableBytes: 500),
            memoryPressure: nil,
            battery: nil
        )

        XCTAssertEqual(assessment.score, 100)
        XCTAssertEqual(assessment.availableCheckCount, 1)
        XCTAssertEqual(assessment.checks[1].status, .unavailable)
        XCTAssertEqual(assessment.checks[2].status, .unavailable)
        XCTAssertEqual(assessment.checks[3].status, .unavailable)
        XCTAssertEqual(assessment.checks[8].status, .unavailable)
    }

    func testMacHealthScoreIncludesReportedStartupDiskStatusAtPublishedWeight() {
        let assessment = MacHealthAssessment(
            storage: StorageSnapshot(totalBytes: 1_000, availableBytes: 150),
            memoryPressure: .warning,
            battery: BatterySnapshot(
                percentage: 80,
                isCharging: false,
                onExternalPower: false,
                healthRating: .fair,
                healthCondition: nil,
                cycleCount: 280
            ),
            startupDiskHealth: .verified
        )

        XCTAssertEqual(assessment.score, 70)
        XCTAssertEqual(assessment.availableCheckCount, 4)
        XCTAssertEqual(assessment.checks.map(\.scorePoints), [70, 55, 60, 100, nil, nil, nil, nil, nil])
    }

    func testFailingStartupDiskIsUrgentAndUnavailableStatusDoesNotAffectScore() {
        let failing = MacHealthAssessment(
            storage: StorageSnapshot(totalBytes: 1_000, availableBytes: 150),
            memoryPressure: .warning,
            battery: nil,
            startupDiskHealth: .attention
        )
        let unavailable = MacHealthAssessment(
            storage: StorageSnapshot(totalBytes: 1_000, availableBytes: 150),
            memoryPressure: .warning,
            battery: nil,
            startupDiskHealth: .unavailable
        )

        XCTAssertEqual(failing.checks[3].status, .urgent)
        XCTAssertEqual(failing.checks[3].scorePoints, 0)
        XCTAssertEqual(unavailable.checks[3].status, .unavailable)
        XCTAssertNil(unavailable.checks[3].scorePoints)
        XCTAssertEqual(unavailable.score, 63)
    }

    func testMacHealthScoreIncludesProtectionAndUserCheckedAppleUpdateStatus() {
        let assessment = MacHealthAssessment(
            storage: StorageSnapshot(totalBytes: 1_000, availableBytes: 500),
            memoryPressure: .normal,
            battery: BatterySnapshot(
                percentage: 80,
                isCharging: false,
                onExternalPower: false,
                healthRating: .good,
                healthCondition: nil,
                cycleCount: 100
            ),
            startupDiskHealth: .verified,
            protectionChecks: [
                LocalProtectionCheck(setting: .fileVault, state: .enabled),
                LocalProtectionCheck(setting: .firewall, state: .enabled),
                LocalProtectionCheck(setting: .gatekeeper, state: .disabled),
                LocalProtectionCheck(setting: .systemIntegrity, state: .disabled)
            ],
            macOSUpdateState: .updatesAvailable([
                LocalMacOSUpdateItem(title: "macOS", version: "27.0")
            ])
        )

        XCTAssertEqual(assessment.checks.map(\.scorePoints), [100, 100, 100, 100, 100, 100, 20, 20, 60])
        XCTAssertEqual(assessment.score, 90)
        XCTAssertEqual(assessment.availableCheckCount, 9)
        XCTAssertEqual(assessment.checks[6].status, .urgent)
        XCTAssertEqual(assessment.checks[8].status, .attention)
    }

    func testUnavailableProtectionAndUnrunUpdateChecksAreExcludedFromHealthScore() {
        let assessment = MacHealthAssessment(
            storage: StorageSnapshot(totalBytes: 1_000, availableBytes: 500),
            memoryPressure: .normal,
            battery: nil,
            protectionChecks: [
                LocalProtectionCheck(setting: .firewall, state: .unavailable)
            ],
            macOSUpdateState: .notReported
        )

        XCTAssertEqual(assessment.score, 100)
        XCTAssertEqual(assessment.checks[5].scorePoints, nil)
        XCTAssertEqual(assessment.checks[8].scorePoints, nil)
        XCTAssertEqual(assessment.availableCheckCount, 2)
    }

    func testBatteryServiceConditionIsUrgentEvenWhenBatteryRatingIsGood() {
        let battery = BatterySnapshot(
            percentage: 80,
            isCharging: false,
            onExternalPower: false,
            healthRating: .good,
            healthCondition: .checkBattery,
            cycleCount: nil
        )
        let assessment = MacHealthAssessment(
            storage: StorageSnapshot(totalBytes: 1_000, availableBytes: 500),
            memoryPressure: .normal,
            battery: battery
        )

        XCTAssertEqual(assessment.checks[2].status, .urgent)
        XCTAssertEqual(assessment.checks[2].scorePoints, 20)
    }
}
