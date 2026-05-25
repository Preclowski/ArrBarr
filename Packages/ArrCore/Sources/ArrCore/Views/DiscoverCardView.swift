import SwiftUI

public struct DiscoverCardView: View {
    let item: DiscoverItem
    let onSwipeRight: () -> Void
    let onSwipeLeft: () -> Void

    public init(item: DiscoverItem,
                onSwipeRight: @escaping () -> Void,
                onSwipeLeft: @escaping () -> Void) {
        self.item = item
        self.onSwipeRight = onSwipeRight
        self.onSwipeLeft = onSwipeLeft
    }

    public var body: some View {
        VStack(spacing: 12) {
            card
            actionRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The whole poster surface IS the card. Title, year, origin chip,
    /// and (optional) short overview live on a dark gradient pasted on
    /// the poster's bottom edge — tinder-style.
    private var card: some View {
        // Aspect 2:3, sized to fit the popover's content column. The
        // GeometryReader gives us the available width and we lock height
        // to width × 1.5, so the card scales if the popover ever grows.
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = w * 1.5

            ZStack(alignment: .bottomLeading) {
                RemotePoster(url: item.result.posterURL, apiKey: nil)
                    .frame(width: w, height: h)
                    .clipped()

                // Bottom darkening gradient — gives the text legible
                // contrast against any poster artwork.
                LinearGradient(
                    colors: [.black.opacity(0.85), .black.opacity(0.0)],
                    startPoint: .bottom, endPoint: .top
                )
                .frame(height: h * 0.45)
                .frame(maxHeight: .infinity, alignment: .bottom)

                // Top-left origin chip — small, also gets a subtle gradient
                // shield so it stays legible on bright posters.
                originChip
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topLeading)

                // Bottom overlay: title + year on top, optional 2-line
                // overview below. Padding pulls them off the bottom edge.
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.result.title)
                        .scaledFont(size: 18, weight: .bold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let y = item.result.year {
                        Text(verbatim: "\(y)")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    if let overview = item.result.overview, !overview.isEmpty {
                        Text(overview)
                            .scaledFont(size: 11)
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
        }
        // The GeometryReader collapses to zero-height by default — we
        // pin an aspect ratio so the layout actually reserves the space.
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
    }

    private var originChip: some View {
        HStack(spacing: 4) {
            Image(systemName: originIcon)
                .scaledFont(size: 10, weight: .semibold)
            Text(originLabel, bundle: .module)
                .scaledFont(size: 10, weight: .semibold)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(.ultraThinMaterial))
    }

    private var originIcon: String {
        switch item.originLabel {
        case .tmdb:    return "film"
        case .library: return "books.vertical"
        case .llm:     return "sparkles"
        }
    }

    private var originLabel: LocalizedStringKey {
        switch item.originLabel {
        case .tmdb:    return "From TMDB"
        case .library: return "From your library"
        case .llm:     return "From AI"
        }
    }

    /// Two fat CTAs split 50/50, matching the rest of the app's button
    /// vocabulary via the shared Glass modifiers (already in scope from
    /// PopoverContentView.swift). Left = neutral Skip, right = prominent
    /// action whose label/icon switch on `item.action`.
    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(action: onSwipeLeft) {
                Label {
                    Text("Skip", bundle: .module)
                } icon: {
                    Image(systemName: "xmark")
                }
                .scaledFont(size: 13, weight: .semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .modifier(GlassButtonStyle())
            .controlSize(.large)
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button(action: onSwipeRight) {
                Label {
                    Text(rightLabel, bundle: .module)
                } icon: {
                    Image(systemName: rightIcon)
                }
                .scaledFont(size: 13, weight: .semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .modifier(GlassProminentButtonStyle())
            .controlSize(.large)
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
    }

    private var rightIcon: String {
        switch item.action {
        case .addToRadarr: return "plus"
        case .openDetail:  return "play.fill"
        }
    }
    private var rightLabel: LocalizedStringKey {
        switch item.action {
        case .addToRadarr: return "Add to Radarr"
        case .openDetail:  return "Watch"
        }
    }
}
