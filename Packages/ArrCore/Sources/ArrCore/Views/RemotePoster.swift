import SwiftUI
import os

/// Blurs NSFW Whisparr posters. `.blur` bleeds past the frame, so `.compositingGroup()` plus
/// `.clipShape` confine it to the poster.
struct PosterBlurContainer<Content: View>: View {
    let blurred: Bool
    let cornerRadius: CGFloat
    @ViewBuilder let content: () -> Content

    init(blurred: Bool, cornerRadius: CGFloat = 4, @ViewBuilder content: @escaping () -> Content) {
        self.blurred = blurred
        self.cornerRadius = cornerRadius
        self.content = content
    }

    var body: some View {
        content()
            .blur(radius: blurred ? 12 : 0)
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// The hero artwork every detail surface draws, with the corner slots that live on the poster.
struct DetailHeroPoster: View {
    let url: URL?
    var apiKey: String?
    var size: CGSize
    var fallbackSymbol: String
    var blurred: Bool
    /// Top-left, tucked into the same corner as the watched wedge.
    var cornerAction: AnyView?
    var watched: Bool = false
    /// `nil` renders the poster inert; a nil `url` disables the button.
    var onTap: ((URL?) -> Void)?

    @State private var hovering = false

    init(
        url: URL?,
        apiKey: String? = nil,
        size: CGSize,
        fallbackSymbol: String = "film",
        blurred: Bool = false,
        cornerAction: AnyView? = nil,
        watched: Bool = false,
        onTap: ((URL?) -> Void)? = nil
    ) {
        self.url = url
        self.apiKey = apiKey
        self.size = size
        self.fallbackSymbol = fallbackSymbol
        self.blurred = blurred
        self.cornerAction = cornerAction
        self.watched = watched
        self.onTap = onTap
    }

    var body: some View {
        artwork
            // `monitored: nil` — the ribbon here is the interactive toggle the
            // host hands down as `cornerAction`, not a drawn-on marker.
            .posterMarks(watched: watched, monitored: nil,
                         cornerRadius: Tokens.Radius.card, ribbonWidth: 12)
            .overlay(alignment: .topLeading) { cornerAction }
    }

    @ViewBuilder
    private var artwork: some View {
        let poster = PosterBlurContainer(blurred: blurred, cornerRadius: Tokens.Radius.card) {
            RemotePoster(
                url: url,
                apiKey: apiKey,
                size: size,
                cornerRadius: Tokens.Radius.card,
                fallbackSymbol: fallbackSymbol,
                fitsContent: true
            )
        }
        if let onTap {
            Button { onTap(url) } label: {
                poster.overlay { enlargeHint }
            }
                .buttonStyle(.plain)
                .disabled(url == nil)
                .help(Text("detail.showPoster.button", bundle: .module))
                // RemotePoster hides itself from VoiceOver, so the button
                // wrapping it has no label at all without this.
                .accessibilityLabel(Text("detail.showPoster.button", bundle: .module))
                #if os(macOS)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                #endif
        } else {
            poster
        }
    }

    /// Hover-only enlarge hint; hidden from VoiceOver (the button has a label) and absent on touch.
    @ViewBuilder
    private var enlargeHint: some View {
        if hovering, url != nil {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(Color.black.opacity(0.28))
                Image(systemName: "magnifyingglass")
                    .font(.system(size: min(size.width, size.height) * 0.22, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }
}

private struct PosterContentMode: ViewModifier {
    let fits: Bool
    func body(content: Content) -> some View {
        if fits { content.scaledToFit() } else { content.scaledToFill() }
    }
}

struct RemotePoster: View {
    let url: URL?
    let apiKey: String?
    /// Explicit because `size` can't decide it: `fill` ignores `size` and the lightbox scales up to 5×.
    /// Too small shows blurry, too large only costs bytes.
    var tier: PosterTier = .card
    var size: CGSize = CGSize(width: 40, height: 60)
    var cornerRadius: CGFloat = 4
    var fallbackSymbol: String? = "photo"
    var fill: Bool = false
    /// Detail heroes fit: an episode still or square cover is not 2:3, and a cropped hero reads as a bug.
    var fitsContent: Bool = false
    var showsLoadingIndicator: Bool = false

    @State private var image: PlatformImage?
    @State private var failed = false
    @State private var isLoading = true

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .modifier(PosterContentMode(fits: fitsContent && !nearlyFillsFrame(image)))
            } else {
                ZStack {
                    // A styled blank poster (sheen plus the arr's glyph) so a posterless title still reads as one.
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

    /// A TVDB poster is 680×1000, not 2:3; within this tolerance the crop is invisible and beats hairline bars.
    private func nearlyFillsFrame(_ image: PlatformImage) -> Bool {
        guard image.size.height > 0, size.height > 0 else { return false }
        let ratio = (image.size.width / image.size.height) / (size.width / size.height)
        return abs(ratio - 1) < 0.08
    }

    private func load() async {
        guard let url else {
            image = nil
            failed = false
            isLoading = false
            return
        }
        isLoading = true
        // Paint the smaller cached copy first, then sharpen. Skipped when something is already shown,
        // or a recycled row would step down in quality.
        if image == nil, let preview = await PosterStore.shared.cachedPreview(for: url, below: tier) {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                image = preview
                isLoading = false
            }
        }
        let result = await PosterStore.shared.image(for: url, tier: tier, apiKey: apiKey)
        // The view may have been recycled onto a different title while downloading.
        guard !Task.isCancelled else { return }
        await MainActor.run {
            // Never replace a poster with nothing: the preview is still the best we have.
            if result != nil || image == nil { image = result }
            failed = (result == nil && image == nil)
            isLoading = false
        }
        #if DEBUG
        if let result { warnOnTierMismatch(result) }
        #endif
    }

    #if DEBUG
    private static let log = Logger(category: "RemotePoster")

    /// Tier is a hand-made choice per call site, so make a wrong one visible.
    private func warnOnTierMismatch(_ image: PlatformImage) {
        guard !fill, size.width > 0, size.height > 0 else { return }
        let scale: CGFloat
        #if os(macOS)
        scale = NSScreen.main?.backingScaleFactor ?? 2
        #else
        scale = UITraitCollection.current.displayScale
        #endif
        let needed = max(size.width, size.height) * scale
        let have = max(image.size.width, image.size.height)
        if have < needed / 1.25 {
            Self.log.notice(
                "under-sampled: \(tier.rawValue, privacy: .public) gives \(Int(have), privacy: .public)px for \(Int(needed), privacy: .public)px"
            )
        } else if have > needed * 2.5 {
            Self.log.notice(
                "over-sampled: \(tier.rawValue, privacy: .public) gives \(Int(have), privacy: .public)px for \(Int(needed), privacy: .public)px"
            )
        }
    }
    #endif
}

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
