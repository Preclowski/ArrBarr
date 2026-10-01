import SwiftUI

/// A pushed page that settles into place (a short fade up from slightly smaller) instead of sliding in from the side.
private struct SettleEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown || reduceMotion ? 1 : 0.97)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: 0.2)) { shown = true }
            }
    }
}

extension View {
    func settleEntrance() -> some View { modifier(SettleEntrance()) }
}
