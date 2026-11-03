import Foundation
import Security

enum ApplicationTrustCheckStatus: Equatable, Sendable {
    case validated
    case notarizationRevoked
    case unsigned
    case couldNotVerify
    case cancelled

    var title: String {
        switch self {
        case .validated: "macOS code check passed"
        case .notarizationRevoked: "Notarization revoked"
        case .unsigned: "No code signature"
        case .couldNotVerify: "Could not complete check"
        case .cancelled: "Check cancelled"
        }
    }

    var symbol: String {
        switch self {
        case .validated: "checkmark.shield.fill"
        case .notarizationRevoked: "xmark.shield.fill"
        case .unsigned: "questionmark.shield"
        case .couldNotVerify: "exclamationmark.shield"
        case .cancelled: "stop.circle"
        }
    }
}

struct ApplicationTrustCheck: Equatable, Sendable {
    let status: ApplicationTrustCheckStatus
    let hasStapledNotarizationTicket: Bool?

    var explanation: String {
        switch status {
        case .validated:
            "macOS validated this app's signed code. This does not determine whether its behavior is safe or free of malware."
        case .notarizationRevoked:
            "macOS reports that this app's notarization was revoked. Investigate the app before opening it."
        case .unsigned:
            "No code signature was found, so macOS could not check its signer or notarization. This alone does not mean the app is harmful."
        case .couldNotVerify:
            "macOS could not complete this code check. The app was left unchanged."
        case .cancelled:
            "The check was cancelled. The app was left unchanged."
        }
    }
}

struct ApplicationTrustCheckService: Sendable {
    static var networkValidationFlags: SecCSFlags {
        SecCSFlags(rawValue: ApplicationSecurityAuditService.validationFlags.rawValue | kSecCSAllowNetworkAccess)
    }

    func check(
        appURL: URL,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> ApplicationTrustCheck {
        guard !isCancelled() else {
            return ApplicationTrustCheck(status: .cancelled, hasStapledNotarizationTicket: nil)
        }
        guard appURL.pathExtension.lowercased() == "app",
              SafeFilePolicy.hasNoSymlinkedParent(path: appURL.path, root: "/") else {
            return ApplicationTrustCheck(status: .couldNotVerify, hasStapledNotarizationTicket: nil)
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode else {
            return ApplicationTrustCheck(status: .couldNotVerify, hasStapledNotarizationTicket: nil)
        }

        var rawInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        )
        if informationStatus == errSecCSUnsigned {
            return ApplicationTrustCheck(status: .unsigned, hasStapledNotarizationTicket: false)
        }
        guard informationStatus == errSecSuccess,
              let information = rawInformation as? [String: Any] else {
            return ApplicationTrustCheck(status: .couldNotVerify, hasStapledNotarizationTicket: nil)
        }

        guard !isCancelled() else {
            return ApplicationTrustCheck(status: .cancelled, hasStapledNotarizationTicket: nil)
        }
        let hasStapledTicket = information[kSecCodeInfoStapledNotarizationTicket as String] != nil
        let validityStatus = SecStaticCodeCheckValidity(staticCode, Self.networkValidationFlags, nil)
        guard !isCancelled() else {
            return ApplicationTrustCheck(status: .cancelled, hasStapledNotarizationTicket: nil)
        }
        return Self.classify(validityStatus: validityStatus, hasStapledTicket: hasStapledTicket)
    }

    static func classify(validityStatus: OSStatus, hasStapledTicket: Bool) -> ApplicationTrustCheck {
        if validityStatus == errSecSuccess {
            return ApplicationTrustCheck(status: .validated, hasStapledNotarizationTicket: hasStapledTicket)
        }
        if validityStatus == errSecCSRevokedNotarization {
            return ApplicationTrustCheck(status: .notarizationRevoked, hasStapledNotarizationTicket: hasStapledTicket)
        }
        if validityStatus == errSecCSUnsigned {
            return ApplicationTrustCheck(status: .unsigned, hasStapledNotarizationTicket: false)
        }
        return ApplicationTrustCheck(status: .couldNotVerify, hasStapledNotarizationTicket: hasStapledTicket)
    }
}
