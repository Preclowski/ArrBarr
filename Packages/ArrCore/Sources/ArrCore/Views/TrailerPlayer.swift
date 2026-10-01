import SwiftUI
import WebKit

// MARK: - Session

/// The one live trailer, owned above the view tree: the popover rebuilds its content on
/// every open, so the key and web view live here to re-present the still-playing clip.
@Observable
public final class TrailerSession {
    public static let shared = TrailerSession()

    /// Nil = no trailer up; set while a clip plays behind a closed popover too.
    public private(set) var key: String?
    public private(set) var reel: TrailerReel?

    /// Kept so a popover reopen re-parents the same web view instead of reloading the clip.
    var webView: WKWebView?
    /// Here, not on a coordinator, because coordinators die with the popover's view tree.
    var loadedKey: String?

    public func present(_ reel: TrailerReel) {
        self.reel = reel
        key = reel.featuredKey
        Self.syncInterfaceOrientations()
    }

    /// Opens the reel on a clip other than the featured one.
    func present(_ reel: TrailerReel, startingAt clip: TrailerClip) {
        present(reel)
        play(clip)
    }

    func play(_ clip: TrailerClip) {
        guard key != nil, reel?.clips.contains(clip) == true else { return }
        key = clip.key
    }

    /// By title, not clip, so picking another tile doesn't read as the trailer closing.
    public func isShowing(_ reel: TrailerReel?) -> Bool {
        reel != nil && self.reel == reel
    }

    /// The iPhone app is portrait-locked except while a trailer plays;
    /// `AppDelegate.supportedInterfaceOrientations` reads this.
    public private(set) static var allowsLandscape = false

    public func toggle(_ reel: TrailerReel?) {
        guard let reel else { return }
        if isShowing(reel) { dismiss() } else { present(reel) }
    }

    /// Releasing the web view is not enough — WebKit keeps playing until the page goes, so blank it.
    public func dismiss() {
        key = nil
        reel = nil
        loadedKey = nil
        webView?.loadHTMLString("<html><body></body></html>", baseURL: nil)
        webView = nil
        Self.syncInterfaceOrientations()
    }

    /// Closing in landscape must also rotate the window back, or the portrait-only app is left
    /// on its side.
    private static func syncInterfaceOrientations() {
        #if os(iOS)
        let playing = shared.key != nil
        guard playing != allowsLandscape else { return }
        allowsLandscape = playing
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if !playing {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
        #endif
    }

    /// The host tree is being dismantled mid-clip (popover closed or rebuilt) but the session keeps it.
    func keepsAlive(_ view: WKWebView) -> Bool {
        key != nil && webView === view
    }
}

// MARK: - Web view
// YouTube's embed is the only legal way to play these clips — feeding the stream to
// AVPlayer breaks YouTube's terms.

/// `allowsFullscreen` is off only in the menu-bar panel: WebKit's fullscreen had to hide and re-show it by
/// hand, which MenuBarExtra then counted as closed (dead content, no outside-click dismissal).
private func trailerWebConfiguration(allowsFullscreen: Bool) -> WKWebViewConfiguration {
    let config = WKWebViewConfiguration()
    config.mediaTypesRequiringUserActionForPlayback = []
    #if os(iOS)
    config.allowsInlineMediaPlayback = true
    #endif
    config.preferences.isElementFullscreenEnabled = allowsFullscreen
    return config
}

/// We embed as the app's own site: claiming YouTube's origin is read as impersonation and
/// fails with `embedder.identity.denied` (error 152).
private let trailerEmbedHost = "https://www.youtube-nocookie.com"
private let trailerEmbedOrigin = "https://arrbarr.app"

/// Wraps the embed in an iframe: loading `…/embed/KEY` directly has no origin (the view starts
/// at `about:blank`) and every clip fails with error 153.
private func trailerEmbedHTML(key: String, autoplay: Bool, allowsFullscreen: Bool) -> String {
    let query = [
        "autoplay=\(autoplay ? 1 : 0)",
        "playsinline=1",
        // `rel=0` keeps end-of-clip suggestions inside the same channel.
        "rel=0",
        // See `trailerWebConfiguration`.
        "fs=\(allowsFullscreen ? 1 : 0)",
        // No annotation / card overlays on the video.
        "iv_load_policy=3",
        "cc_load_policy=0",
        // The one piece of chrome colour the API exposes.
        "color=white",
        // Deprecated by YouTube in 2023 (the logo shows regardless) but still accepted.
        "modestbranding=1",
        "origin=\(trailerEmbedOrigin)",
        // No `enablejsapi=1`: it makes the app a YouTube API Services client, with the privacy
        // policy obligations that carries.
    ].joined(separator: "&")
    return """
    <!doctype html>
    <html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
          html, body { margin: 0; padding: 0; height: 100%; background: #000; overflow: hidden; }
          iframe { border: 0; width: 100%; height: 100%; display: block; }
        </style>
      </head>
      <body>
        <iframe src="\(trailerEmbedHost)/embed/\(key)?\(query)"
                allow="autoplay; encrypted-media; picture-in-picture"
                allowfullscreen></iframe>
      </body>
    </html>
    """
}

#if os(macOS)
private struct TrailerWebView: NSViewRepresentable {
    let key: String
    var allowsFullscreen = true

    /// Returns a host, not the web view: WebKit's fullscreen takes the web view away and puts it back at the
    /// size it had on screen, and SwiftUI never resizes a view it didn't place, so it overflowed the window.
    func makeNSView(context: Context) -> TrailerHostView {
        let host = TrailerHostView()
        host.embed(webView())
        return host
    }

    func updateNSView(_ host: TrailerHostView, context: Context) {
        // updateNSView fires on every parent redraw; reloading would restart playback.
        guard TrailerSession.shared.loadedKey != key, let view = host.webView else { return }
        load(into: view)
    }

    /// Releasing the web view is not enough — WebKit keeps the audio playing until the page goes.
    static func dismantleNSView(_ host: TrailerHostView, coordinator: ()) {
        // The tree died mid-clip while the session owns the player: leave it so the clip survives.
        guard let view = host.webView, !TrailerSession.shared.keepsAlive(view) else { return }
        view.loadHTMLString("<html><body></body></html>", baseURL: nil)
    }

    private func webView() -> WKWebView {
        let session = TrailerSession.shared
        if let existing = session.webView {
            // A still-playing player from a torn-down tree: adopt it without touching the page. Moved from
            // the detached window into the panel, its YouTube button may stay, but it no longer does anything.
            existing.configuration.preferences.isElementFullscreenEnabled = allowsFullscreen
            if session.loadedKey != key { load(into: existing) }
            return existing
        }
        let view = WKWebView(frame: .zero, configuration: trailerWebConfiguration(allowsFullscreen: allowsFullscreen))
        view.setValue(false, forKey: "drawsBackground")
        session.webView = view
        load(into: view)
        return view
    }

    private func load(into view: WKWebView) {
        TrailerSession.shared.loadedKey = key
        view.loadHTMLString(trailerEmbedHTML(key: key, autoplay: true, allowsFullscreen: allowsFullscreen),
                            baseURL: URL(string: trailerEmbedOrigin))
    }
}

/// Keeps the web view at its own bounds, including when WebKit hands it back after fullscreen.
final class TrailerHostView: NSView {
    private(set) weak var webView: WKWebView?

    func embed(_ view: WKWebView) {
        webView = view
        addSubview(view)
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        subview.frame = bounds
    }

    /// `layout()` alone isn't called on a plain resize of a view without constraints.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fit()
    }

    override func layout() {
        super.layout()
        fit()
    }

    /// A newer host may have adopted the web view since.
    private func fit() {
        if let webView, webView.superview === self { webView.frame = bounds }
    }
}

#else
private struct TrailerWebView: UIViewRepresentable {
    let key: String
    var allowsFullscreen = true

    func makeUIView(context: Context) -> WKWebView {
        let session = TrailerSession.shared
        if let existing = session.webView {
            // A surviving player from a torn-down tree keeps its page and position.
            if session.loadedKey != key { load(into: existing) }
            return existing
        }
        let view = WKWebView(frame: .zero, configuration: trailerWebConfiguration(allowsFullscreen: allowsFullscreen))
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        session.webView = view
        load(into: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard TrailerSession.shared.loadedKey != key else { return }
        load(into: view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        // Releasing the view leaves the clip playing — blank it, unless the session still owns it.
        if TrailerSession.shared.keepsAlive(view) { return }
        view.loadHTMLString("<html><body></body></html>", baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {}

    private func load(into view: WKWebView) {
        TrailerSession.shared.loadedKey = key
        view.loadHTMLString(trailerEmbedHTML(key: key, autoplay: true, allowsFullscreen: allowsFullscreen),
                            baseURL: URL(string: trailerEmbedOrigin))
    }
}
#endif

// MARK: - Overlay presentation

/// Portrait keeps a margin; landscape drops the inset and safe area to give the clip the glass.
private struct TrailerStageInsets: ViewModifier {
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    func body(content: Content) -> some View {
        // Branch on values, never `if`/`else`: a structural branch changes identity and rotating
        // rebuilt `TrailerWebView`, blanking the picture mid-clip.
        content
            .padding(.horizontal, isLandscape ? 0 : 12)
            .ignoresSafeArea(edges: isLandscape ? .all : [])
    }

    private var isLandscape: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }
}

extension View {
    /// Over the whole surface, like the poster lightbox — inline, the player pushed everything
    /// else out of the narrow popover. `fillsWindow`: the window has grown to the clip's shape, so the
    /// clip runs edge to edge at the top with the reel under it.
    /// `tileNamespace`: the detail's trailer row hands its tiles to the reel strip, so they travel into place
    /// while the window grows.
    @ViewBuilder
    func trailerOverlay(key: Binding<String?>, fillsWindow: Bool = false, allowsFullscreen: Bool = true,
                        tileNamespace: Namespace.ID? = nil) -> some View {
        overlay {
            ZStack(alignment: .topLeading) {
                if let presented = key.wrappedValue {
                    // Top-leading: the ✕ matches the lightbox's corner and every back chevron.
                    ZStack(alignment: .topLeading) {
                        // One near-black layer, not a material: measured over bright content even a dark ultra-thick
                        // material only reaches 0.37 luminance; video wants ~0.09.
                        Rectangle()
                            .fill(Color.black.opacity(fillsWindow ? 1 : 0.92))
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.smooth(duration: 0.4)) { key.wrappedValue = nil }
                            }
                        if fillsWindow {
                            TrailerWebView(key: presented, allowsFullscreen: allowsFullscreen)
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .background(Color.black)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                .ignoresSafeArea()
                        } else {
                            VStack(spacing: 14) {
                                TrailerPlayerCard(key: presented)
                                    .modifier(TrailerStageInsets())
                                TrailerReelStrip(playing: presented)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        LightboxCloseButton(labelKey: "detail.trailerClose.button") {
                            withAnimation(.smooth(duration: 0.4)) { key.wrappedValue = nil }
                        }
                    }
                    .transition(.opacity)
                }
                // Outside the fading layer, pinned to the bottom of the window grown for it, so its tiles can
                // travel in from the detail's row instead of fading.
                if fillsWindow, let presented = key.wrappedValue, TrailerWindowSize.showsStrip {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        TrailerReelStrip(playing: presented, tileNamespace: tileNamespace)
                            .frame(height: TrailerWindowSize.stripHeight, alignment: .top)
                            .padding(.vertical, TrailerWindowSize.stripPadding)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                }
            }
            // Below the poster lightbox (10) so the two can't fight.
            .zIndex(9)
        }
    }
}

// MARK: - Reel strip

/// Hidden with a single clip, and in landscape, where the clip owns the glass.
private struct TrailerReelStrip: View {
    let playing: String
    var tileNamespace: Namespace.ID? = nil
    private var session: TrailerSession { .shared }
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    var body: some View {
        if let clips = session.reel?.clips, clips.count > 1, !isLandscape {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(clips) { clip in
                            TrailerClipTile(clip: clip, isPlaying: clip.key == playing) {
                                withAnimation(.smooth(duration: 0.2)) { session.play(clip) }
                            }
                            .trailerTileMatch(clip, in: tileNamespace)
                            .id(clip.key)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                // Tiles fly in from the detail's row; clipped, they'd show only once inside the strip.
                .scrollClipDisabled(tileNamespace != nil)
                .onAppear { proxy.scrollTo(playing, anchor: .center) }
                .onChange(of: playing) { _, key in
                    withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(key, anchor: .center) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isLandscape: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }
}

private struct TrailerClipTile: View {
    let clip: TrailerClip
    let isPlaying: Bool
    let action: () -> Void

    private static let thumbnail = TrailerClip.thumbnailSize

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                RemotePoster(url: clip.thumbnailURL, apiKey: nil, tier: .icon,
                             size: Self.thumbnail, cornerRadius: 6,
                             fallbackSymbol: "play.rectangle")
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white, lineWidth: isPlaying ? 2 : 0)
                    }
                Group {
                    if let name = clip.name, !name.isEmpty {
                        Text(verbatim: name)
                    } else {
                        Text("detail.trailer.button", bundle: .module)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.white)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            }
            .frame(width: Self.thumbnail.width)
            .opacity(isPlaying ? 1 : 0.7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isPlaying ? .isSelected : [])
        #if os(macOS)
        .pointerStyle(.link)
        #endif
    }
}


// MARK: - Inline card

/// Sized by aspect ratio so it fills both the narrow panel and the wide detached window.
struct TrailerPlayerCard: View {
    let key: String

    var body: some View {
        TrailerWebView(key: key)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
        // Dismissal is the overlay's job (✕, scrim tap, Esc).
    }
}
