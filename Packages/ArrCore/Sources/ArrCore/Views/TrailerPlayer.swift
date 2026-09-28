import SwiftUI
import WebKit

// MARK: - Session

/// The one live trailer, owned above the view tree: the popover rebuilds its content on
/// every open, so the key and web view live here to re-present the still-playing clip.
public final class TrailerSession: ObservableObject {
    public static let shared = TrailerSession()

    /// Nil = no trailer up; set while a clip plays behind a closed popover too.
    @Published public private(set) var key: String?
    @Published public private(set) var reel: TrailerReel?

    /// Kept so a popover reopen re-parents the same web view instead of reloading the clip.
    var webView: WKWebView?
    /// Here, not on a coordinator, because coordinators die with the popover's view tree.
    var loadedKey: String?

    public func present(_ reel: TrailerReel) {
        self.reel = reel
        key = reel.featuredKey
        Self.syncInterfaceOrientations()
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

private let trailerFullscreenMessage = "trailerFullscreen"

private func trailerWebConfiguration() -> WKWebViewConfiguration {
    let config = WKWebViewConfiguration()
    config.mediaTypesRequiringUserActionForPlayback = []
    #if os(iOS)
    config.allowsInlineMediaPlayback = true
    #endif
    // WebKit's element fullscreen works from the non-activating popover
    // (`document.fullscreenEnabled` is true there) and keeps the player's controls.
    config.preferences.isElementFullscreenEnabled = true
    return config
}

/// We embed as the app's own site: claiming YouTube's origin is read as impersonation and
/// fails with `embedder.identity.denied` (error 152).
private let trailerEmbedHost = "https://www.youtube-nocookie.com"
private let trailerEmbedOrigin = "https://arrbarr.app"

/// Wraps the embed in an iframe: loading `…/embed/KEY` directly has no origin (the view starts
/// at `about:blank`) and every clip fails with error 153.
private func trailerEmbedHTML(key: String, autoplay: Bool) -> String {
    let query = [
        "autoplay=\(autoplay ? 1 : 0)",
        "playsinline=1",
        // `rel=0` keeps end-of-clip suggestions inside the same channel.
        "rel=0",
        "fs=1",
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
        <script>
          // The popover floats above WebKit's fullscreen window, so native code has to hide it.
          document.addEventListener("fullscreenchange", function () {
            window.webkit?.messageHandlers?.\(trailerFullscreenMessage)
              ?.postMessage(!!document.fullscreenElement);
          });
        </script>
      </body>
    </html>
    """
}

#if os(macOS)
/// WebKit's element fullscreen moves the web view into its own window; this hook fires even
/// when the cross-origin iframe's `fullscreenchange` never reaches our page.
private final class TrailerBackingWebView: WKWebView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

private struct TrailerWebView: NSViewRepresentable {
    let key: String

    func makeNSView(context: Context) -> WKWebView {
        let session = TrailerSession.shared
        let coordinator = context.coordinator
        if let existing = session.webView as? TrailerBackingWebView {
            // A still-playing player from a torn-down tree: adopt it without touching the page.
            // Remove-then-add because `add` with a duplicate handler name raises.
            existing.configuration.userContentController
                .removeScriptMessageHandler(forName: trailerFullscreenMessage)
            existing.configuration.userContentController
                .add(coordinator, name: trailerFullscreenMessage)
            coordinator.webView = existing
            existing.onWindowChange = { [weak coordinator] window in
                coordinator?.webViewMoved(to: window)
            }
            if session.loadedKey != key { load(into: existing) }
            return existing
        }
        let config = trailerWebConfiguration()
        config.userContentController.add(coordinator, name: trailerFullscreenMessage)
        let view = TrailerBackingWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        coordinator.webView = view
        view.onWindowChange = { [weak coordinator] window in
            coordinator?.webViewMoved(to: window)
        }
        session.webView = view
        load(into: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        // updateNSView fires on every parent redraw; reloading would restart playback.
        guard TrailerSession.shared.loadedKey != key else { return }
        load(into: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        // The tree died mid-clip while the session owns the player: leave the page and its
        // handler alone so the clip survives to be re-presented.
        if TrailerSession.shared.keepsAlive(view) { return }
        view.configuration.userContentController
            .removeScriptMessageHandler(forName: trailerFullscreenMessage)
        coordinator.hostTornDown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Hides the popover while the player is fullscreen. Ordered out, not closed: closing tore
    /// down the tree holding the player and left a dead black overlay on return.
    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        /// The popover or detached window; captured the first time we are placed.
        private weak var hostWindow: NSWindow?
        private var retainedDuringFullscreen: WKWebView?
        /// Restored on return: AppKit otherwise puts the panel back at a frame it computed off-screen
        /// while the fullscreen window owned the display.
        private var hostFrameBeforeFullscreen: NSRect?

        func webViewMoved(to window: NSWindow?) {
            // No window at all is teardown, handled by `hostTornDown()`.
            guard let window else { return }
            guard let hostWindow else {
                hostWindow = window
                return
            }
            if window !== hostWindow {
                beginFullscreen(hostWindow: hostWindow)
            } else {
                endFullscreen(hostWindow: hostWindow)
            }
        }

        private func beginFullscreen(hostWindow: NSWindow) {
            // The tree stays alive behind the hidden window, but a strong reference guarantees nothing
            // pulls the player out from under WebKit mid-clip.
            retainedDuringFullscreen = webView
            hostFrameBeforeFullscreen = hostWindow.frame
            hostWindow.orderOut(nil)
        }

        /// Releasing the web view is not enough — WebKit keeps the audio playing until the page goes.
        func hostTornDown() {
            guard retainedDuringFullscreen == nil else { return }   // fullscreen owns it
            webView?.loadHTMLString("<html><body></body></html>", baseURL: nil)
        }

        /// Leaves the clip alone — it is still playing, and the small player is where the user expects to land.
        private func endFullscreen(hostWindow: NSWindow) {
            retainedDuringFullscreen = nil
            guard hostFrameBeforeFullscreen != nil else { return }
            hostWindow.orderFrontRegardless()
            restoreHostFrame()
        }

        /// Re-applied over a few runloop turns: AppKit re-places the panel itself as it returns, and
        /// a single restore races it.
        private func restoreHostFrame() {
            guard hostFrameBeforeFullscreen != nil else { return }
            for delay in [0, 0.05, 0.2, 0.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.applySavedFrame(clearing: delay == 0.5)
                }
            }
        }

        private func applySavedFrame(clearing: Bool) {
            defer { if clearing { hostFrameBeforeFullscreen = nil } }
            guard let hostWindow, let saved = hostFrameBeforeFullscreen,
                  hostWindow.frame != saved else { return }
            let visible = (hostWindow.screen ?? NSScreen.main)?.visibleFrame
            var frame = saved
            if let visible {
                frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            }
            hostWindow.setFrame(frame, display: true)
        }

        /// Second signal, for when the page does see the change; harmless after `webViewMoved(to:)`.
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            // JS booleans arrive as NSNumber; `as? Bool` alone relies on a bridging detail.
            guard message.name == trailerFullscreenMessage,
                  let entered = (message.body as? NSNumber)?.boolValue
                      ?? (message.body as? Bool),
                  entered, let hostWindow, hostWindow.isVisible else { return }
            beginFullscreen(hostWindow: hostWindow)
        }
    }

    private func load(into view: WKWebView) {
        TrailerSession.shared.loadedKey = key
        view.loadHTMLString(trailerEmbedHTML(key: key, autoplay: true),
                            baseURL: URL(string: trailerEmbedOrigin))
    }
}

#else
private struct TrailerWebView: UIViewRepresentable {
    let key: String

    func makeUIView(context: Context) -> WKWebView {
        let session = TrailerSession.shared
        if let existing = session.webView {
            // A surviving player from a torn-down tree keeps its page and position.
            if session.loadedKey != key { load(into: existing) }
            return existing
        }
        let view = WKWebView(frame: .zero, configuration: trailerWebConfiguration())
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
        view.loadHTMLString(trailerEmbedHTML(key: key, autoplay: true),
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
    /// else out of the narrow popover.
    @ViewBuilder
    func trailerOverlay(key: Binding<String?>) -> some View {
        overlay {
            if let presented = key.wrappedValue {
                // Top-leading: the ✕ matches the lightbox's corner and every back chevron.
                ZStack(alignment: .topLeading) {
                    // One near-black layer, not a material: measured over bright content even a dark ultra-thick
                    // material only reaches 0.37 luminance; video wants ~0.09.
                    Rectangle()
                        .fill(Color.black.opacity(0.92))
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.smooth(duration: 0.2)) { key.wrappedValue = nil }
                        }
                    VStack(spacing: 14) {
                        TrailerPlayerCard(key: presented)
                            .modifier(TrailerStageInsets())
                        TrailerReelStrip(playing: presented)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    LightboxCloseButton(labelKey: "detail.trailerClose.button") {
                        withAnimation(.smooth(duration: 0.2)) { key.wrappedValue = nil }
                    }
                }
                .transition(.opacity)
                // Below the poster lightbox (10) so the two can't fight.
                .zIndex(9)
            }
        }
    }
}

// MARK: - Reel strip

/// Hidden with a single clip, and in landscape, where the clip owns the glass.
private struct TrailerReelStrip: View {
    let playing: String
    @ObservedObject private var session = TrailerSession.shared
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
                            .id(clip.key)
                        }
                    }
                    .padding(.horizontal, 12)
                }
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

    private static let thumbnail = CGSize(width: 128, height: 72)

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
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #endif
    }
}

// MARK: - Poster badge

/// Only this corner opens the trailer; the rest of the poster keeps its lightbox tap.
struct TrailerPosterBadge: View {
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // The mark carries its own contrast; the shadow keeps its edge on a light or busy poster.
            Image("brand-youtube", bundle: .module)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 21)
                .shadow(color: .black.opacity(0.55), radius: 2, y: 0.5)
                .opacity(isPlaying ? 1 : 0.88)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .help(Text("detail.trailer.button", bundle: .module))
        .accessibilityLabel(Text("detail.trailer.button", bundle: .module))
        #if os(macOS)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
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
