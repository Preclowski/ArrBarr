import SwiftUI

/// Shared poster + title + metadata + accessory row for Search and Upcoming, so their layout can't drift.
struct PosterMetadataRow<TitleBadge: View, MetadataBadge: View, MetadataBadge2: View, TrailingAccessory: View>: View {
    let posterURL: URL?
    let posterAPIKey: String?
    /// A parameter, not a constant, so a bigger poster doesn't silently get a soft thumbnail tier.
    let posterTier: PosterTier
    let posterSize: CGSize
    let posterCornerRadius: CGFloat
    let posterBlurred: Bool
    let posterFallbackSymbol: String
    /// `posterMonitored` is `nil` on rows that don't know the flag (a search hit, an upcoming episode).
    let posterWatched: Bool
    let posterMonitored: Bool?
    let posterLibraryMark: LibraryMark?
    /// Callers compose `Title (Year)` themselves: episodes have no year suffix.
    let title: String
    let metadataSegments: [String]
    /// Aligned by index with `metadataSegments`; may be shorter. `nil` keeps `.secondary`.
    let metadataSegmentColors: [Color?]
    let metadataSegments2: [String]
    @ViewBuilder let titleBadge: () -> TitleBadge
    @ViewBuilder let metadataBadge: () -> MetadataBadge
    @ViewBuilder let metadataBadge2: () -> MetadataBadge2
    let trailing: () -> TrailingAccessory
    let onTap: () -> Void
    let disabled: Bool
    init(
        posterURL: URL?,
        posterAPIKey: String?,
        posterTier: PosterTier = .icon,
        posterSize: CGSize,
        posterCornerRadius: CGFloat = 3,
        posterBlurred: Bool,
        posterFallbackSymbol: String = "",
        posterWatched: Bool = false,
        posterMonitored: Bool? = nil,
        posterLibraryMark: LibraryMark? = nil,
        title: String,
        metadataSegments: [String],
        metadataSegmentColors: [Color?] = [],
        metadataSegments2: [String] = [],
        disabled: Bool = false,
        onTap: @escaping () -> Void,
        @ViewBuilder titleBadge: @escaping () -> TitleBadge,
        @ViewBuilder metadataBadge: @escaping () -> MetadataBadge,
        @ViewBuilder metadataBadge2: @escaping () -> MetadataBadge2,
        @ViewBuilder trailing: @escaping () -> TrailingAccessory
    ) {
        self.posterURL = posterURL
        self.posterAPIKey = posterAPIKey
        self.posterTier = posterTier
        self.posterSize = posterSize
        self.posterCornerRadius = posterCornerRadius
        self.posterBlurred = posterBlurred
        self.posterFallbackSymbol = posterFallbackSymbol
        self.posterWatched = posterWatched
        self.posterMonitored = posterMonitored
        self.posterLibraryMark = posterLibraryMark
        self.title = title
        self.metadataSegments = metadataSegments
        self.metadataSegmentColors = metadataSegmentColors
        self.metadataSegments2 = metadataSegments2
        self.titleBadge = titleBadge
        self.metadataBadge = metadataBadge
        self.metadataBadge2 = metadataBadge2
        self.disabled = disabled
        self.onTap = onTap
        self.trailing = trailing
    }

    var body: some View {
        // Not a disabled Button: that greys the whole label, which reads as "unavailable".
        if disabled {
            rowContent
        } else {
            Button(action: onTap) { rowContent }
                .buttonStyle(.plain)
                // Row hover lights the title chevron, not just hovering the glyph.
                .linkRowHover()
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            PosterBlurContainer(blurred: posterBlurred, cornerRadius: posterCornerRadius) {
                RemotePoster(
                    url: posterURL,
                    apiKey: posterAPIKey,
                    tier: posterTier,
                    size: posterSize,
                    cornerRadius: posterCornerRadius,
                    fallbackSymbol: posterFallbackSymbol
                )
            }
            .posterMarks(watched: posterWatched, monitored: posterMonitored, library: posterLibraryMark,
                         cornerRadius: posterCornerRadius,
                         ribbonWidth: max(5, posterSize.width * 0.2))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .scaledFont(size: 12, weight: .medium)
                        .lineLimit(1)
                    titleBadge()
                    // Hover-independent drill-in affordance, since iOS has no hover.
                    if !disabled {
                        LinkChevron(size: 9)
                    }
                }
                if hasMetadataBadge || !metadataSegments.isEmpty {
                    HStack(spacing: 5) {
                        metadataBadge()
                        metadataLine(metadataSegments, colors: metadataSegmentColors)
                    }
                    .scaledFont(size: 10)
                }
                if hasMetadataBadge2 || !metadataSegments2.isEmpty {
                    HStack(spacing: 5) {
                        metadataBadge2()
                        metadataLine(metadataSegments2, colors: [])
                    }
                    .scaledFont(size: 10)
                }
            }

            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    /// Read off the type: a row without a badge is `EmptyView` at compile time.
    private var hasMetadataBadge: Bool { MetadataBadge.self != EmptyView.self }
    private var hasMetadataBadge2: Bool { MetadataBadge2.self != EmptyView.self }

    @ViewBuilder
    private func metadataLine(_ segments: [String], colors: [Color?]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                if idx > 0 {
                    SeparatorDot()
                }
                Text(seg)
                    .lineLimit(1)
                    .foregroundStyle(
                        (idx < colors.count ? colors[idx] : nil)
                            .map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)
                    )
            }
        }
    }
}


// MARK: - Badge-free initialisers
//
// Generic badges rather than `AnyView` so SwiftUI updates rows in place in a scrolling list.
extension PosterMetadataRow where TitleBadge == EmptyView, MetadataBadge == EmptyView, MetadataBadge2 == EmptyView {
    init(
        posterURL: URL?,
        posterAPIKey: String?,
        posterTier: PosterTier = .icon,
        posterSize: CGSize,
        posterCornerRadius: CGFloat = 3,
        posterBlurred: Bool,
        posterFallbackSymbol: String = "",
        posterWatched: Bool = false,
        posterMonitored: Bool? = nil,
        posterLibraryMark: LibraryMark? = nil,
        title: String,
        metadataSegments: [String],
        metadataSegmentColors: [Color?] = [],
        metadataSegments2: [String] = [],
        disabled: Bool = false,
        onTap: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> TrailingAccessory
    ) {
        self.init(posterURL: posterURL, posterAPIKey: posterAPIKey, posterTier: posterTier,
                  posterSize: posterSize, posterCornerRadius: posterCornerRadius,
                  posterBlurred: posterBlurred, posterFallbackSymbol: posterFallbackSymbol,
                  posterWatched: posterWatched, posterMonitored: posterMonitored,
                  posterLibraryMark: posterLibraryMark,
                  title: title, metadataSegments: metadataSegments,
                  metadataSegmentColors: metadataSegmentColors,
                  metadataSegments2: metadataSegments2, disabled: disabled, onTap: onTap,
                  titleBadge: { EmptyView() }, metadataBadge: { EmptyView() },
                  metadataBadge2: { EmptyView() }, trailing: trailing)
    }
}

extension PosterMetadataRow where MetadataBadge == EmptyView, MetadataBadge2 == EmptyView {
    init(
        posterURL: URL?,
        posterAPIKey: String?,
        posterTier: PosterTier = .icon,
        posterSize: CGSize,
        posterCornerRadius: CGFloat = 3,
        posterBlurred: Bool,
        posterFallbackSymbol: String = "",
        posterWatched: Bool = false,
        posterMonitored: Bool? = nil,
        posterLibraryMark: LibraryMark? = nil,
        title: String,
        metadataSegments: [String],
        metadataSegmentColors: [Color?] = [],
        metadataSegments2: [String] = [],
        disabled: Bool = false,
        onTap: @escaping () -> Void,
        @ViewBuilder titleBadge: @escaping () -> TitleBadge,
        @ViewBuilder trailing: @escaping () -> TrailingAccessory
    ) {
        self.init(posterURL: posterURL, posterAPIKey: posterAPIKey, posterTier: posterTier,
                  posterSize: posterSize, posterCornerRadius: posterCornerRadius,
                  posterBlurred: posterBlurred, posterFallbackSymbol: posterFallbackSymbol,
                  posterWatched: posterWatched, posterMonitored: posterMonitored,
                  posterLibraryMark: posterLibraryMark,
                  title: title, metadataSegments: metadataSegments,
                  metadataSegmentColors: metadataSegmentColors,
                  metadataSegments2: metadataSegments2, disabled: disabled, onTap: onTap,
                  titleBadge: titleBadge, metadataBadge: { EmptyView() },
                  metadataBadge2: { EmptyView() }, trailing: trailing)
    }
}

extension PosterMetadataRow where TitleBadge == EmptyView, MetadataBadge2 == EmptyView {
    init(
        posterURL: URL?,
        posterAPIKey: String?,
        posterTier: PosterTier = .icon,
        posterSize: CGSize,
        posterCornerRadius: CGFloat = 3,
        posterBlurred: Bool,
        posterFallbackSymbol: String = "",
        posterWatched: Bool = false,
        posterMonitored: Bool? = nil,
        posterLibraryMark: LibraryMark? = nil,
        title: String,
        metadataSegments: [String],
        metadataSegmentColors: [Color?] = [],
        metadataSegments2: [String] = [],
        disabled: Bool = false,
        onTap: @escaping () -> Void,
        @ViewBuilder metadataBadge: @escaping () -> MetadataBadge,
        @ViewBuilder trailing: @escaping () -> TrailingAccessory
    ) {
        self.init(posterURL: posterURL, posterAPIKey: posterAPIKey, posterTier: posterTier,
                  posterSize: posterSize, posterCornerRadius: posterCornerRadius,
                  posterBlurred: posterBlurred, posterFallbackSymbol: posterFallbackSymbol,
                  posterWatched: posterWatched, posterMonitored: posterMonitored,
                  posterLibraryMark: posterLibraryMark,
                  title: title, metadataSegments: metadataSegments,
                  metadataSegmentColors: metadataSegmentColors,
                  metadataSegments2: metadataSegments2, disabled: disabled, onTap: onTap,
                  titleBadge: { EmptyView() }, metadataBadge: metadataBadge,
                  metadataBadge2: { EmptyView() }, trailing: trailing)
    }
}


extension PosterMetadataRow where TitleBadge == EmptyView, MetadataBadge == EmptyView {
    init(
        posterURL: URL?,
        posterAPIKey: String?,
        posterTier: PosterTier = .icon,
        posterSize: CGSize,
        posterCornerRadius: CGFloat = 3,
        posterBlurred: Bool,
        posterFallbackSymbol: String = "",
        posterWatched: Bool = false,
        posterMonitored: Bool? = nil,
        posterLibraryMark: LibraryMark? = nil,
        title: String,
        metadataSegments: [String],
        metadataSegmentColors: [Color?] = [],
        metadataSegments2: [String] = [],
        disabled: Bool = false,
        onTap: @escaping () -> Void,
        @ViewBuilder metadataBadge2: @escaping () -> MetadataBadge2,
        @ViewBuilder trailing: @escaping () -> TrailingAccessory
    ) {
        self.init(posterURL: posterURL, posterAPIKey: posterAPIKey, posterTier: posterTier,
                  posterSize: posterSize, posterCornerRadius: posterCornerRadius,
                  posterBlurred: posterBlurred, posterFallbackSymbol: posterFallbackSymbol,
                  posterWatched: posterWatched, posterMonitored: posterMonitored,
                  posterLibraryMark: posterLibraryMark,
                  title: title, metadataSegments: metadataSegments,
                  metadataSegmentColors: metadataSegmentColors,
                  metadataSegments2: metadataSegments2, disabled: disabled, onTap: onTap,
                  titleBadge: { EmptyView() }, metadataBadge: { EmptyView() },
                  metadataBadge2: metadataBadge2, trailing: trailing)
    }
}
