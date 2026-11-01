import SwiftUI

extension View {
    /// Morphs a state-driven symbol. Needs an animation in the transaction.
    func symbolSwap() -> some View { modifier(SymbolSwap()) }

    /// `symbolEffect(value:)` only fires on a change, so a symbol just inserted needs one.
    func symbolEffectOnArrival<Effect: SymbolEffect & DiscreteSymbolEffect>(_ effect: Effect) -> some View {
        modifier(SymbolArrival(effect: effect))
    }
}

private struct SymbolSwap: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
    }
}

private struct SymbolArrival<Effect: SymbolEffect & DiscreteSymbolEffect>: ViewModifier {
    let effect: Effect
    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .symbolEffect(effect, value: arrived)
            .symbolEffectsRemoved(reduceMotion)
            .onAppear { arrived = true }
    }
}
