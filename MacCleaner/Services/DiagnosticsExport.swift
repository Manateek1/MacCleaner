import Foundation

struct DiagnosticsScanSummary: Codable, Equatable, Sendable {
    let scanType: String
    let finishedAt: Date
    let filesChecked: Int
    let entriesChecked: Int
    let bytesChecked: Int64
    let findingsCount: Int
    let skippedItemCount: Int
    let excludedFolderCount: Int
    let entryLimit: Int
    let wasPartial: Bool
}

struct MacCleanerDiagnosticsReport: Codable, Equatable, Sendable {
    let formatVersion: Int
    let generatedAt: Date
    let appVersion: String
    let appBuild: String
    let macOSVersion: String
    let processorArchitecture: String
    let scanNoticeAccepted: Bool
    let standardFoldersAccessible: Bool
    let minimumFileSizeMB: Int
    let olderFileThresholdDays: Int
    let lastScan: DiagnosticsScanSummary?
}

enum DiagnosticsExportError: Error {
    case couldNotEncode
}

enum MacCleanerDiagnosticsExportService {
    static func makeReport(
        appVersion: String,
        appBuild: String,
        macOSVersion: String,
        processorArchitecture: String,
        scanNoticeAccepted: Bool,
        standardFoldersAccessible: Bool,
        minimumFileSizeMB: Int,
        olderFileThresholdDays: Int,
        lastScan: ScanResult?,
        generatedAt: Date = .now
    ) -> MacCleanerDiagnosticsReport {
        let scanSummary = lastScan.map { result in
            DiagnosticsScanSummary(
                scanType: result.kind.rawValue,
                finishedAt: result.finishedAt,
                filesChecked: result.filesVisited,
                entriesChecked: result.entriesVisited,
                bytesChecked: result.bytesVisited,
                findingsCount: result.items.count,
                skippedItemCount: result.skippedItems,
                excludedFolderCount: result.excludedLocations.count,
                entryLimit: result.entryLimit,
                wasPartial: result.wasTruncated
            )
        }

        return MacCleanerDiagnosticsReport(
            formatVersion: 2,
            generatedAt: generatedAt,
            appVersion: appVersion,
            appBuild: appBuild,
            macOSVersion: macOSVersion,
            processorArchitecture: processorArchitecture,
            scanNoticeAccepted: scanNoticeAccepted,
            standardFoldersAccessible: standardFoldersAccessible,
            minimumFileSizeMB: max(1, minimumFileSizeMB),
            olderFileThresholdDays: max(1, olderFileThresholdDays),
            lastScan: scanSummary
        )
    }

    static func encode(_ report: MacCleanerDiagnosticsReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report) else {
            throw DiagnosticsExportError.couldNotEncode
        }
        return data
    }
}
