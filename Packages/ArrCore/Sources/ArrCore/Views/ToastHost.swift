import SwiftUI

extension View {
    /// Draws `ToastCenter` as a bottom pill, above the floating search capsule and chat field.
    func toastHost() -> some View { modifier(ToastHost()) }
}

private struct ToastHost: ViewModifier {
    private var center: ToastCenter { .shared }

    #if os(macOS)
    private static let bottomClearance: CGFloat = 56
    #else
    private static let bottomClearance: CGFloat = 64
    #endif

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = center.current {
                    ToastPill(toast: toast)
                        .id(toast.id)
                        .padding(.horizontal, 16)
                        .padding(.bottom, Self.bottomClearance)
                        .transition(.asymmetric(
                            insertion: .offset(y: 10).combined(with: .scale(scale: 0.96, anchor: .bottom)).combined(with: .opacity),
                            removal: .offset(y: 6).combined(with: .opacity)))
                }
            }
            .animation(.smooth(duration: 0.3), value: center.current?.id)
    }
}

private struct ToastPill: View {
    let toast: Toast
    private var center: ToastCenter { .shared }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(symbolTint)
            HStack(spacing: 4) {
                Text(toast.title, bundle: .module)
                    .fontWeight(.semibold)
                    .fixedSize()
                if let detail = toast.detail, !detail.isEmpty {
                    Text(verbatim: "· \(detail)")
                        .foregroundStyle(.secondary)
                        .truncationMode(.tail)
                }
            }
            .lineLimit(1)
            if let action = toast.action {
                Divider().frame(height: 14)
                Button {
                    center.dismiss()
                    action.perform()
                } label: {
                    Text(action.label, bundle: .module)
                        .fontWeight(.semibold)
                        .foregroundStyle(Self.accent)
                        .fixedSize()
                }
                .buttonStyle(.plain)
            }
        }
        .scaledFont(size: 12.5)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .glassyFloatingBar()
        .onHover { $0 ? center.hold() : center.release() }
        .accessibilityElement(children: .combine)
    }

    /// Solid system colours: SwiftUI's wash out over the menu-bar panel's vibrancy.
    private var symbolTint: Color {
        switch toast.tone {
        case .success: Self.platform(.systemGreen)
        case .failure: Self.platform(.systemOrange)
        case .neutral: .secondary
        }
    }

    #if os(macOS)
    private static let accent = Color(nsColor: .controlAccentColor)
    private static func platform(_ color: NSColor) -> Color { Color(nsColor: color) }
    #else
    private static let accent = Color.accentColor
    private static func platform(_ color: UIColor) -> Color { Color(uiColor: color) }
    #endif
}
