import AVFoundation
import Contacts
import XCTest
@testable import MacCleaner

final class PrivacyPermissionReaderTests: XCTestCase {
    func testMediaPermissionStatusesAreDescribedWithoutRequestingAccess() {
        XCTAssertEqual(LocalPermissionStatus.mediaCapture(.notDetermined), .notRequested)
        XCTAssertEqual(LocalPermissionStatus.mediaCapture(.authorized), .allowed)
        XCTAssertEqual(LocalPermissionStatus.mediaCapture(.denied), .turnedOff)
        XCTAssertEqual(LocalPermissionStatus.mediaCapture(.restricted), .restricted)
    }

    func testContactsPermissionStatusesAreDescribedWithoutReadingContacts() {
        XCTAssertEqual(LocalPermissionStatus.contacts(.notDetermined), .notRequested)
        XCTAssertEqual(LocalPermissionStatus.contacts(.authorized), .allowed)
        XCTAssertEqual(LocalPermissionStatus.contacts(.denied), .turnedOff)
        XCTAssertEqual(LocalPermissionStatus.contacts(.restricted), .restricted)
    }

    func testBooleanPermissionStatusesDoNotPretendToKnowWhyAccessIsOff() {
        XCTAssertEqual(LocalPermissionStatus.booleanPermission(enabled: true), .allowed)
        XCTAssertEqual(LocalPermissionStatus.booleanPermission(enabled: false), .notEnabled)
        XCTAssertEqual(LocalPermissionStatus.notEnabled.displayName, "Not enabled or not yet allowed")
    }

}
