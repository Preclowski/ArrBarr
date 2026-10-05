import SwiftUI

enum ShelfControlKind { case collection, mode, filter }

/// A glass button of the Roulette that grows into a panel of every choice, from the corner it sits in: on hover,
/// or on a tap where there is no pointer. While one is open the other two step aside.
struct ShelfExpandingControl<Face: View, Panel: View>: View {
    let kind: ShelfControlKind
    @Binding var open: ShelfControlKind?
    let alignment: Alignment
    let label: Text
    @ViewBuilder var face: () -> Face
    @ViewBuilder var panel: () -> Panel
    @State private var pending: Task<Void, Never>?

    private var isOpen: Bool { open == kind }
    private var isShown: Bool { open == nil || isOpen }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: isOpen ? 22 : 18, style: .continuous) }

    var body: some View {
        ZStack(alignment: alignment) {
            if isOpen {
                panel()
                    .padding(12)
                    .fixedSize()
                    .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.06)))
            } else {
                Button { open = kind } label: {
                    face()
                        .scaledFont(size: 13, weight: .semibold)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        // Clipped, so the panel is revealed by the growing glass instead of spilling out of it.
        .clipShape(shape)
        .glassEffect(isOpen ? .regular.tint(.black.opacity(0.35)) : .regular, in: shape)
        .opacity(isShown ? 1 : 0)
        .scaleEffect(isShown ? 1 : 0.8)
        .allowsHitTesting(isShown)
        .animation(isOpen ? .spring(response: 0.42, dampingFraction: 0.78) : .smooth(duration: 0.28), value: isOpen)
        .animation(.easeOut(duration: 0.2), value: isShown)
        #if os(macOS)
        .onHover { inside in
            pending?.cancel()
            if inside {
                guard !isOpen else { return }
                // A pointer passing over on its way elsewhere opens nothing.
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(90))
                    guard !Task.isCancelled else { return }
                    open = kind
                }
            } else if isOpen {
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, open == kind else { return }
                    open = nil
                }
            }
        }
        #endif
    }
}

/// A capsule track whose selected segment slides under its neighbour.
struct ShelfSegments<ID: Hashable, Label: View>: View {
    let items: [ID]
    let selected: ID?
    var height: CGFloat = 26
    let action: (ID) -> Void
    var onHover: ((ID?) -> Void)? = nil
    @ViewBuilder let label: (ID, Bool) -> Label
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { id in
                let on = id == selected
                Button { action(id) } label: {
                    label(id, on)
                        .foregroundStyle(on ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .background {
                            if on {
                                Capsule()
                                    .fill(Color.primary.opacity(0.18))
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { inside in onHover?(inside ? id : nil) }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .animation(.spring(response: 0.36, dampingFraction: 0.75), value: selected)
    }
}

/// A small-caps heading over one group of a panel, with what's picked (or hovered) on the right.
struct ShelfPanelSection<Hint: View, Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var hint: () -> Hint
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title, bundle: .module)
                    .textCase(.uppercase)
                    .tracking(0.7)
                    .scaledFont(size: 10.5, weight: .semibold)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                hint()
                    .scaledFont(size: 11.5, weight: .medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
            content()
        }
    }
}

extension ShelfPanelSection where Hint == EmptyView {
    init(title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, hint: { EmptyView() }, content: content)
    }
}

/// Every mode as a live miniature of the Roulette, on the user's own covers, starting from the one on the hero.
struct ShelfModePanel: View {
    @Binding var mode: ShelfMode
    let entries: [LibraryEntry]
    let posters: ShelfPosters
    /// The scroll's virtual index on the hero slot.
    let center: Int
    @State private var hovered: ShelfMode?
    @State private var start = Date()

    private static let tile = CGSize(width: 64, height: 80)

    var body: some View {
        VStack(spacing: 8) {
            Text((hovered ?? mode).title, bundle: .module)
                .scaledFont(size: 11.5, weight: .medium)
                .foregroundStyle(.secondary)
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                let t = timeline.date.timeIntervalSince(start)
                HStack(spacing: 6) {
                    ForEach(ShelfMode.allCases) { m in
                        tile(m, position: Double(center) + Self.stepped(t), time: t)
                    }
                }
            }
        }
    }

    private func tile(_ m: ShelfMode, position: Double, time: Double) -> some View {
        let on = m == mode
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return Button { mode = m } label: {
            VStack(spacing: 6) {
                ShelfScene(mode: m, entries: entries, posters: posters, position: position,
                           velocity: 0, time: time, size: Self.tile)
                    .frame(width: Self.tile.width, height: Self.tile.height)
                    .background(RadialGradient(colors: [Color(white: 0.16), Color(white: 0.04)],
                                               center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 70))
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .padding(2.5)
                    .overlay(RoundedRectangle(cornerRadius: 15.5, style: .continuous)
                        .strokeBorder(.white.opacity(on ? 0.92 : 0), lineWidth: 1.5))
                    .offset(y: hovered == m ? -3 : 0)
                    .scaleEffect(hovered == m ? 1.04 : 1)
                Text(m.title, bundle: .module)
                    .scaledFont(size: 10.5, weight: on ? .semibold : .medium)
                    .foregroundStyle(on ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: Self.tile.width + 5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(m.title, bundle: .module))
        .onHover { inside in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                if inside { hovered = m } else if hovered == m { hovered = nil }
            }
        }
    }

    /// The Roulette's rhythm: rest on a cover, then glide to the next.
    private static func stepped(_ t: Double) -> Double {
        let beat = t / 1.7
        let k = beat.rounded(.down)
        let f = beat - k
        guard f > 0.5 else { return k }
        let u = (f - 0.5) / 0.5
        return k + u * u * (3 - 2 * u)
    }
}
