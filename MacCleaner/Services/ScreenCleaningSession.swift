import AppKit
import SwiftUI

enum ScreenCleaningDuration: Int, CaseIterable, Identifiable, Sendable {
    case quick = 30
    case standard = 60
    case extended = 120

    var id: Int { rawValue }
    var seconds: Int { rawValue }

    var title: String {
        switch self {
        case .quick: "30 seconds"
        case .standard: "1 minute"
        case .extended: "2 minutes"
        }
    }
}

struct ScreenCleaningCountdown: Equatable, Sendable {
    private(set) var remainingSeconds: Int

    static func remainingTimeDescription(_ seconds: Int) -> String {
        let remaining = max(0, seconds)
        return "\(remaining) second\(remaining == 1 ? "" : "s") remaining"
    }

    init(duration: ScreenCleaningDuration) {
        remainingSeconds = duration.seconds
    }

    /// Advances one second and returns true when the session has expired.
    mutating func advance() -> Bool {
        guard remainingSeconds > 0 else { return true }
        remainingSeconds -= 1
        return remainingSeconds == 0
    }
}

@MainActor
final class ScreenCleaningSession: ObservableObject {
    @Published private(set) var secondsRemaining = 0

    private var panels: [ScreenCleaningPanel] = []
    private var countdown: ScreenCleaningCountdown?
    private var countdownTask: Task<Void, Never>?

    var isActive: Bool { !panels.isEmpty }

    func start(duration: ScreenCleaningDuration) {
        guard panels.isEmpty, let mainScreen = NSScreen.main else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        countdown = ScreenCleaningCountdown(duration: duration)
        secondsRemaining = duration.seconds

        for screen in screens {
            let panel = ScreenCleaningPanel(contentRect: screen.frame)
            panel.level = .screenSaver
            panel.backgroundColor = .white
            panel.isOpaque = true
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isMovable = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentView = NSHostingView(rootView: ScreenCleaningOverlay(session: self))
            panels.append(panel)
            panel.orderFrontRegardless()
        }

        NSApp.activate(ignoringOtherApps: true)
        panels.first(where: { $0.frame.equalTo(mainScreen.frame) })?.makeKeyAndOrderFront(nil)
        startCountdown()
    }

    func stop() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        secondsRemaining = 0

        let closingPanels = panels
        panels.removeAll()
        closingPanels.forEach { panel in
            panel.orderOut(nil)
            panel.close()
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self, var countdown = self.countdown else { return }
                let expired = countdown.advance()
                self.countdown = countdown
                self.secondsRemaining = countdown.remainingSeconds
                if expired {
                    self.stop()
                    return
                }
            }
        }
    }
}

private final class ScreenCleaningPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }
}

private struct ScreenCleaningOverlay: View {
    @ObservedObject var session: ScreenCleaningSession

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(MacCleanerTheme.accent)
                Text("Screen cleaning mode")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Use a soft, lint-free cloth and follow the display maker’s cleaning instructions. Never spray liquid directly onto a screen.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 400)
                Text(ScreenCleaningCountdown.remainingTimeDescription(session.secondsRemaining))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(MacCleanerTheme.accent)
                    .padding(.top, 4)
                Button("Exit Cleaning Mode", action: session.stop)
                    .buttonStyle(.borderedProminent)
                    .tint(MacCleanerTheme.accent)
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, 3)
                Text("Press Escape to exit at any time")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(28)
            .frame(maxWidth: 500)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand(perform: session.stop)
    }
}
