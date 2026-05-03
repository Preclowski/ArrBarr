import SwiftUI
import AppKit

struct WelcomeView: View {
    let variant: WelcomeContent.Variant
    let onDismiss: () -> Void
    let onAddService: () -> Void
    let onTryDemo: () -> Void
    /// Called when the user clicks the final "Done" button — closes the
    /// welcome window AND opens the popover so the tour ends by showing the
    /// thing the user just learned about.
    let onFinish: () -> Void

    @EnvironmentObject var configStore: ConfigStore
    @State private var pageIndex: Int = 0

    private var pages: [WelcomeContent.WelcomePage] {
        WelcomeContent.pages(for: variant)
    }

    private var current: WelcomeContent.WelcomePage {
        pages[max(0, min(pageIndex, pages.count - 1))]
    }

    private var isLastPage: Bool { pageIndex >= pages.count - 1 }

    /// True if the current page has a custom illustration to render. Used to
    /// skip the spacer scaffolding for pages that show only text + CTA — those
    /// would otherwise have their text pushed off-center by empty spacers
    /// wrapping an EmptyView.
    private var hasIllustration: Bool {
        switch current.id {
        case "menubar", "tonight", "customize": return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            pageContent
            Spacer(minLength: 0)
            if pages.count > 1 { pageDots.padding(.bottom, 6) }
            footer
        }
        // Fill whatever the NSHostingView gives us instead of a fixed frame —
        // the window's `setContentSize` is the source of truth. With a fixed
        // .frame(width:height:), any pixel of the hosting view beyond our
        // 400×440 box would show NSWindow's own background colour, which
        // reads as a lighter band under the action buttons.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topTrailing) {
            closeButton
                .padding(.top, 8)
                .padding(.trailing, 10)
        }
        .overlay(alignment: .leading) {
            edgeArrow(direction: .previous)
                .padding(.leading, 6)
                .opacity(pageIndex > 0 ? 1 : 0)
                .allowsHitTesting(pageIndex > 0)
        }
        .overlay(alignment: .trailing) {
            edgeArrow(direction: .next)
                .padding(.trailing, 6)
                .opacity(!isLastPage ? 1 : 0)
                .allowsHitTesting(!isLastPage)
        }
        // The window has .fullSizeContentView with a transparent titlebar, but
        // NSHostingController still reserves safe-area inset for the title-bar
        // region. Ignoring it lets our content (and the X close button) sit at
        // the actual top of the window instead of being pushed down ~28pt.
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

            Text(LocalizedStringKey(current.titleKey))
                .font(.system(size: 18, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(LocalizedStringKey(current.bodyKey))
                .font(.system(size: 12))
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
                        Text(LocalizedStringKey(cta.titleKey))
                    } icon: {
                        Image(systemName: cta.symbol)
                    }
                }
                .controlSize(.regular)
                .padding(.top, 22)
                .padding(.bottom, 4)
            }

            if hasIllustration && current.illustrationPosition == .below {
                // Flexible spacer pushes the illustration toward the visual
                // centre of the window so it's the focal point rather than a
                // footnote under the text.
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
    //
    // Only pages that have a real custom illustration render anything here.
    // Pages without one (e.g. Connect, Star) intentionally have no hero —
    // the title + body + CTA stand on their own, which keeps the window
    // free of generic "icon in a circle" placeholders.

    @ViewBuilder
    private var heroIllustration: some View {
        switch current.id {
        case "menubar":   MenuBarIllustration().frame(height: 110)
        case "tonight":   TonightIllustration().frame(height: 100)
        case "customize": CustomizeIllustration().frame(height: 110)
        default:          EmptyView()
        }
    }

    // MARK: - Page dots (clickable, hover effect)

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<pages.count, id: \.self) { i in
                PageDot(isActive: i == pageIndex) {
                    guard i != pageIndex else { return }
                    withAnimation(.easeInOut(duration: 0.22)) { pageIndex = i }
                }
                .help("Page \(i + 1)")
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
                .font(.system(size: 17, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(String(localized: "Close"))
        .keyboardShortcut(.cancelAction)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if case .firstRun = variant, !isLastPage {
                Button(String(localized: "Try demo mode")) { onTryDemo() }
                    .buttonStyle(.link)
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
        if !isLastPage { return String(localized: "Continue") }
        return String(localized: "Done")
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
            NSWorkspace.shared.open(url)
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

    /// Hover only brightens the dot — it doesn't change width — so neighbours
    /// don't reflow on every mouse move. The active dot animates from a 7pt
    /// circle to an 18pt pill (Apple's pattern) when its state changes; that
    /// width change happens at most once per click, never on hover.
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

    /// Bare chevron, no background. Sits on a tall transparent hit area so
    /// it's easy to click but invisible until you hover. Color goes from
    /// nearly-invisible tertiary to primary on hover.
    var body: some View {
        Button(action: action) {
            Image(systemName: direction == .previous ? "chevron.left" : "chevron.right")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(hovering ? .primary : .tertiary)
                .frame(width: 28, height: 80)
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(direction == .previous ? "Previous" : "Next")
    }
}

// MARK: - Custom illustrations

private struct MenuBarIllustration: View {
    /// Mock display with a menu bar strip up top and a small popover
    /// "preview" hanging from the ArrBarr status item — exactly what the
    /// app actually does when you click its menu-bar icon.
    var body: some View {
        ZStack(alignment: .top) {
            // Background "screen" card
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor).opacity(0.95),
                            Color.accentColor.opacity(0.12),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
                )
                .frame(width: 260, height: 130)

            // Menu bar strip
            menuBarStrip
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .frame(width: 260, alignment: .leading)
                .background(Color.primary.opacity(0.08))
                .clipShape(
                    .rect(topLeadingRadius: 10, bottomLeadingRadius: 0,
                          bottomTrailingRadius: 0, topTrailingRadius: 10)
                )

            // Popover sketch hanging from the status item
            popoverSketch
                .frame(width: 110, height: 90)
                .offset(x: 70, y: 18)
        }
        .frame(width: 260, height: 130)
    }

    private var menuBarStrip: some View {
        HStack(spacing: 7) {
            Image(systemName: "applelogo")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.primary)
            Text("ArrBarr").font(.system(size: 9, weight: .semibold))
            Text("File").font(.system(size: 9)).foregroundStyle(.primary.opacity(0.85))
            Text("View").font(.system(size: 9)).foregroundStyle(.primary.opacity(0.85))
            Spacer()
            Image(systemName: "wifi").font(.system(size: 9)).foregroundStyle(.secondary)
            Image(systemName: "battery.100percent").font(.system(size: 9)).foregroundStyle(.secondary)
            statusItemBadge
            Text("9:41").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    private var statusItemBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tint)
            Text("3").font(.system(size: 9, weight: .semibold))
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
            // Tail / arrow pointing up to the status item
            Triangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(Triangle().stroke(Color.secondary.opacity(0.30), lineWidth: 0.5))
                .frame(width: 10, height: 5)
                .offset(y: 0.5)

            // Popover body — abstract row stack
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
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.30), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            )
        }
    }
}

/// Small downward-pointing triangle used as the popover tail.
private struct Triangle: Shape {
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
    /// Mirrors the real Tonight banner from PopoverContentView: a "Tonight"
    /// header row with the moon icon and count badge, followed by upcoming
    /// rows that match UpcomingRowView's layout (small poster, title +
    /// subtitle, time + release-type on the right).
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
                releaseType: "Airing"
            )
            upcomingRow(
                posterColor: .purple.opacity(0.55),
                title: "Sintel",
                subtitle: nil,
                timeLabel: "11:30 PM",
                releaseType: "Digital"
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text("Tonight")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Text("2")
                .font(.system(size: 9, weight: .semibold))
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
        releaseType: String
    ) -> some View {
        HStack(spacing: 8) {
            // Mini poster — same 24x36 ratio as UpcomingRowView
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text(timeLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(releaseType)
                    .font(.system(size: 8, weight: .medium))
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
        let label: String
        let on: Bool
    }

    private let rows: [Row] = [
        Row(id: 0, symbol: "moon.stars.fill",         label: "Tonight",   on: true),
        Row(id: 1, symbol: "exclamationmark.bubble.fill", label: "Needs you", on: true),
        Row(id: 2, symbol: "server.rack",             label: "Lidarr",    on: false),
    ]

    var body: some View {
        VStack(spacing: 5) {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.symbol)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(row.label)
                        .font(.system(size: 11))
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
