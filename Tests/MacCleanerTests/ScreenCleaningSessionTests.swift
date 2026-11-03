import XCTest
@testable import MacCleaner

final class ScreenCleaningSessionTests: XCTestCase {
    func testAvailableDurationsAreShortAndBounded() {
        XCTAssertEqual(ScreenCleaningDuration.allCases.map(\.seconds), [30, 60, 120])
        XCTAssertEqual(ScreenCleaningDuration.allCases.map(\.title), ["30 seconds", "1 minute", "2 minutes"])
    }

    func testCountdownExpiresAtExactlyTheSelectedDuration() {
        var countdown = ScreenCleaningCountdown(duration: .quick)

        for remaining in stride(from: 29, through: 1, by: -1) {
            XCTAssertFalse(countdown.advance())
            XCTAssertEqual(countdown.remainingSeconds, remaining)
        }

        XCTAssertTrue(countdown.advance())
        XCTAssertEqual(countdown.remainingSeconds, 0)
    }

    func testFinishedCountdownStaysFinished() {
        var countdown = ScreenCleaningCountdown(duration: .quick)
        for _ in 0..<30 { _ = countdown.advance() }

        XCTAssertTrue(countdown.advance())
        XCTAssertEqual(countdown.remainingSeconds, 0)
    }

    func testRemainingTimeDescriptionShowsTheCurrentSeconds() {
        XCTAssertEqual(ScreenCleaningCountdown.remainingTimeDescription(30), "30 seconds remaining")
        XCTAssertEqual(ScreenCleaningCountdown.remainingTimeDescription(1), "1 second remaining")
        XCTAssertEqual(ScreenCleaningCountdown.remainingTimeDescription(-1), "0 seconds remaining")
    }
}
