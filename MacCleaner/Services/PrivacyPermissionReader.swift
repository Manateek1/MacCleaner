import ApplicationServices
import AVFoundation
import Contacts
import CoreGraphics
import Foundation

enum PrivacyPermissionReader {
    static var current: PrivacyPermissionSnapshot {
        PrivacyPermissionSnapshot(
            camera: .mediaCapture(AVCaptureDevice.authorizationStatus(for: .video)),
            microphone: .mediaCapture(AVCaptureDevice.authorizationStatus(for: .audio)),
            contacts: .contacts(CNContactStore.authorizationStatus(for: .contacts)),
            screenRecording: .booleanPermission(enabled: CGPreflightScreenCaptureAccess()),
            accessibility: .booleanPermission(enabled: AXIsProcessTrusted())
        )
    }
}
