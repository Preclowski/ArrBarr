import SwiftUI

public struct WelcomeView: View {
    let onDismiss: () -> Void
    let onAddService: () -> Void
    let onTryDemo: () -> Void
    /// Also opens the popover, so the tour ends on the thing it just explained.
    let onFinish: () -> Void

    public init(
        onDismiss: @escaping () -> Void,
        onAddService: @escaping () -> Void,
        onTryDemo: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        self.onAddService = onAddService
        self.onTryDemo = onTryDemo
        self.onFinish = onFinish
    }

    @Environment(ConfigStore.self) var configStore
    @State private var pageIndex: Int = 0

    private var pages: [WelcomeContent.WelcomePage] { WelcomeContent.firstRunPages }

    private var current: WelcomeContent.WelcomePage {
        pages[max(0, min(pageIndex, pages.count - 1))]
    }

    private var isLastPage: Bool { pageIndex >= pages.count - 1 }

    /// Text-only pages skip the spacers, which would push their text off-centre.
    private var hasIllustration: Bool {
        switch current.id {
        case "menubar", "tonight", "customize": return true
        default: return false
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            pageContent
            Spacer(minLength: 0)
            if pages.count > 1 { pageDots.padding(.bottom, 6) }
            footer
        }
        // Not a fixed frame: any pixel beyond it shows NSWindow's background as a lighter band.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformWindowBackground)
        .overlay(alignment: .topTrailing) {
            closeButton
                .padding(.top, 8)
                .padding(.trailing, 10)
        }
        .overlay(alignment: .leading) {
            // `.opacity(0)` doesn't hide it from VoiceOver, hence `accessibilityHidden`.
            edgeArrow(direction: .previous)
                .padding(.leading, 6)
                .opacity(pageIndex > 0 ? 1 : 0)
                .allowsHitTesting(pageIndex > 0)
                .accessibilityHidden(pageIndex == 0)
        }
        .overlay(alignment: .trailing) {
            edgeArrow(direction: .next)
                .padding(.trailing, 6)
                .opacity(!isLastPage ? 1 : 0)
                .allowsHitTesting(!isLastPage)
                .accessibilityHidden(isLastPage)
        }
        // NSHostingController reserves a title-bar inset even with a transparent
        // full-size titlebar; ignoring it saves ~28pt.
        .ignoresSafeArea()
        .environment(\.locale, configStore.currentLocale)
    }

    // MARK: - Page content

    private var pageContent: some View {
        VStack(spacing: 12) {
            if hasIllustration && current.illustrationPosition == .above {
                Spacer(minLength: 12)
                heroIllustration
                Spacer(minLength: 22)
            }

            Text(LocalizedStringKey(current.titleKey), bundle: .module)
                .scaledFont(size: 18, weight: .semibold)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(LocalizedStringKey(current.bodyKey), bundle: .module)
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .lineSpacing(1)

            if let cta = current.cta {
                Button {
                    handleCTA(cta)
                } label: {
                    Label {
                        Text(LocalizedStringKey(cta.titleKey), bundle: .module)
                    } icon: {
                        Image(systemName: cta.symbol)
                    }
                }
                .controlSize(.regular)
                .padding(.top, 22)
                .padding(.bottom, 4)
            }

            if hasIllustration && current.illustrationPosition == .below {
                Spacer(minLength: 18)
                heroIllustration
                Spacer(minLength: 12)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 36)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .id(current.id)
        .transition(.opacity)
    }

    // MARK: - Hero illustrations

    @ViewBuilder
    private var heroIllustration: some View {
        Group {
            switch current.id {
            case "menubar":   MenuBarIllustration().frame(height: 110)
            case "tonight":   TonightIllustration().frame(height: 100)
            case "customize": CustomizeIllustration().frame(height: 110)
            default:          EmptyView()
            }
        }
        // Mock chrome with fake titles would sound like real library data to VoiceOver.
        .accessibilityHidden(true)
    }

    // MARK: - Page dots (clickable, hover effect)

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<pages.count, id: \.self) { i in
                PageDot(isActive: i == pageIndex) {
                    guard i != pageIndex else { return }
                    withAnimation(.easeInOut(duration: 0.22)) { pageIndex = i }
                }
                .help(Text(String(format: String(localized: "common.pageLld.label", bundle: .module), i + 1)))
                .accessibilityLabel(Text(String(format: String(localized: "common.pageLld.label", bundle: .module), i + 1)))
                .accessibilityAddTraits(i == pageIndex ? .isSelected : [])
            }
        }
    }

    // MARK: - Edge arrows

    private func edgeArrow(direction: NavDirection) -> some View {
        EdgeArrowButton(direction: direction) {
            switch direction {
            case .previous:
                guard pageIndex > 0 else { return }
                withAnimation(.easeInOut(duration: 0.22)) { pageIndex -= 1 }
            case .next:
                guard !isLastPage else { return }
                withAnimation(.easeInOut(duration: 0.22)) { pageIndex += 1 }
            }
        }
    }

    // MARK: - Close button (top-right)

    private var closeButton: some View {
        Button {
            onDismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .scaledFont(size: 17, weight: .regular)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(String(localized: "settings.close.button", bundle: .module))
        .accessibilityLabel(Text("settings.close.button", bundle: .module))
        .keyboardShortcut(.cancelAction)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if !isLastPage {
                Button(String(localized: "onboarding.tryDemoMode.button", bundle: .module)) { onTryDemo() }
                    #if os(macOS)
                    .buttonStyle(.link)
                    #else
                    .buttonStyle(.borderless)
                    #endif
            }
            Spacer()
            Button(primaryButtonTitle) { onPrimary() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var primaryButtonTitle: String {
        if !isLastPage { return String(localized: "queue.continue.button", bundle: .module) }
        return String(localized: "onboarding.done.button", bundle: .module)
    }

    private func onPrimary() {
        if !isLastPage {
            withAnimation(.easeInOut(duration: 0.22)) { pageIndex += 1 }
            return
        }
        onFinish()
    }

    private func handleCTA(_ cta: WelcomeContent.WelcomePage.CTA) {
        switch cta.kind {
        case .openURL(let url):
            PlatformURLOpener.open(url)
        case .openSettings:
            onAddService()
        }
    }
}

// MARK: - Page dot

private struct PageDot: View {
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    /// Hover only brightens, so neighbours don't reflow on every mouse move.
    private var width: CGFloat { isActive ? 18 : 7 }

    private var fillColor: Color {
        if isActive { return Color.accentColor }
        if hovering { return Color.secondary.opacity(0.65) }
        return Color.secondary.opacity(0.32)
    }

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(fillColor)
                .frame(width: width, height: 7)
                .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isActive)
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Edge arrow button

fileprivate enum NavDirection { case previous, next }

private struct EdgeArrowButton: View {
    let direction: NavDirection
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: direction == .previous ? "chevron.left" : "chevron.right")
                .scaledFont(size: 18, weight: .medium)
                .foregroundStyle(hovering ? .primary : .tertiary)
                .frame(width: 28, height: 80)
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text(direction == .previous ? "onboarding.previous.button" : "onboarding.next.button", bundle: .module))
        // Bare chevron: without this the button announces as "chevron left".
        .accessibilityLabel(Text(direction == .previous
                                 ? "onboarding.previous.button"
                                 : "onboarding.next.button", bundle: .module))
    }
}

// MARK: - Custom illustrations

private struct MenuBarIllustration: View {
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: Tokens.Radius.panel)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.platformWindowBackground.opacity(0.95),
                            Color.accentColor.opacity(0.12),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.panel)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
                )
                .frame(width: 260, height: 130)

            menuBarStrip
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .frame(width: 260, alignment: .leading)
                .background(Color.primary.opacity(0.08))
                .clipShape(
                    .rect(topLeadingRadius: 10, bottomLeadingRadius: 0,
                          bottomTrailingRadius: 0, topTrailingRadius: 10)
                )

            popoverSketch
                .frame(width: 110, height: 90)
                .offset(x: 70, y: 18)
        }
        .frame(width: 260, height: 130)
    }

    private var menuBarStrip: some View {
        HStack(spacing: 7) {
            Image(systemName: "applelogo")
                .scaledFont(size: 9, weight: .semibold)
                .foregroundStyle(.primary)
            Text(verbatim: "ArrBarr").scaledFont(size: 9, weight: .semibold)
            Text("queue.file.button", bundle: .module).scaledFont(size: 9).foregroundStyle(.primary.opacity(0.85))
            Text("onboarding.view.button", bundle: .module).scaledFont(size: 9).foregroundStyle(.primary.opacity(0.85))
            Spacer()
            Image(systemName: "wifi").scaledFont(size: 9).foregroundStyle(.secondary)
            Image(systemName: "battery.100percent").scaledFont(size: 9).foregroundStyle(.secondary)
            statusItemBadge
            Text(verbatim: "9:41").scaledFont(size: 9, weight: .medium).foregroundStyle(.secondary)
        }
    }

    private var statusItemBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.down.circle.fill")
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(.tint)
            Text(verbatim: "3").scaledFont(size: 9, weight: .semibold)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.accentColor.opacity(0.22)))
        .overlay(
            Capsule().strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 0.8)
        )
    }

    private var popoverSketch: some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(Color.platformWindowBackground)
                .overlay(Triangle().stroke(Color.secondary.opacity(0.30), lineWidth: 0.5))
                .frame(width: 10, height: 5)
                .offset(y: 0.5)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(
                                [Color.blue, Color.purple, Color.orange][i].opacity(0.55)
                            )
                            .frame(width: 10, height: 14)
                        VStack(alignment: .leading, spacing: 1.5) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.primary.opacity(0.55))
                                .frame(width: CGFloat([42, 50, 36][i]), height: 4)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.secondary.opacity(0.45))
                                .frame(width: CGFloat([28, 36, 22][i]), height: 3)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.card)
                    .fill(Color.platformWindowBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.Radius.card)
                            .strokeBorder(Color.secondary.opacity(0.30), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            )
        }
    }
}

nonisolated private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct TonightIllustration: View {
    /// Mirrors the real Tonight banner and UpcomingRowView's layout.
    var body: some View {
        VStack(spacing: 0) {
            tonightHeader
                .padding(.horizontal, 10)
                .padding(.top, 7)
                .padding(.bottom, 5)
            upcomingRow(
                posterColor: .blue.opacity(0.55),
                title: "Pioneer One",
                subtitle: "S01E03 · Endurance",
                timeLabel: "9:41 PM",
                releaseType: "upcoming.type.airing"
            )
            upcomingRow(
                posterColor: .purple.opacity(0.55),
                title: "Sintel",
                subtitle: nil,
                timeLabel: "11:30 PM",
                releaseType: "upcoming.type.digital"
            )
        }
        .frame(width: 260)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.5)
                )
        )
    }

    private var tonightHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "moon.stars.fill")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text("onboarding.tonight.button", bundle: .module)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(.primary)
            Text(verbatim: "2")
                .scaledFont(size: 9, weight: .semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
            Spacer()
        }
    }

    private func upcomingRow(
        posterColor: Color,
        title: String,
        subtitle: String?,
        timeLabel: String,
        releaseType: LocalizedStringKey
    ) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    LinearGradient(
                        colors: [posterColor, posterColor.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 18, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .scaledFont(size: 9)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text(timeLabel)
                    .scaledFont(size: 9, weight: .medium)
                    .foregroundStyle(.secondary)
                Text(releaseType, bundle: .module)
                    .scaledFont(size: 8, weight: .medium)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

private struct CustomizeIllustration: View {
    private struct Row: Identifiable {
        let id: Int
        let symbol: String
        let label: Text
        let on: Bool
    }

    private let rows: [Row] = [
        Row(id: 0, symbol: "moon.stars.fill",         label: Text("onboarding.tonight.button", bundle: .module), on: true),
        Row(id: 1, symbol: "exclamationmark.bubble.fill", label: Text("queue.needsYou.button", bundle: .module), on: true),
        Row(id: 2, symbol: "server.rack",             label: Text(verbatim: "Lidarr"), on: false),
    ]

    var body: some View {
        VStack(spacing: 5) {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.symbol)
                        .scaledFont(size: 11, weight: .regular)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    row.label
                        .scaledFont(size: 11)
                        .foregroundStyle(.primary)
                    Spacer()
                    miniToggle(on: row.on)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.secondary.opacity(0.08))
                )
            }
        }
        .frame(width: 200)
    }

    private func miniToggle(on: Bool) -> some View {
        Capsule()
            .fill(on ? Color.accentColor : Color.secondary.opacity(0.35))
            .frame(width: 22, height: 12)
            .overlay(
                Circle()
                    .fill(.white)
                    .frame(width: 9, height: 9)
                    .offset(x: on ? 5 : -5)
            )
    }
}