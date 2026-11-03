import XCTest
@testable import MacCleaner

final class ActivityNotificationServiceTests: XCTestCase {
    @MainActor
    func testFirstEnableRequestsAuthorizationAndPersistsPreference() async throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = TestActivityNotificationClient(status: .notDetermined, authorizationResult: true)
        let service = ActivityNotificationService(client: client, defaults: defaults)

        let result = await service.enable(.scanCompleted)

        XCTAssertEqual(result, .enabled)
        XCTAssertEqual(client.authorizationRequestCount, 1)
        XCTAssertTrue(defaults.bool(forKey: ActivityNotificationKind.scanCompleted.preferenceKey))
    }

    @MainActor
    func testDeniedAuthorizationIsNotRequestedAgain() async throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = TestActivityNotificationClient(status: .denied, authorizationResult: true)
        let service = ActivityNotificationService(client: client, defaults: defaults)

        let result = await service.enable(.cleanupCompleted)

        XCTAssertEqual(result, .denied)
        XCTAssertEqual(client.authorizationRequestCount, 0)
        XCTAssertFalse(defaults.bool(forKey: ActivityNotificationKind.cleanupCompleted.preferenceKey))
    }

    @MainActor
    func testDecliningFirstRequestLeavesPreferenceOff() async throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = TestActivityNotificationClient(status: .notDetermined, authorizationResult: false)
        let service = ActivityNotificationService(client: client, defaults: defaults)

        let result = await service.enable(.scanCompleted)

        XCTAssertEqual(result, .denied)
        XCTAssertEqual(client.authorizationRequestCount, 1)
        XCTAssertFalse(defaults.bool(forKey: ActivityNotificationKind.scanCompleted.preferenceKey))
    }

    @MainActor
    func testCompletionNotificationUsesOnlyGenericLocalCopyAndEnabledPreference() async throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = TestActivityNotificationClient(status: .authorized, authorizationResult: true)
        let service = ActivityNotificationService(client: client, defaults: defaults)

        await service.notifyIfEnabled(.scanCompleted)
        XCTAssertTrue(client.scheduledNotifications.isEmpty)

        defaults.set(true, forKey: ActivityNotificationKind.scanCompleted.preferenceKey)
        await service.notifyIfEnabled(.scanCompleted)

        XCTAssertEqual(client.scheduledNotifications.count, 1)
        XCTAssertEqual(client.scheduledNotifications.first?.title, "Mac Cleaner")
        XCTAssertFalse(client.scheduledNotifications.first?.message.contains("/") ?? true)
    }

    @MainActor
    func testAppUpdateSourceCheckNotificationIsGenericAndPreferenceGated() async throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = TestActivityNotificationClient(status: .authorized, authorizationResult: true)
        let service = ActivityNotificationService(client: client, defaults: defaults)

        await service.notifyIfEnabled(.appUpdateSourceCheckCompleted)
        XCTAssertTrue(client.scheduledNotifications.isEmpty)

        defaults.set(true, forKey: ActivityNotificationKind.appUpdateSourceCheckCompleted.preferenceKey)
        await service.notifyIfEnabled(.appUpdateSourceCheckCompleted)

        XCTAssertEqual(client.scheduledNotifications.count, 1)
        XCTAssertEqual(client.scheduledNotifications.first?.title, "Mac Cleaner")
        XCTAssertEqual(
            client.scheduledNotifications.first?.message,
            "An app update source check has finished. Open Mac Cleaner to review its result."
        )
    }

    @MainActor
    func testAppSecurityNotificationIsGenericAndPreferenceGated() async throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = TestActivityNotificationClient(status: .authorized, authorizationResult: true)
        let service = ActivityNotificationService(client: client, defaults: defaults)

        await service.notifyIfEnabled(.appSecurityCheckCompleted)
        XCTAssertTrue(client.scheduledNotifications.isEmpty)

        defaults.set(true, forKey: ActivityNotificationKind.appSecurityCheckCompleted.preferenceKey)
        await service.notifyIfEnabled(.appSecurityCheckCompleted)

        XCTAssertEqual(client.scheduledNotifications.count, 1)
        XCTAssertEqual(client.scheduledNotifications.first?.title, "Mac Cleaner")
        XCTAssertEqual(
            client.scheduledNotifications.first?.message,
            "Your App Security check is ready to review. Open Mac Cleaner to see its summary."
        )
        XCTAssertFalse(client.scheduledNotifications.first?.message.contains("/") ?? true)
    }

    @MainActor
    func testMacHealthNotificationIsGenericAndPreferenceGated() async throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = TestActivityNotificationClient(status: .authorized, authorizationResult: true)
        let service = ActivityNotificationService(client: client, defaults: defaults)

        await service.notifyIfEnabled(.macHealthCheckCompleted)
        XCTAssertTrue(client.scheduledNotifications.isEmpty)

        defaults.set(true, forKey: ActivityNotificationKind.macHealthCheckCompleted.preferenceKey)
        await service.notifyIfEnabled(.macHealthCheckCompleted)

        XCTAssertEqual(client.scheduledNotifications.count, 1)
        XCTAssertEqual(
            client.scheduledNotifications.first?.message,
            "A Mac Health check has finished. Open Mac Cleaner to review its result."
        )
        XCTAssertFalse(client.scheduledNotifications.first?.message.contains("/") ?? true)
    }

    @MainActor
    private func makeDefaults() throws -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "MacCleanerActivityNotifications.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}

@MainActor
private final class TestActivityNotificationClient: ActivityNotificationClient {
    private(set) var status: ActivityNotificationAuthorization
    private let authorizationResult: Bool
    private(set) var authorizationRequestCount = 0
    private(set) var scheduledNotifications: [(title: String, message: String, identifier: String)] = []

    init(status: ActivityNotificationAuthorization, authorizationResult: Bool) {
        self.status = status
        self.authorizationResult = authorizationResult
    }

    func authorizationStatus() async -> ActivityNotificationAuthorization { status }

    func requestAuthorization() async throws -> Bool {
        authorizationRequestCount += 1
        status = authorizationResult ? .authorized : .denied
        return authorizationResult
    }

    func schedule(title: String, message: String, identifier: String) async throws {
        scheduledNotifications.append((title, message, identifier))
    }
}
