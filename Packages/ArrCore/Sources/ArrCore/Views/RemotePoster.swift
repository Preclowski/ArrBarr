import SwiftUI
import os

/// Wraps a poster (or any view) and blurs it when `blurred` is true. Used to
/// hide NSFW Whisparr posters. There's no tap-to-reveal — toggle is a global
/// preference in Settings, not a per-poster trick.
///
/// SwiftUI's `.blur(radius:)` is a Gaussian convolution that bleeds past the
/// content's frame, producing fuzzy edges past the poster. We `.compositingGroup()`
/// to rasterize the blur, then `.clipShape(RoundedRectangle)` to confine it back
/// to the poster's shape so the bleed disappears.
public struct PosterBlurContainer<Content: View>: View {
    let blurred: Bool
    let cornerRadius: CGFloat
    @ViewBuilder let content: () -> Content

    public init(blurred: Bool, cornerRadius: CGFloat = 4, @ViewBuilder content: @escaping () -> Content) {
        self.blurred = blurred
        self.cornerRadius = cornerRadius
        self.content = content
    }

    public var body: some View {
        content()
            .blur(radius: blurred ? 12 : 0)
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

public struct RemotePoster: View {
    let url: URL?
    let apiKey: String?
    /// How large a copy to fetch and keep. Stated explicitly rather than
    /// inferred from `size`, because `size` cannot see the two things that
    /// decide it: `fill` ignores `size` entirely, and the lightbox scales its
    /// poster up to 5× after layout. Defaults to `.card` — the safe direction,
    /// since a too-small tier shows as a blurry poster while a too-large one
    /// only costs bytes (and DEBUG builds log both, see `load`).
    var tier: PosterTier = .card
    var size: CGSize = CGSize(width: 40, height: 60)
    var cornerRadius: CGFloat = 4
    var fallbackSymbol: String? = "photo"
    /// When true the poster expands to fill its parent's available
    /// rectangle (`maxWidth/Height: .infinity`) instead of clamping to
    /// `size`. Default `false` preserves all existing call-site behaviour.
    var fill: Bool = false
    /// Opt-in: show a spinner while the image is in flight instead of the
    /// fallback symbol. Off by default so existing call sites are unchanged;
    /// used where load latency is visible (e.g. the Quiz card's poster deck).
    var showsLoadingIndicator: Bool = false

    @State private var image: PlatformImage?
    @State private var failed = false
    @State private var isLoading = true

    public var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                ZStack {
                    // A styled "blank poster" instead of a flat grey box: a
                    // soft top-down sheen over the fill plus the arr's own
                    // glyph, so a posterless title still reads as a
                    // poster-shaped placeholder at any size — list thumbnail
                    // through detail hero. Callers pass their source symbol
                    // (`tv`/`film`/`music.note`/`flame`); an empty symbol just
                    // yields the sheen with no glyph.
                    Rectangle().fill(.quaternary)
                    LinearGradient(
                        colors: [Color.primary.opacity(0.06), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    if showsLoadingIndicator && isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else if let fallbackSymbol, !fallbackSymbol.isEmpty {
                        Image(systemName: fallbackSymbol)
                            .font(.system(size: min(size.width, size.height) * 0.38, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .modifier(RemotePosterFrame(fill: fill, size: size))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
        // The tier is part of the request's identity: switching it has to
        // re-load, not keep showing the previously sized copy.
        .task(id: PosterRequest(url: url, tier: tier)) {
            await load()
        }
    }

    private func load() async {
        guard let url else {
            image = nil
            failed = false
            isLoading = false
            return
        }
        isLoading = true
        // Paint the smaller copy we already hold, then sharpen. The icon tier
        // covers the whole library, so a detail view that used to sit on a grey
        // rectangle for the length of a download now opens with its poster.
        // Skipped when this view already shows something (a recycled row would
        // otherwise visibly step *down* in quality first).
        if image == nil, let preview = await PosterStore.shared.cachedPreview(for: url, below: tier) {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                image = preview
                isLoading = false
            }
        }
        let result = await PosterStore.shared.image(for: url, tier: tier, apiKey: apiKey)
        // The view may have been recycled onto a different title while we were
        // downloading; landing this poster there would show the wrong artwork.
        guard !Task.isCancelled else { return }
        await MainActor.run {
            // Never replace a poster with nothing: if the bigger copy failed,
            // the preview on screen is still the best we have.
            if result != nil || image == nil { image = result }
            failed = (result == nil && image == nil)
            isLoading = false
        }
        #if DEBUG
        if let result { warnOnTierMismatch(result) }
        #endif
    }

    #if DEBUG
    /// Tier is a hand-made choice per call site, so make a wrong one visible
    /// instead of silently blurry (too small) or silently expensive (too big).
    private func warnOnTierMismatch(_ image: PlatformImage) {
        guard !fill, size.width > 0, size.height > 0 else { return }
        let scale: CGFloat
        #if os(macOS)
        scale = NSScreen.main?.backingScaleFactor ?? 2
        #else
        scale = UIScreen.main.scale
        #endif
        let needed = max(size.width, size.height) * scale
        let have = max(image.size.width, image.size.height)
        if have < needed / 1.25 {
            Logger(category: "RemotePoster").notice(
                "under-sampled: \(tier.rawValue, privacy: .public) gives \(Int(have), privacy: .public)px for \(Int(needed), privacy: .public)px"
            )
        } else if have > needed * 2.5 {
            Logger(category: "RemotePoster").notice(
                "over-sampled: \(tier.rawValue, privacy: .public) gives \(Int(have), privacy: .public)px for \(Int(needed), privacy: .public)px"
            )
        }
    }
    #endif
}

/// Identity of a poster request — `.task(id:)` must re-run when either half
/// changes.
private struct PosterRequest: Equatable {
    let url: URL?
    let tier: PosterTier
}

private struct RemotePosterFrame: ViewModifier {
    let fill: Bool
    let size: CGSize

    func body(content: Content) -> some View {
        if fill {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            content
                .frame(width: size.width, height: size.height)
        }
    }
}
