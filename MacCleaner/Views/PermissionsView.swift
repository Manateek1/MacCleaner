import AppKit
import SwiftUI

struct PermissionsView: View {
    @ObservedObject var model: ScanViewModel
    let onOpenSmartScan: () -> Void
    let onOpenSimilarPhotos: () -> Void
    let onOpenAppUpdater: () -> Void

    @State private var photoAccess = PhotoLibraryAccess.currentAuthorization
    @State private var optionalAccess = PrivacyPermissionReader.current
    @AppStorage("MacCleaner.applicationUpdater.feedNoticeAccepted.v1") private var updateFeedNoticeAccepted = false

    private var photoStatusDescription: String {
        switch photoAccess {
        case .notDetermined:
            "Access has not been requested. Start a Photos scan when you want to use this feature."
        case .authorized:
            "Mac Cleaner can review pictures in your Photos library that are available on this Mac."
        case .limited:
            "macOS lets Mac Cleaner see only the Photos items you selected."
        case .denied:
            "Photos access is turned off. Change it in System Settings, then return and scan again."
        case .restricted:
            "This Mac or its management settings restrict Photos access."
        case .unknown:
            "macOS did not return a Photos access status."
        }
    }

    private var canUsePhotos: Bool { photoAccess.canRead }
    private var needsPhotosSettings: Bool { photoAccess == .denied || photoAccess == .restricted }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                permissionsHeader
                accessNotice
                corePermissionCards
                OptionalPermissionsSection(access: optionalAccess)
            }
            .frame(maxWidth: 840, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            refreshPhotoAccess()
            if model.scanNoticeAccepted { model.refreshDiskAccessStatusInBackground() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPhotoAccess()
        }
    }

    private var permissionsHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Privacy & Permissions")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(MacCleanerTheme.primaryText)
            Text("See what Mac Cleaner can access and manage scan setup in one place.")
                .font(.title3)
                .foregroundStyle(MacCleanerTheme.secondaryText)
        }
    }

    private var accessNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("macOS controls access", systemImage: "lock.shield")
                .font(.headline)
            Text("Mac Cleaner uses Full Disk Access to scan local folders without asking you to choose each one. Photos access is separate and used only for Similar Photos. macOS controls each permission and any change you make in System Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var corePermissionCards: some View {
        VStack(spacing: 12) {
            permissionCard(
                symbol: "internaldrive.fill",
                title: "Mac disk scans",
                status: model.standardFoldersAccessible ? "Ready" : (model.standardFoldersChecked ? "Needs setup" : "Not checked"),
                ready: model.standardFoldersAccessible,
                description: model.standardFoldersAccessible
                    ? "Documents and Downloads are accessible. Mac Cleaner can scan local folders across your Mac; other protected locations are reported if macOS still blocks them."
                    : (model.standardFoldersChecked
                        ? "Enable Mac Cleaner under Full Disk Access in System Settings, then return and scan. You only need to do this once."
                        : "Mac Cleaner checks whether Documents and Downloads can be opened after you accept the first-run notice. It does not read your files before that."),
                actionTitle: model.standardFoldersAccessible ? "Open Smart Scan" : "Open Full Disk Access Settings",
                action: {
                    if model.standardFoldersAccessible { onOpenSmartScan() }
                    else { model.openFullDiskAccessSettings() }
                }
            )

            permissionCard(
                symbol: "photo.on.rectangle.angled",
                title: "Photos Library",
                status: photoAccess.displayName,
                ready: canUsePhotos,
                description: photoStatusDescription,
                actionTitle: needsPhotosSettings ? "Open System Settings" : "Open Similar Photos",
                action: needsPhotosSettings ? openSystemSettings : onOpenSimilarPhotos
            )

            permissionCard(
                symbol: "arrow.down.app",
                title: "App update checks",
                status: updateFeedNoticeAccepted ? "Manual checks ready" : "Notice on first check",
                ready: updateFeedNoticeAccepted,
                description: "When you check an app's secure update feed, its publisher receives ordinary connection information. Mac Cleaner does not send file names or contents and does not download installers.",
                actionTitle: "Open App Updater",
                action: onOpenAppUpdater
            )
        }
    }

    private func permissionCard(
        symbol: String,
        title: String,
        status: String,
        ready: Bool,
        description: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(MacCleanerTheme.accent)
                .frame(width: 42, height: 42)
                .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(title).font(.headline)
                    Text(status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ready ? Color(nsColor: .systemGreen) : MacCleanerTheme.secondaryText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background((ready ? Color(nsColor: .systemGreen) : MacCleanerTheme.secondaryText).opacity(0.12), in: Capsule())
                }
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard()
    }

    private func refreshPhotoAccess() {
        photoAccess = PhotoLibraryAccess.currentAuthorization
        optionalAccess = PrivacyPermissionReader.current
    }

    private func openSystemSettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app", isDirectory: true))
    }
}

private struct OptionalPermissionsSection: View {
    let access: PrivacyPermissionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Optional permissions").font(.headline)
                Text("Mac Cleaner does not use these permissions to scan or clean files. Status checks do not trigger a macOS prompt.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LocalPermissionRow(title: "Camera", symbol: "camera", status: access.camera, settingsAnchor: "Privacy_Camera")
            Divider()
            LocalPermissionRow(title: "Microphone", symbol: "mic", status: access.microphone, settingsAnchor: "Privacy_Microphone")
            Divider()
            LocalPermissionRow(title: "Contacts", symbol: "person.crop.circle", status: access.contacts, settingsAnchor: "Privacy_Contacts")
            Divider()
            LocalPermissionRow(title: "Screen Recording", symbol: "record.circle", status: access.screenRecording, settingsAnchor: "Privacy_ScreenCapture")
            Divider()
            LocalPermissionRow(title: "Accessibility", symbol: "accessibility", status: access.accessibility, settingsAnchor: "Privacy_Accessibility")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanerCard()
    }
}

private struct LocalPermissionRow: View {
    let title: String
    let symbol: String
    let status: LocalPermissionStatus
    let settingsAnchor: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MacCleanerTheme.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.callout.weight(.medium))
                    Text(status.displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status.isEnabled ? Color(nsColor: .systemGreen) : MacCleanerTheme.secondaryText)
                }
                Text(status.isEnabled
                     ? "Enabled in macOS; Mac Cleaner does not use it."
                     : "Not needed by Mac Cleaner. This check did not request access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("View Settings") {
                openSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
    }

    private func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")
        if let url, NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app", isDirectory: true))
    }
}
