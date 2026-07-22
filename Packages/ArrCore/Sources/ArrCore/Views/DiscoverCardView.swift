import SwiftUI

/// Build the colored rating chips for a SearchResult — same vocabulary
/// as queue/search rows (IMDb yellow, RT red, MC green, ★ TMDB fallback).
func discoverRatingChips(for result: SearchResult) -> [RatingChip] {
    var out: [RatingChip] = []
    if let imdb = result.imdb {
        out.append(RatingChip(label: "IMDb", value: String(format: "%.1f", imdb), color: .yellow))
    }
    if let rt = result.rottenTomatoes {
        out.append(RatingChip(label: "RT", value: "\(Int(rt))%", color: .red))
    }
    if let mc = result.metacritic {
        out.append(RatingChip(label: "MC", value: "\(Int(mc))", color: .green))
    }
    if result.imdb == nil, let r = result.rating {
        out.append(RatingChip(label: "★", value: String(format: "%.1f", r), color: .yellow))
    }
    return out
}

/// The immersive Quiz card: a single full-bleed poster with a bottom glass
/// scrim carrying the title / meta / a short overview and a "Więcej" link
/// that opens the full detail card. Swipe tint + stamp overlays give the
/// drag its like/skip feedback. No hover-flip back face — details live on
/// the detail card the "Więcej" link opens.
public struct DiscoverCardView: View {
    let item: DiscoverItem
    var dragOffset: CGSize = .zero
    /// Vertical space reserved at the bottom for the floating action
    /// buttons so the metadata never slides under them.
    var bottomInset: CGFloat = 0
    /// Opens the full movie/series detail card.
    var onMore: () -> Void

    public init(item: DiscoverItem,
                dragOffset: CGSize = .zero,
                bottomInset: CGFloat = 0,
                onMore: @escaping () -> Void = {}) {
        self.item = item
        self.dragOffset = dragOffset
        self.bottomInset = bottomInset
        self.onMore = onMore
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .bottomLeading) {
                // Full-bleed poster — fills the whole popover (2:3, no crop).
                RemotePoster(
                    url: item.result.posterURL,
                    apiKey: nil,
                    size: CGSize(width: w, height: h),
                    cornerRadius: 0,
                    fallbackSymbol: "film",
                    fill: true,
                    showsLoadingIndicator: true
                )
                .frame(width: w, height: h)
                .clipped()

                // Origin chip pinned top-right on the poster.
                originChip
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                // Bottom scrim — transparent at the top, opaque glass at the
                // bottom — so text + buttons read over any artwork.
                bottomGlassPanel(h: h * 0.55)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)

                // Title / meta / overview / "Więcej", lifted above the
                // floating action buttons by `bottomInset`.
                metadata
                    .padding(16)
                    .padding(.bottom, bottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(width: w, height: h)
            // Rounded corners / rim / shadow are intentionally absent: the
            // card fills the popover and NSPopover masks it to the window's
            // own rounded corners.
            .overlay(swipeTint.allowsHitTesting(false))
            .overlay(alignment: dragOffset.width > 0 ? .topLeading : .topTrailing) {
                swipeStamp
            }
        }
    }

    // MARK: - Metadata block

    @ViewBuilder
    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleAndYear)
                .scaledFont(size: 19, weight: .semibold)
                .foregroundStyle(.primary)
                .lineLimit(2)
            if !runtimeCertSegments.isEmpty {
                Text(runtimeCertSegments.joined(separator: " · "))
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            let chips = discoverRatingChips(for: item.result)
            if !chips.isEmpty {
                HStack(spacing: 5) {
                    ForEach(chips, id: \.label) { RatingPill(chip: $0) }
                }
            }
            if let overview = item.result.overview, !overview.isEmpty {
                Text(overview)
                    .scaledFont(size: 12)
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineSpacing(2)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }
            moreButton
        }
    }

    /// The "Więcej" affordance — opens the full detail / add card.
    private var moreButton: some View {
        Button(action: onMore) {
            HStack(spacing: 3) {
                Text("discover.moreDetails.button", bundle: .module)
                    .scaledFont(size: 12, weight: .semibold)
                Image(systemName: "chevron.right")
                    .scaledFont(size: 9, weight: .bold)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("discover.moreDetails.button", bundle: .module))
        #if os(macOS)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #endif
    }

    // MARK: - Helpers

    private var titleAndYear: String {
        if let y = item.result.year {
            return "\(item.result.title) (\(y))"
        }
        return item.result.title
    }

    private var runtimeCertSegments: [String] {
        [
            item.result.runtime.flatMap { $0 > 0 ? "\($0 / 60)h \($0 % 60)m" : nil },
            item.result.certification.flatMap { $0.isEmpty ? nil : $0 },
            item.result.network.flatMap { $0.isEmpty ? nil : $0 },
        ].compactMap { $0 }
    }

    /// Glass material masked by a vertical gradient — transparent at top,
    /// fully opaque (= visible glass blur) at bottom.
    @ViewBuilder
    private func bottomGlassPanel(h: CGFloat) -> some View {
        Rectangle()
            .fill(.regularMaterial)
            .mask(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.8), .black],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .frame(height: h)
    }

    @ViewBuilder
    private var originChip: some View {
        switch item.originLabel {
        case .library:
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(size: 8, weight: .semibold)
                    .foregroundStyle(Color.accentColor)
                Text("search.inLibrary.button", bundle: .module)
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                Capsule().stroke(Color.accentColor.opacity(0.6), lineWidth: 0.75)
            )
        case .tmdb:
            HStack(spacing: 3) {
                Image(systemName: "globe")
                    .scaledFont(size: 8, weight: .semibold)
                    .foregroundStyle(Color.blue)
                Text("discover.discover.button", bundle: .module)
                    .scaledFont(size: 9, weight: .medium)
                    .foregroundStyle(Color.blue)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: Capsule())
        case .llm:
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                    .scaledFont(size: 8, weight: .semibold)
                    .foregroundStyle(Color.purple)
                Text("settings.ai.label", bundle: .module)
                    .scaledFont(size: 9, weight: .medium)
                    .foregroundStyle(Color.purple)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: Capsule())
        }
    }

    // MARK: - Swipe tint / stamp

    @ViewBuilder
    private var swipeTint: some View {
        let progress = min(1.0, abs(dragOffset.width) / 180)
        if abs(dragOffset.width) > 4 {
            Rectangle()
                .fill(dragOffset.width > 0 ? Color.accentColor : Color.secondary)
                .opacity(progress * 0.40)
        }
    }

    @ViewBuilder
    private var swipeStamp: some View {
        let progress = min(1.0, abs(dragOffset.width) / 180)
        if abs(dragOffset.width) > 30 {
            let isAdd = dragOffset.width > 0
            Text(LocalizedStringKey(isAdd ? "Add" : "Skip"), bundle: .module)
                .scaledFont(size: 28, weight: .heavy)
                .textCase(.uppercase)
                .foregroundStyle(isAdd ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isAdd ? Color.accentColor : Color.secondary, lineWidth: 3)
                )
                .rotationEffect(.degrees(isAdd ? 15 : -15))
                .opacity(progress)
                .padding(24)
                .allowsHitTesting(false)
        }
    }
}
