import SwiftUI

struct DiffTag: View {
    enum Style { case new, old }
    let text: String
    let style: Style

    public var body: some View {
        Text(text)
            .scaledFont(size: 9, weight: .bold, monospacedDigit: true)
            .tracking(0.5)
            .foregroundStyle(style == .new ? Color.accentColor : Color.secondary)
            .frame(width: 30, height: 14)
            .background(
                style == .new
                    ? Color.accentColor.opacity(0.18)
                    : Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 3)
            )
    }
}
