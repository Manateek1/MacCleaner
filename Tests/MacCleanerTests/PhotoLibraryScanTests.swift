import Foundation
import Photos
import XCTest
@testable import MacCleaner

final class PhotoLibraryScanTests: XCTestCase {
    func testAuthorizationStatesSeparateReadAccessFromDenial() {
        XCTAssertTrue(PhotoLibraryAuthorizationState(.authorized).canRead)
        XCTAssertTrue(PhotoLibraryAuthorizationState(.limited).canRead)
        XCTAssertFalse(PhotoLibraryAuthorizationState(.notDetermined).canRead)
        XCTAssertFalse(PhotoLibraryAuthorizationState(.denied).canRead)
        XCTAssertFalse(PhotoLibraryAuthorizationState(.restricted).canRead)
    }

    func testAuthorizationStatesHavePlainLanguageNames() {
        XCTAssertEqual(PhotoLibraryAuthorizationState(.notDetermined).displayName, "Not requested")
        XCTAssertEqual(PhotoLibraryAuthorizationState(.authorized).displayName, "Allowed")
        XCTAssertEqual(PhotoLibraryAuthorizationState(.limited).displayName, "Limited access")
        XCTAssertEqual(PhotoLibraryAuthorizationState(.denied).displayName, "Turned off")
        XCTAssertEqual(PhotoLibraryAuthorizationState(.restricted).displayName, "Restricted by macOS")
    }

    func testFirstRunRequestsPhotosOnlyWhenSelectedAndNotPreviouslyDecided() {
        XCTAssertTrue(FirstRunPermissionPolicy.shouldRequestPhotosAccess(
            includePhotos: true,
            currentState: .notDetermined
        ))
        XCTAssertFalse(FirstRunPermissionPolicy.shouldRequestPhotosAccess(
            includePhotos: false,
            currentState: .notDetermined
        ))
        XCTAssertFalse(FirstRunPermissionPolicy.shouldRequestPhotosAccess(
            includePhotos: true,
            currentState: .authorized
        ))
        XCTAssertFalse(FirstRunPermissionPolicy.shouldRequestPhotosAccess(
            includePhotos: true,
            currentState: .denied
        ))
    }

    func testRemovalRequiresAGroupMemberThatStillExistsAndIsNotSelected() {
        let group = PhotoLibraryGroup(photos: [photo("one"), photo("two")])

        XCTAssertTrue(PhotoLibraryCleanupSafety.hasUnselectedSurvivors(
            groups: [group],
            selected: ["one"],
            currentIdentifiers: ["one", "two"]
        ))
        XCTAssertFalse(PhotoLibraryCleanupSafety.hasUnselectedSurvivors(
            groups: [group],
            selected: ["one"],
            currentIdentifiers: ["one"]
        ))
        XCTAssertFalse(PhotoLibraryCleanupSafety.hasUnselectedSurvivors(
            groups: [group],
            selected: ["one", "two"],
            currentIdentifiers: ["one", "two"]
        ))
    }

    private func photo(_ identifier: String) -> PhotoLibraryPhoto {
        let fingerprint = VisualPhotoFingerprint(
            identifier: identifier,
            width: 100,
            height: 100,
            hash: 0,
            average: 100,
            pixels: [UInt8](repeating: 100, count: 72),
            duplicateIdentity: nil,
            createdAt: nil
        )
        return PhotoLibraryPhoto(fingerprint: fingerprint, modificationDate: nil)
    }
}
