import SwiftUI

// MARK: - Font scale environment + modifier
//
// Lets the user globally bump every UI font size via a single Settings
// preset (1.0 / 1.10 / 1.20). The codebase is full of explicit
// `.font(.system(size: N))` calls (282 sites at last count) — SwiftUI's
// native `.dynamicTypeSize(...)` only affects semantic fonts
// (`.body`, `.caption`), not explicit pt sizes, so we route every
// font definition through `scaledFont(size:)` which multiplies by the
// environment-injected scale before handing it to SwiftUI.

private struct FontScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

public extension EnvironmentValues {
    var fontScale: Double {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

/// Drop-in replacement for `.font(.system(size:weight:design:))` that
/// respects the user's `fontScale` preset. Takes the same arguments as
/// `Font.system`, plus an optional `monospacedDigit` flag to mirror the
/// chained `.monospacedDigit()` form some sites use.
///
/// Existing call:        `.font(.system(size: 11, weight: .semibold))`
/// Equivalent scaled:    `.scaledFont(size: 11, weight: .semibold)`
public extension View {
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(ScaledFontModifier(
            size: size,
            weight: weight,
            design: design,
            monospacedDigit: monospacedDigit
        ))
    }
}

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.fontScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        var font = Font.system(size: size * scale, weight: weight, design: design)
        if monospacedDigit { font = font.monospacedDigit() }
        return content.font(font)
    }
}
