import XCTest
@testable import MacCleaner

final class LocalTimeMachineSnapshotsTests: XCTestCase {
    func testParsesAndSortsTimeMachineSnapshotNamesWithoutOtherSnapshots() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-10-29-120000.local
        com.apple.TimeMachine.2026-10-30-093015.local
        com.apple.os.update-ABC123
        not-a-snapshot
        """

        let snapshots = LocalTimeMachineSnapshotService.parse(
            output,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(snapshots.map(\.name), [
            "com.apple.TimeMachine.2026-10-30-093015.local",
            "com.apple.TimeMachine.2026-10-29-120000.local"
        ])
        XCTAssertEqual(snapshots[0].createdAt.timeIntervalSince1970, 1_793_352_615, accuracy: 1)
    }

    func testEmptySnapshotListingReturnsAnEmptyInventory() async throws {
        let checkedAt = Date(timeIntervalSince1970: 1_793_252_400)
        let service = LocalTimeMachineSnapshotService(command: { "Snapshots for disk /:\n" })

        let inventory = try await service.inventory(
            checkedAt: checkedAt,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertTrue(inventory.snapshots.isEmpty)
        XCTAssertEqual(inventory.checkedAt, checkedAt)
    }

    func testCommandFailuresUsePlainLanguageWithoutExposingCommandOutput() async {
        let service = LocalTimeMachineSnapshotService(command: { throw LocalTimeMachineSnapshotError.commandFailed })

        do {
            _ = try await service.inventory()
            XCTFail("Expected a snapshot-listing failure.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "macOS couldn’t list local Time Machine snapshots. Check Time Machine and disk access, then try again.")
        }
    }
}
