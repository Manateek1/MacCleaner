import SwiftUI

struct ScreenCleaningModeView: View {
    @StateObject private var session = ScreenCleaningSession()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Screen Cleaning Mode")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(MacCleanerTheme.primaryText)
                    Text("Temporarily cover your displays while you clean them.")
                        .font(.title3)
                        .foregroundStyle(MacCleanerTheme.secondaryText)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label("A clear surface, with a built-in timeout", systemImage: "sparkles")
                        .font(.headline)
                Text("Mac Cleaner covers each connected display with a plain white surface. The overlay closes automatically, or you can exit sooner with the button or Escape. It does not record your input, change settings, or touch your files.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 14) {
                    Text("Choose how long to cover the displays")
                        .font(.headline)
                    HStack(spacing: 12) {
                        ForEach(ScreenCleaningDuration.allCases) { duration in
                            Button {
                                session.start(duration: duration)
                            } label: {
                                Label(duration.title, systemImage: "rectangle.inset.filled")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(MacCleanerTheme.accent)
                            .disabled(session.isActive)
                        }
                    }
                }
                .padding(18)
                .cleanerCard()

                Label("Use a soft, lint-free cloth, follow your display maker’s instructions, and never spray liquid directly onto a screen.", systemImage: "hand.raised")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onDisappear { session.stop() }
    }
}
