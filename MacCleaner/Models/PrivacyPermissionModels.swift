import AVFoundation
import Contacts
import Foundation

enum LocalPermissionStatus: Equatable, Sendable {
    case allowed
    case notRequested
    case turnedOff
    case restricted
    case notEnabled
    case unavailable

    var displayName: String {
        switch self {
        case .allowed: "Allowed"
        case .notRequested: "Not requested"
        case .turnedOff: "Turned off"
        case .restricted: "Restricted by macOS"
        case .notEnabled: "Not enabled or not yet allowed"
        case .unavailable: "Unavailable"
        }
    }

    var isEnabled: Bool { self == .allowed }

    static func mediaCapture(_ status: AVAuthorizationStatus) -> Self {
        switch status {
        case .authorized: .allowed
        case .notDetermined: .notRequested
        case .denied: .turnedOff
        case .restricted: .restricted
        @unknown default: .unavailable
        }
    }

    static func contacts(_ status: CNAuthorizationStatus) -> Self {
        switch status {
        case .authorized: .allowed
        case .notDetermined: .notRequested
        case .denied: .turnedOff
        case .restricted: .restricted
        @unknown default: .unavailable
        }
    }

    static func booleanPermission(enabled: Bool) -> Self {
        enabled ? .allowed : .notEnabled
    }
}

struct PrivacyPermissionSnapshot: Equatable, Sendable {
    let camera: LocalPermissionStatus
    let microphone: LocalPermissionStatus
    let contacts: LocalPermissionStatus
    let screenRecording: LocalPermissionStatus
    let accessibility: LocalPermissionStatus
}
