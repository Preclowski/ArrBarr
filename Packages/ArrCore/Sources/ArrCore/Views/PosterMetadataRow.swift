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
    /// Right-hand accessory. Pass `EmptyView()` if you don't want one.
    let trailing: () -> TrailingAccessory
    let onTap: () -> Void
    /// When `true` the row is non-interactive (no hover tint, no tap).
    /// Used by Upcoming rows that don't have a backing `entityId` —
    /// nothing meaningful to drill into.
    let disabled: Bool

    @State private var isHovering = false

    public init(
        posterURL: URL?,
        posterAPIKey: String?,
        posterSize: CGSize,
        posterCornerRadius: CGFloat = 3,
        posterBlurred: Bool,
        posterFallbackSymbol: String = "",
        title: String,
        metadataSegments: [String],
        disabled: Bool = false,
        onTap: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> TrailingAccessory
    ) {
        self.posterURL = posterURL
        self.posterAPIKey = posterAPIKey
        self.posterSize = posterSize
        self.posterCornerRadius = posterCornerRadius
        self.posterBlurred = posterBlurred
        self.posterFallbackSymbol = posterFallbackSymbol
        self.title = title
        self.metadataSegments = metadataSegments
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
                        size: posterSize,
                        cornerRadius: posterCornerRadius,
                        fallbackSymbol: posterFallbackSymbol
                    )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if !metadataSegments.isEmpty {
                        metadataLine
                            .font(.system(size: 10))
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
        #if os(macOS)
        // Same hover-tint signal both rows used to roll independently.
        // Padding-horizontal 6 insets the highlight from the row edge —
        // gives it a "selected card" feel rather than a full-bleed bar.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering && !disabled ? Color.primary.opacity(0.06) : Color.clear)
                .padding(.horizontal, 6)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        #endif
    }

    @ViewBuilder
    private var metadataLine: some View {
        HStack(spacing: 4) {
            ForEach(Array(metadataSegments.enumerated()), id: \.offset) { idx, seg in
                if idx > 0 {
                    Text("·").foregroundStyle(.tertiary)
                }
                Text(seg).foregroundStyle(.secondary)
            }
        }
    }
}
