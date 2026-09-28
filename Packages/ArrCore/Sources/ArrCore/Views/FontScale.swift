import SwiftUI

// MARK: - Font scale environment + modifier
//
// `.dynamicTypeSize` ignores explicit pt sizes, so fonts go through
// `scaledFont(size:)`, which multiplies by the environment scale.

private struct FontScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

public extension EnvironmentValues {
    var fontScale: Double {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

public extension View {
    /// Apply at every scene root: popover, windows and the iOS root share no ancestor,
    /// and a missing root silently falls back to 1.0.
    func appFontScale(_ configStore: ConfigStore) -> some View {
        environment(\.fontScale, configStore.effectiveFontScale)
    }
}

public extension ConfigStore {
    var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

/// `.font(.system(size:weight:design:))` scaled by the user's `fontScale` preset.
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
