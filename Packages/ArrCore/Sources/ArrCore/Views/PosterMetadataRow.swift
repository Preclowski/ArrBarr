import SwiftUI

/// Shared row chrome for poster + title + dot-joined metadata + trailing
/// accessory. Powers both the search "+" result rows (`SearchResultRow`)
/// and the Upcoming tab rows (`UpcomingRowView`) so they stay
/// pixel-identical structurally — the only differences should be what
/// goes into `metadataSegments` and what trails on the right.
///
/// Why centralise this? Both rows previously hand-rolled the same
/// HStack(poster, VStack(title, metadata), Spacer, accessory) layout
/// plus the same hover-tint background. Diverged by ~2pt on padding /
/// spacing across iterations and the user noticed; pulling it into one
/// place keeps them in lock-step from now on.
public struct PosterMetadataRow<TrailingAccessory: View>: View {
    let posterURL: URL?
    let posterAPIKey: String?
    /// Every caller so far is a list row at 26×38, comfortably inside the icon
    /// tier even at @3x — but it is a parameter rather than a constant so a
    /// future caller with a bigger poster doesn't silently get a soft one.
    let posterTier: PosterTier
    let posterSize: CGSize
    let posterCornerRadius: CGFloat
    let posterBlurred: Bool
    /// SF Symbol shown when the poster URL fails to load. Empty string
    /// (or whatever `RemotePoster` treats as missing) skips the fallback.
    let posterFallbackSymbol: String
    /// Already-formatted title — callers compose `Title (Year)` themselves
    /// since the year-suffix rule differs (movies have year, episodes
    /// don't).
    let title: String
    let metadataSegments: [String]
    /// Optional second metadata line, rendered below the first. Lets a row
    /// split overflowing metadata across two lines (e.g. Upcoming on iOS:
    /// episode info on line 1, rating/runtime/type on line 2). Empty = one line.
    let metadataSegments2: [String]
    /// Optional pill / badge rendered inline next to the title — used
    /// by Search rows to surface an "In library" tag without burning a
    /// metadata segment (a coloured chip reads at a glance; an extra
    /// "· In library" string does not). `nil` keeps the title alone.
    let titleBadge: AnyView?
    /// Right-hand accessory. Pass `EmptyView()` if you don't want one.
    let trailing: () -> TrailingAccessory
    let onTap: () -> Void
    /// When `true` the row is non-interactive (no hover tint, no tap).
    /// Used by Upcoming rows that don't have a backing `entityId` —
    /// nothing meaningful to drill into.
    let disabled: Bool
    public init(
        posterURL: URL?,
        posterAPIKey: String?,
        posterTier: PosterTier = .icon,
        posterSize: CGSize,
        posterCornerRadius: CGFloat = 3,
        posterBlurred: Bool,
        posterFallbackSymbol: String = "",
        title: String,
        metadataSegments: [String],
        metadataSegments2: [String] = [],
        titleBadge: AnyView? = nil,
        disabled: Bool = false,
        onTap: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> TrailingAccessory
    ) {
        self.posterURL = posterURL
        self.posterAPIKey = posterAPIKey
        self.posterTier = posterTier
        self.posterSize = posterSize
        self.posterCornerRadius = posterCornerRadius
        self.posterBlurred = posterBlurred
        self.posterFallbackSymbol = posterFallbackSymbol
        self.title = title
        self.metadataSegments = metadataSegments
        self.metadataSegments2 = metadataSegments2
        self.titleBadge = titleBadge
        self.disabled = disabled
        self.onTap = onTap
        self.trailing = trailing
    }

    public var body: some View {
        Button(action: onTap) {
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

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title)
                            .scaledFont(size: 12, weight: .medium)
                            .lineLimit(1)
                        if let titleBadge {
                            titleBadge
                        }
                        // Chevron telegraphs "tap to drill in" without
                        // depending on hover — works on iOS (no hover)
                        // and clarifies macOS rows too. Skipped on
                        // disabled rows (no tap target).
                        if !disabled {
                            LinkChevron(size: 9)
                        }
                    }
                    if !metadataSegments.isEmpty {
                        metadataLine(metadataSegments)
                            .scaledFont(size: 10)
                    }
                    if !metadataSegments2.isEmpty {
                        metadataLine(metadataSegments2)
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
        .buttonStyle(.plain)
        .disabled(disabled)
        // Publish the row's hover state to the drill-in LinkChevron(s)
        // inside (the title chevron + any trailing accessory chevron)
        // so they light up on row hover, not on glyph hover.
        .linkRowHover()
        // Hover-tint dropped — chevron after the title now signals
        // "tap to drill in" without depending on cursor state. Works
        // identically on macOS (mouse) and iOS (touch).
    }

    @ViewBuilder
    private func metadataLine(_ segments: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                if idx > 0 {
                    SeparatorDot()
                }
                Text(seg).foregroundStyle(.secondary)
            }
        }
    }
}
