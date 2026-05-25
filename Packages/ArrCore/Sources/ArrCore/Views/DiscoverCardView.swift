import SwiftUI

/// Build the colored rating chips for a SearchResult — same vocabulary
/// as queue/search rows (IMDb yellow, RT red, MC green, ★ TMDB fallback).
func discoverRatingChips(for result: SearchResult) -> [RatingChip] {
    var out: [RatingChip] = []
    if let imdb = result.imdb {
        out.append(RatingChip(label: "IMDb",
                              value: String(format: "%.1f", imdb),
                              color: .yellow))
    }
    if let rt = result.rottenTomatoes {
        out.append(RatingChip(label: "RT", value: "\(Int(rt))%", color: .red))
    }
    if let mc = result.metacritic {
        out.append(RatingChip(label: "MC", value: "\(Int(mc))", color: .green))
    }
    if result.imdb == nil, let r = result.rating {
        out.append(RatingChip(label: "★",
                              value: String(format: "%.1f", r),
                              color: .yellow))
    }
    return out
}

public struct DiscoverCardView: View {
    let item: DiscoverItem
    @Binding var isHovered: Bool
    var dragOffset: CGSize = .zero

    public init(item: DiscoverItem,
                isHovered: Binding<Bool>,
                dragOffset: CGSize = .zero) {
        self.item = item
        self._isHovered = isHovered
        self.dragOffset = dragOffset
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .leading) {
                // 1) The poster card — always rendered, just tilted when
                //    hovered. The drawer overlays it on the left.
                frontFace(w: w, h: h)
                    .rotation3DEffect(
                        .degrees(isHovered ? 8 : 0),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: .trailing,
                        perspective: 0.5
                    )

                // 2) The drawer — slides in from the left edge of the
                //    card, covers ~65% of the card width. Hidden by
                //    default (offset off-screen left).
                if isHovered && abs(dragOffset.width) < 10 {
                    infoDrawer(w: w * 0.80, h: h)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .frame(width: w, height: h)
            .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
        }
    }

    // MARK: - Shared helpers

    private var titleWithYear: String {
        if let y = item.result.year { return "\(item.result.title) (\(y))" }
        return item.result.title
    }

    private var runtimeCertSegments: [String] {
        [
            item.result.runtime.flatMap { $0 > 0 ? "\($0) min" : nil },
            item.result.certification.flatMap { $0.isEmpty ? nil : $0 },
            item.result.network.flatMap { $0.isEmpty ? nil : $0 },
        ].compactMap { $0 }
    }

    private var frontMetadataLine: String {
        var parts: [String] = []
        if let r = item.result.runtime, r > 0 {
            parts.append("\(r) min")
        }
        if let c = item.result.certification, !c.isEmpty {
            parts.append(c)
        }
        // Always include a primary rating fallback so the line never disappears.
        if let imdb = item.result.imdb {
            parts.append(String(format: "IMDb %.1f", imdb))
        } else if let r = item.result.rating {
            parts.append(String(format: "★ %.1f", r))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var originChip: some View {
        switch item.originLabel {
        case .library:
            InLibraryBadge()
        case .tmdb:
            TagChip(text: "Discover", color: .blue)
        case .llm:
            TagChip(text: "AI", color: .purple)
        }
    }

    // MARK: - Swipe tint / stamp

    @ViewBuilder
    private var swipeTint: some View {
        let progress = min(1.0, abs(dragOffset.width) / 180)
        if abs(dragOffset.width) > 4 {
            Rectangle()
                .fill(dragOffset.width > 0 ? Color.green : Color.red)
                .opacity(progress * 0.40)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var swipeStamp: some View {
        let progress = min(1.0, abs(dragOffset.width) / 180)
        if abs(dragOffset.width) > 30 {
            let isPick = dragOffset.width > 0
            Text(LocalizedStringKey(isPick ? "Pick" : "Skip"), bundle: .module)
                .scaledFont(size: 28, weight: .heavy)
                .textCase(.uppercase)
                .foregroundStyle(isPick ? Color.green : Color.red)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isPick ? Color.green : Color.red, lineWidth: 3)
                )
                .rotationEffect(.degrees(isPick ? 15 : -15))
                .opacity(progress)
                .padding(24)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Front face

    @ViewBuilder
    private func frontFace(w: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.black

            RemotePoster(
                url: item.result.posterURL,
                apiKey: nil,
                size: CGSize(width: w, height: h),
                cornerRadius: 16
            )

            // Origin chip top-left
            originChip
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topLeading)

            // Bottom dark gradient — covers ~50% of card height for
            // the info block below to read clearly.
            LinearGradient(
                colors: [.black.opacity(0.95), .black.opacity(0.0)],
                startPoint: .bottom, endPoint: .top
            )
            .frame(height: h * 0.50)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            // Bottom info block — title(year) / runtime·cert / ratings / genres
            VStack(alignment: .leading, spacing: 5) {
                Text(titleWithYear)
                    .scaledFont(size: 17, weight: .bold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)

                if !frontMetadataLine.isEmpty {
                    Text(frontMetadataLine)
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.95))
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                }

                let chips = discoverRatingChips(for: item.result)
                if !chips.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(chips, id: \.label) { RatingPill(chip: $0) }
                    }
                    .padding(.top, 2)
                }

                if !item.result.genres.isEmpty {
                    Text(item.result.genres.prefix(3).joined(separator: " · "))
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(swipeTint)
        .overlay(alignment: dragOffset.width > 0 ? .topLeading : .topTrailing) {
            swipeStamp
        }
        .overlay(
            // 1) Crisp outer border — what catches light on the card's edge.
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.32), lineWidth: 1)
        )
        .overlay(
            // 2) Inner bottom highlight — a thin gradient on the bottom edge
            //    suggesting card thickness. Just 4pt tall.
            VStack {
                Spacer()
                LinearGradient(
                    colors: [.white.opacity(0.0), .white.opacity(0.18)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 4)
                .blendMode(.plusLighter)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.45), radius: 12, x: 0, y: 4)
        .shadow(color: .black.opacity(0.20), radius: 4, x: 0, y: 1)
    }

    // MARK: - Info drawer

    @ViewBuilder
    private func infoDrawer(w: CGFloat, h: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            originChip
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(titleWithYear)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !runtimeCertSegments.isEmpty {
                    Text(runtimeCertSegments.joined(separator: " · "))
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(.secondary)
                }
            }

            let chips = discoverRatingChips(for: item.result)
            if !chips.isEmpty {
                HStack(spacing: 5) {
                    ForEach(chips, id: \.label) { RatingPill(chip: $0) }
                }
            }

            if !item.result.genres.isEmpty {
                Text(item.result.genres.prefix(4).joined(separator: " · "))
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider().opacity(0.25)

            if let overview = item.result.overview, !overview.isEmpty {
                ScrollView {
                    Text(overview)
                        .scaledFont(size: 12)
                        .foregroundStyle(.primary)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No overview available", bundle: .module)
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: w, height: h, alignment: .topLeading)
        // Single-layer glass — thinMaterial so the poster bleeds through.
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.thinMaterial)
        )
        .overlay(
            // Sharp edge highlight — light catching the top of a glass pane.
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.40), .white.opacity(0.10), .white.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 4, x: 1, y: 0)
    }
}
