import SwiftUI
#if os(macOS)
import AppKit
import QuartzCore
#else
import UIKit
#endif

/// The menu-bar panel's size while a trailer plays: the clip's 16:9 at full width, plus the reel strip.
enum TrailerWindowSize {
    static let standard = CGSize(width: 400, height: 600)
    static let width: CGFloat = 720
    /// `TrailerClipTile`: a 72 pt thumbnail, a 5 pt gap and the two caption lines it always reserves.
    static let stripHeight: CGFloat = 72 + 5 + 2 * captionLineHeight
    static let stripPadding: CGFloat = 12

    /// The reel only shows with more than one clip.
    static var showsStrip: Bool { (TrailerSession.shared.reel?.clips.count ?? 0) > 1 }

    private static var captionLineHeight: CGFloat {
        #if os(macOS)
        NSLayoutManager().defaultLineHeight(for: .preferredFont(forTextStyle: .caption2)).rounded(.up)
        #else
        UIFont.preferredFont(forTextStyle: .caption2).lineHeight.rounded(.up)
        #endif
    }

    static func trailer(showsStrip: Bool, screenWidth: CGFloat?) -> CGSize {
        let width = min(Self.width, (screenWidth ?? Self.width + 40) - 40).rounded()
        let strip = showsStrip ? stripHeight + 2 * stripPadding : 0
        return CGSize(width: width, height: (width * 9 / 16 + strip).rounded())
    }
}

#if os(macOS)
/// Grows the window to the trailer's shape and back. Stepped frame by frame: SwiftUI hands AppKit only the
/// end size of an animated frame, so the window would jump; each step here is a real size.
struct TrailerWindowSizing: ViewModifier {
    let sizer: TrailerWindowSizer

    func body(content: Content) -> some View {
        // The clip's overlay leaves at once while the window still has 0.4 s to shrink: black until then,
        // not the 400 pt content adrift in a wide window.
        let shrinking = sizer.size != TrailerWindowSize.standard && TrailerSession.shared.key == nil
        content
            .opacity(shrinking ? 0 : 1)
            .frame(width: sizer.size.width, height: sizer.size.height)
            .background(Color.black.opacity(shrinking ? 1 : 0))
            .animation(.easeOut(duration: 0.15), value: shrinking)
            .background(WindowReader { sizer.attach($0) })
    }
}

/// One per window, not view state: the panel's content is rebuilt on every open, and a fresh view would
/// restart from 400×600 under a clip that is still playing.
@MainActor @Observable
final class TrailerWindowSizer {
    /// Hangs from its menu-bar icon, so it grows left.
    static let panel = TrailerWindowSizer(growsLeft: true)
    static let detached = TrailerWindowSizer(growsLeft: false)

    private(set) var size = TrailerWindowSize.standard

    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private let growsLeft: Bool
    /// Where the window hangs from while it isn't standard size: its top edge, and the side edge that stays.
    @ObservationIgnored private var anchor: (top: CGFloat, x: CGFloat)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    var screenWidth: CGFloat? { (window?.screen ?? NSScreen.main)?.visibleFrame.width }

    /// Follows the session, which the other window's clip changes too while this one is shut.
    private init(growsLeft: Bool) {
        self.growsLeft = growsLeft
        follow()
    }

    private func follow() {
        withObservationTracking {
            _ = TrailerSession.shared.key
            _ = TrailerSession.shared.reel
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.animate(to: self.target)
                self.follow()
            }
        }
    }

    private var target: CGSize {
        let session = TrailerSession.shared
        guard session.key != nil else { return TrailerWindowSize.standard }
        return TrailerWindowSize.trailer(showsStrip: TrailerWindowSize.showsStrip, screenWidth: screenWidth)
    }

    /// Called on every open, since the content is rebuilt: a clip may have started while the window was shut.
    func attach(_ window: NSWindow?) {
        guard let window else { return }
        if window !== self.window {
            observers.forEach(NotificationCenter.default.removeObserver)
            self.window = window
            observers = [NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            }]
        }
        animate(to: target)
    }

    @ObservationIgnored private var easing: Task<Void, Never>?

    private func animate(to end: CGSize) {
        easing?.cancel()
        easing = Task { await ease(to: end) }
    }

    private func ease(to end: CGSize) async {
        let start = size
        guard start != end else { return }
        // A shut window takes the size at once and opens at it (the panel placed by MenuBarExtra under its
        // icon); an anchor taken from its hidden frame would pull it somewhere stale.
        guard let window, window.isVisible else {
            size = end
            anchor = nil
            return
        }
        if anchor == nil { anchor = (window.frame.maxY, growsLeft ? window.frame.maxX : window.frame.minX) }
        let began = CACurrentMediaTime()
        let duration = 0.4
        while !Task.isCancelled {
            let t = min((CACurrentMediaTime() - began) / duration, 1)
            let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            size = CGSize(width: (start.width + (end.width - start.width) * e).rounded(),
                          height: (start.height + (end.height - start.height) * e).rounded())
            resizeWindow(window)
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(8))
        }
        if size == TrailerWindowSize.standard { anchor = nil }
    }

    /// Also set directly: the detached window's hosting controller doesn't follow its content's size.
    private func resizeWindow(_ window: NSWindow) {
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        guard frame.size != window.frame.size else { return }
        window.setFrame(NSRect(origin: anchoredOrigin(for: frame.size, in: window) ?? window.frame.origin,
                               size: frame.size), display: true)
    }

    private func anchoredOrigin(for size: CGSize, in window: NSWindow) -> CGPoint? {
        guard let anchor else { return nil }
        var origin = CGPoint(x: growsLeft ? anchor.x - size.width : anchor.x, y: anchor.top - size.height)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        return origin
    }

    private func place() {
        guard let window, let origin = anchoredOrigin(for: window.frame.size, in: window) else { return }
        if origin != window.frame.origin { window.setFrameOrigin(origin) }
    }
}

private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
#endif
