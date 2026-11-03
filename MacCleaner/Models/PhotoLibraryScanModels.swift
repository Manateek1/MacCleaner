import Foundation
import Photos

struct PhotoLibraryPhoto: Identifiable, Sendable {
    let fingerprint: VisualPhotoFingerprint
    let modificationDate: Date?

    var id: String { fingerprint.identifier }
    var width: Int { fingerprint.width }
    var height: Int { fingerprint.height }
    var creationDate: Date? { fingerprint.createdAt }
}

struct PhotoLibraryGroup: Identifiable, Sendable {
    let photos: [PhotoLibraryPhoto]
    var id: String { photos[0].id }

    var suggestedKeep: String? {
        photos.sorted { lhs, rhs in
            let areaA = Int64(lhs.width) * Int64(lhs.height)
            let areaB = Int64(rhs.width) * Int64(rhs.height)
            if areaA != areaB { return areaA > areaB }
            if lhs.modificationDate != rhs.modificationDate {
                return (lhs.modificationDate ?? .distantFuture) < (rhs.modificationDate ?? .distantFuture)
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }.first?.id
    }
}

struct PhotoLibraryScanResult: Sendable {
    let groups: [PhotoLibraryGroup]
    let inspected: Int
    let skipped: Int
    let unavailableFromCloud: Int
    let truncated: Bool
}

enum PhotoLibraryAuthorizationState: Equatable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted
    case unknown

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .authorized
        case .limited: self = .limited
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .unknown
        }
    }

    var canRead: Bool { self == .authorized || self == .limited }

    var displayName: String {
        switch self {
        case .notDetermined: "Not requested"
        case .authorized: "Allowed"
        case .limited: "Limited access"
        case .denied: "Turned off"
        case .restricted: "Restricted by macOS"
        case .unknown: "Unavailable"
        }
    }
}

enum FirstRunPermissionPolicy {
    static func shouldRequestPhotosAccess(
        includePhotos: Bool,
        currentState: PhotoLibraryAuthorizationState
    ) -> Bool {
        includePhotos && currentState == .notDetermined
    }
}

enum PhotoLibraryCleanupSafety {
    static func hasUnselectedSurvivors(
        groups: [PhotoLibraryGroup],
        selected: Set<String>,
        currentIdentifiers: Set<String>
    ) -> Bool {
        for group in groups where group.photos.contains(where: { selected.contains($0.id) }) {
            let remaining = group.photos.filter { !selected.contains($0.id) && currentIdentifiers.contains($0.id) }
            if remaining.isEmpty { return false }
        }
        return true
    }
}

enum PhotoLibraryError: LocalizedError {
    case accessNotAllowed
    case selectedPhotosChanged
    case noUnselectedSurvivor
    case selectedPhotoCannotBeDeleted
    case deletionFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessNotAllowed: "Photos access is not enabled. Allow access in System Settings, then try again."
        case .selectedPhotosChanged: "One or more selected photos changed or disappeared. Scan again before removing anything."
        case .noUnselectedSurvivor: "At least one matching group would have no remaining photo. Change your selection and try again."
        case .selectedPhotoCannotBeDeleted: "Photos can’t remove one of the selected items. Change your selection and try again."
        case .deletionFailed(let message): "Photos couldn’t remove the selected items. \(message)"
        }
    }
}
