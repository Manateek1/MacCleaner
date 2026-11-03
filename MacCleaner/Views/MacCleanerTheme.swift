import SwiftUI

enum MacCleanerTheme {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor).opacity(0.42)
    static let accent = Color(nsColor: .systemBlue)
    static let primaryText = Color(nsColor: .labelColor)
    static let accentSoft = Color(nsColor: .systemBlue).opacity(0.10)
    static let accentWash = Color(nsColor: .systemBlue).opacity(0.035)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let shadow = Color.black.opacity(0.045)
}

extension View {
    func cleanerCard(cornerRadius: CGFloat = 16) -> some View {
        background(
            MacCleanerTheme.surface,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(MacCleanerTheme.border.opacity(0.82), lineWidth: 1)
        }
        .shadow(color: MacCleanerTheme.shadow, radius: 8, x: 0, y: 2)
    }
}
