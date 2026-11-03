import Foundation
import UserNotifications

enum ActivityNotificationKind: String, CaseIterable, Sendable {
    case scanCompleted
    case cleanupCompleted
    case appUpdateSourceCheckCompleted
    case appSecurityCheckCompleted
    case macHealthCheckCompleted

    var preferenceKey: String {
        switch self {
        case .scanCompleted: "MacCleaner.notifications.scanCompleted"
        case .cleanupCompleted: "MacCleaner.notifications.cleanupCompleted"
        case .appUpdateSourceCheckCompleted: "MacCleaner.notifications.appUpdateSourceCheckCompleted"
        case .appSecurityCheckCompleted: "MacCleaner.notifications.appSecurityCheckCompleted"
        case .macHealthCheckCompleted: "MacCleaner.notifications.macHealthCheckCompleted"
        }
    }

    var title: String { "Mac Cleaner" }

    var message: String {
        switch self {
        case .scanCompleted: "Your local scan is ready to review. Open Mac Cleaner to see what it found."
        case .cleanupCompleted: "Your cleanup review is complete. Open Mac Cleaner to review the result."
        case .appUpdateSourceCheckCompleted: "An app update source check has finished. Open Mac Cleaner to review its result."
        case .appSecurityCheckCompleted: "Your App Security check is ready to review. Open Mac Cleaner to see its summary."
        case .macHealthCheckCompleted: "A Mac Health check has finished. Open Mac Cleaner to review its result."
        }
    }
}

enum ActivityNotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

enum ActivityNotificationEnableResult: Equatable, Sendable {
    case enabled
    case denied
    case failed
}

@MainActor
protocol ActivityNotificationClient: AnyObject {
    func authorizationStatus() async -> ActivityNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func schedule(title: String, message: String, identifier: String) async throws
}

@MainActor
final class ActivityNotificationService {
    static let shared = ActivityNotificationService()

    private let client: ActivityNotificationClient
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.client = SystemActivityNotificationClient()
        self.defaults = defaults
    }

    init(client: ActivityNotificationClient, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
    }

    func enable(_ kind: ActivityNotificationKind) async -> ActivityNotificationEnableResult {
        switch await client.authorizationStatus() {
        case .authorized:
            defaults.set(true, forKey: kind.preferenceKey)
            return .enabled
        case .denied:
            defaults.set(false, forKey: kind.preferenceKey)
            return .denied
        case .notDetermined:
            do {
                guard try await client.requestAuthorization() else {
                    defaults.set(false, forKey: kind.preferenceKey)
                    return .denied
                }
                defaults.set(true, forKey: kind.preferenceKey)
                return .enabled
            } catch {
                defaults.set(false, forKey: kind.preferenceKey)
                return .failed
            }
        }
    }

    func authorizationStatus() async -> ActivityNotificationAuthorization {
        await client.authorizationStatus()
    }

    func notifyIfEnabled(_ kind: ActivityNotificationKind) async {
        guard defaults.bool(forKey: kind.preferenceKey),
              await client.authorizationStatus() == .authorized else { return }
        do {
            try await client.schedule(
                title: kind.title,
                message: kind.message,
                identifier: "\(kind.rawValue).\(UUID().uuidString)"
            )
        } catch {
            // A notification failure must never interrupt a scan or cleanup.
        }
    }
}

@MainActor
private final class SystemActivityNotificationClient: ActivityNotificationClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        center.delegate = ActivityNotificationDelegate.shared
    }

    func authorizationStatus() async -> ActivityNotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func schedule(title: String, message: String, identifier: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

private final class ActivityNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ActivityNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
