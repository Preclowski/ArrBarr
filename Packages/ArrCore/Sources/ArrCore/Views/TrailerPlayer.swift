import SwiftUI
import WebKit

// MARK: - Session

/// The one live trailer, owned ABOVE the view tree.
///
/// The menu-bar popover rebuilds its entire content view on every open, so any
/// trailer state kept in a surface's `@State` dies with the popover — the clip
/// kept playing (WebKit holds the page until it is blanked) while the UI that
/// could show or stop it was gone. Holding the key AND the web view here lets
/// the root overlay re-present the same, still-playing player when the popover
/// comes back, and gives closing it a single owner.
///
/// One session, not one per surface: the overlay is full-surface, so two
/// concurrent clips can't exist anyway.
@MainActor
public final class TrailerSession: ObservableObject {
    public static let shared = TrailerSession()

    /// YouTube id of the clip on screen (or playing behind a closed popover).
    /// Nil = no trailer up.
    @Published public private(set) var key: String?

    /// The live player, kept so a popover close/reopen re-parents the SAME
    /// web view instead of reloading the clip from zero.
    var webView: WKWebView?
    /// Which clip `webView` has loaded — lives here (not on a coordinator)
    /// because coordinators die with the popover's view tree.
    var loadedKey: String?

    public func present(_ key: String) { self.key = key }

    /// The badge's toggle: play, or stop if this clip is already up.
    public func toggle(_ key: String?) {
        guard let key else { return }
        if self.key == key { dismiss() } else { present(key) }
    }

    /// Stops playback for real: releasing the web view is NOT enough — WebKit
    /// keeps the media playing until the page goes, so blank it.
    public func dismiss() {
        key = nil
        loadedKey = nil
        webView?.loadHTMLString("<html><body></body></html>", baseURL: nil)
        webView = nil
    }

    /// True while `view` must be kept alive and audible even though its host
    /// tree is being dismantled (popover closed or rebuilt mid-clip).
    func keepsAlive(_ view: WKWebView) -> Bool {
        key != nil && webView === view
    }
}

// MARK: - Web view
//
// YouTube's embed is the only legal way to play these clips — pulling the
// media stream out to feed AVPlayer breaks YouTube's terms — so the player is
// a WKWebView pointed at the `nocookie` embed host. Everything the app draws
// around it (fullscreen, close) is native chrome; the rectangle itself is the
// iframe.

/// Shared configuration: inline playback (so the clip stays inside our card
/// rather than being taken over by the system player) and no tap-to-start gate,
/// since the user already pressed a play button to get here.
/// Name of the JS → native channel carrying fullscreen enter/exit.
private let trailerFullscreenMessage = "trailerFullscreen"

private func trailerWebConfiguration() -> WKWebViewConfiguration {
    let config = WKWebViewConfiguration()
    config.mediaTypesRequiringUserActionForPlayback = []
    #if os(iOS)
    config.allowsInlineMediaPlayback = true
    #endif
    // Element fullscreen ON: this is what makes the player's OWN fullscreen
    // button work, and WebKit's fullscreen window is a far better one than a
    // hand-rolled screen-sized panel — it works from the menu-bar popover
    // (verified: `document.fullscreenEnabled` is true in a non-activating
    // panel) and brings the player's native controls with it.
    config.preferences.isElementFullscreenEnabled = true
    return config
}

/// The embed host the iframe points at, and the origin we embed AS.
///
/// The origin is the app's own site on purpose. Claiming YouTube's own origin
/// (the obvious way to make a local page look "allowed") is read as an
/// embedder pretending to be YouTube and the player answers
/// `embedder.identity.denied` — error 152. An honest third-party origin plays.
private let trailerEmbedHost = "https://www.youtube-nocookie.com"
private let trailerEmbedOrigin = "https://arrbarr.app"

/// A page wrapping the embed in an iframe — NOT the embed URL loaded directly.
///
/// Loading `…/embed/KEY` straight into a WKWebView gives every clip "Error 153
/// — player configuration error": the navigation carries no origin or referrer
/// (the web view starts from `about:blank`), and the player refuses to run for
/// an embedder it can't identify. Serving our own HTML with a real `baseURL`
/// gives the iframe an origin, which is what the player checks.
private func trailerEmbedHTML(key: String, autoplay: Bool) -> String {
    let query = [
        "autoplay=\(autoplay ? 1 : 0)",
        "playsinline=1",
        // No "more videos from around YouTube" grid when the clip ends —
        // `rel=0` keeps suggestions inside the same channel.
        "rel=0",
        // The player's own fullscreen button, which is now the ONLY one —
        // ours sat next to it doing the same job worse.
        "fs=1",
        // Everything the embed API lets us switch off, off. What's left is
        // play/pause, the scrubber, volume and fullscreen — the controls a
        // trailer actually needs.
        //
        // No annotation / card overlays on the video.
        "iv_load_policy=3",
        // Captions stay off unless the viewer turns them on.
        "cc_load_policy=0",
        // Grey progress bar instead of YouTube red — the one piece of chrome
        // colour the API does expose.
        "color=white",
        // Deprecated by YouTube in 2023 (the logo shows regardless now) but
        // still accepted and free to send.
        "modestbranding=1",
        "origin=\(trailerEmbedOrigin)",
        // Makes the player post its state (including error codes) to the
        // parent frame — the only way to see WHY a clip refuses to play.
        "enablejsapi=1",
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
          // The popover floats above WebKit's fullscreen window, so native
          // code has to hide it — and only this event knows when the player's
          // own fullscreen button was pressed.
          document.addEventListener("fullscreenchange", function () {
            window.webkit?.messageHandlers?.\(trailerFullscreenMessage)
              ?.postMessage(!!document.fullscreenElement);
          });
        </script>
      </body>
    </html>
    """
}

/// One web view per host, owned by SwiftUI.
///
/// There is no cross-surface handoff any more: fullscreen is WebKit's own,
/// driven by the player's button, so the clip never has to move between two
/// windows we manage. That also means teardown needs no bookkeeping — when the
/// host disappears the web view is released and the audio stops with it.
#if os(macOS)
/// Reports every re-parenting. WebKit's element fullscreen moves the web view
/// into its OWN window, so this hook — not a JS event — is the signal that
/// cannot be missed: it fires whoever asked for fullscreen, including a
/// cross-origin iframe like YouTube's player, whose `fullscreenchange` does not
/// reliably reach our page.
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
            // The still-playing player from a torn-down popover tree — hand it
            // to this tree's coordinator without touching the page, so the
            // clip carries on exactly where it was. Remove-then-add because
            // the dead tree's handler may still be registered, and `add` with
            // a duplicate name raises.
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
        // Reload only when the clip changes: updateNSView fires on every parent
        // redraw, and reloading would restart playback each time.
        guard TrailerSession.shared.loadedKey != key else { return }
        load(into: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        // The popover (or its content tree) died mid-clip while the session
        // still owns the player: leave the page — and its message handler,
        // which the next tree's coordinator takes over — alone, so the clip
        // survives to be re-presented on reopen.
        if TrailerSession.shared.keepsAlive(view) { return }
        view.configuration.userContentController
            .removeScriptMessageHandler(forName: trailerFullscreenMessage)
        coordinator.hostTornDown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Hides the popover while the player is fullscreen, and brings it back
    /// after.
    ///
    /// Hiding, not closing: the panel outranks WebKit's fullscreen window, so
    /// it has to go — but CLOSING it tore down the view tree holding the
    /// player, which is why leaving fullscreen dumped the user on a dead black
    /// overlay (and took the popover with it). Ordered out, the tree stays
    /// alive, the clip keeps its page, and coming back is just ordering the
    /// same window front again.
    ///
    /// (An earlier attempt at ordering out "did nothing" — that was the JS
    /// `fullscreenchange` never arriving from YouTube's cross-origin iframe,
    /// not the hiding. `viewDidMoveToWindow` is the signal that actually
    /// fires.)
    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        /// The window the player lives in normally — the popover, or the
        /// detached window. Captured the first time we are placed.
        private weak var hostWindow: NSWindow?
        /// Keeps the player alive while its host window is gone.
        private var retainedDuringFullscreen: WKWebView?
        /// Where the popover sat before we closed it. Coming back from
        /// fullscreen, AppKit restores the panel at whatever frame it last
        /// computed — which is off-screen, since the panel was closed while a
        /// screen-filling window owned the display.
        private var hostFrameBeforeFullscreen: NSRect?

        func webViewMoved(to window: NSWindow?) {
            // No window at all is teardown, not fullscreen — `hostTornDown()`
            // handles stopping the clip there.
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
            // Belt and braces: the tree stays alive behind a hidden window, but
            // a strong reference means nothing can pull the player out from
            // under WebKit mid-clip.
            retainedDuringFullscreen = webView
            hostFrameBeforeFullscreen = hostWindow.frame
            hostWindow.orderOut(nil)
        }

        /// The view that hosted the player went away — the user closed the
        /// overlay or left the surface. Releasing the web view is NOT enough:
        /// WebKit keeps the media playing until the page goes, so the audio
        /// carried on with nothing on screen. Blanking the page is what stops
        /// it.
        func hostTornDown() {
            guard retainedDuringFullscreen == nil else { return }   // fullscreen owns it
            webView?.loadHTMLString("<html><body></body></html>", baseURL: nil)
        }

        /// Back from fullscreen into the popover: show it again, put it back
        /// where it was, and leave the clip alone — it is still playing, and
        /// the small player is what the user expects to land in.
        private func endFullscreen(hostWindow: NSWindow) {
            retainedDuringFullscreen = nil
            guard hostFrameBeforeFullscreen != nil else { return }
            hostWindow.orderFrontRegardless()
            restoreHostFrame()
        }

        /// Puts the popover back where it was, clamped to the screen it is on.
        ///
        /// Repeated over the next few runloop turns, not done once: AppKit
        /// re-places the panel itself as it comes back, and whether that lands
        /// before or after a single restore is a coin flip — which is exactly
        /// why the popover came back correctly on one trailer and off-screen on
        /// the next. Re-applying until the frame sticks removes the race
        /// instead of betting on it.
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

        /// Second signal, for the case where the page DOES see the change (a
        /// same-origin request, or a future WebKit that forwards the iframe's).
        /// Harmless when `webViewMoved(to:)` already handled it.
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            // JS booleans arrive as NSNumber, so read it as one — `as? Bool`
            // alone is a bridging detail to depend on.
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
            // Same as macOS: a surviving player from a torn-down tree keeps
            // its page (and playback position) across the re-parent.
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
        // See the macOS note: releasing the view leaves the clip playing —
        // blank it, unless the session still owns it (tree rebuilt mid-clip).
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

extension View {
    /// Present the trailer over the WHOLE surface — dimmed backdrop, player
    /// centred — the way tapping the poster raises the lightbox. Under the
    /// synopsis the player was a block the page had to make room for, and on a
    /// narrow popover that pushed everything else out of view.
    @ViewBuilder
    func trailerOverlay(key: Binding<String?>) -> some View {
        overlay {
            if let presented = key.wrappedValue {
                ZStack(alignment: .topTrailing) {
                    // ONE near-black layer, not a material with a black plate on
                    // top. Tinting the glass was the tidier idea but it can't
                    // get there: measured over bright content, `.regularMaterial`
                    // lands at 0.51 luminance and even an ultra-thick material
                    // forced to its dark variant only reaches 0.37 — a mid-grey
                    // blur is what a material IS. Video wants ~0.09, and at that
                    // point the blur underneath contributes nothing visible, so
                    // the material is dropped rather than paid for.
                    Rectangle()
                        .fill(Color.black.opacity(0.92))
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.smooth(duration: 0.2)) { key.wrappedValue = nil }
                        }
                    TrailerPlayerCard(key: presented)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    LightboxCloseButton(labelKey: "detail.trailerClose.button") {
                        withAnimation(.smooth(duration: 0.2)) { key.wrappedValue = nil }
                    }
                }
                .transition(.opacity)
                // Below the poster lightbox (10) so the two can't fight, above
                // everything else on the surface.
                .zIndex(9)
            }
        }
    }
}

// MARK: - Poster badge

/// YouTube mark tucked into the poster's bottom-right corner — the trailer
/// affordance lives ON the artwork it belongs to, instead of taking a row of
/// its own under it. The poster's own tap (the lightbox) keeps the rest of the
/// artwork; only this corner opens the trailer.
struct TrailerPosterBadge: View {
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // The full-colour mark, bare on the artwork. It carries its own
            // contrast (red body, white glyph) which is why the plate could go;
            // the shadow keeps its edge on a light or busy poster.
            Image("brand-youtube", bundle: .module)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 21)
                .shadow(color: .black.opacity(0.55), radius: 2, y: 0.5)
                // Playing is a full-strength mark; idle sits back a little.
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

/// The 16:9 clip itself, sized by aspect ratio rather than a fixed height so it
/// fills the narrow menu-bar panel and the wide detached window equally.
/// Fullscreen comes from the player's own control bar; dismissal from the
/// overlay around it.
struct TrailerPlayerCard: View {
    let key: String

    var body: some View {
        TrailerWebView(key: key)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
        // Dismissal is the overlay's job (round ✕ in the corner, scrim tap,
        // Esc) — exactly as it is for the poster. The card is only the clip.
    }
}
