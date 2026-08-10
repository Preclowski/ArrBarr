import AppKit
import ArrCore
import ObjectiveC
import os

/// Makes the menu-bar icon accept dropped torrents, nzbs and magnet links.
///
/// Two approaches were tried and rejected before this one, both worth naming so
/// they don't get re-attempted:
///
/// 1. `.dropDestination` on the `MenuBarExtra` label. SwiftUI accepts the
///    modifier and registers *nothing* — the status item's views come back with
///    no dragged types at all, so the drop is never offered.
/// 2. A transparent catcher view over the status item. A view must own
///    hit-testing to receive drags, so it also swallows the click that opens
///    the panel and has to forward it by hand — and the thing it must forward
///    to is an `NSStatusBarButton` buried two levels down, not the view next to
///    it. Get that wrong and the icon goes completely dead.
///
/// So instead of adding a view, the four `NSDraggingDestination` methods are
/// installed on the classes of the status item's *existing* views — the whole
/// chain, see `dropTargets()` for why the button alone isn't enough, and
/// `StatusItemDropBridge` for why a runtime subclass crashes. Nothing about
/// hit-testing, event routing or the view tree changes, so clicking the icon
/// keeps working exactly as before; those views simply also answer drags now.
@MainActor
final class StatusItemDropTarget {
    private let log = Logger(subsystem: "pl.incred.ArrBarr", category: "DownloadDrop")
    /// The outermost view we last attached to. Weak *and* re-checked, because
    /// SwiftUI rebuilds the status item's view tree — the label re-renders
    /// whenever the active-download count changes — and rebuilt views carry no
    /// registered drag types. Attaching once meant drops worked only until the
    /// first badge change.
    private weak var attachedButton: NSView?
    private var watchdog: Timer?

    /// Install once the status item exists. SwiftUI creates it during the first
    /// scene update — after `applicationDidFinishLaunching` — so this retries
    /// briefly rather than assuming it's there, and gives up quietly in
    /// Dock-window mode where there is no status item at all.
    func install() {
        attachIfNeeded(log: true)
        // Cheap: a walk over ~5 views plus a pointer compare. It only re-attaches
        // when the button has actually been replaced, so the steady state costs
        // nothing and the badge-change rebuild can't silently kill drops.
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachIfNeeded(log: false) }
        }
    }

    private func attachIfNeeded(log logFailure: Bool) {
        guard let targets = Self.dropTargets() else {
            if logFailure { log.notice("status item views not found — menu-bar drops unavailable") }
            return
        }
        // Same views, still carrying our types → nothing to do.
        if targets.first === attachedButton, targets.allSatisfy({ !$0.registeredDraggedTypes.isEmpty }) { return }
        for target in targets { StatusItemDropBridge.attach(to: target) }
        if let root = targets.first, let window = root.window {
            let centre = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
            let hit = root.hitTest(centre)
            log.notice(
                "hit-test at icon centre: \(hit.map { String(describing: type(of: $0)) } ?? "nil", privacy: .public) types=\(hit?.registeredDraggedTypes.map(\.rawValue).joined(separator: ",") ?? "-", privacy: .public)"
            )
        }
        attachedButton = targets.first
        log.notice("menu-bar drop target attached to \(targets.count, privacy: .public) view(s)")
    }

    /// Every view a drag over the icon could land on, outermost first.
    ///
    /// Registering only on `NSStatusBarButton` isn't enough: it sits at
    /// `NSStatusBarContentView` → `NSView` → `NSStatusBarButton`, but the
    /// content view also holds two `NSStatusBarShadowView` siblings ordered
    /// *after* it. A drag hit-tests into a shadow view, and AppKit then looks
    /// for a registered destination up the ancestor chain — which never passes
    /// through the button, so the drag was refused with no badge at all.
    /// Registering the whole chain means whichever view the pointer lands on
    /// answers. Matching on class names is unavoidable (none of it is public
    /// API); every failure degrades to "no menu-bar drops", never a crash.
    private static func dropTargets() -> [NSView]? {
        guard let window = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("StatusBar") }),
              let root = window.contentView else { return nil }
        var targets: [NSView] = [root]
        targets.append(contentsOf: descendants(of: root))
        return targets.isEmpty ? nil : targets
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

/// Adds `NSDraggingDestination` behaviour to a status item view by installing
/// the four methods **on its existing class**.
///
/// The obvious alternative — building a runtime subclass and `object_setClass`
/// -ing the button into it — crashes: a class made with
/// `objc_allocateClassPair` carries no Swift metadata, so the first time Swift
/// touches the instance generically (reading `subviews`, which is an
/// `[NSView]`) `swift_dynamicCast` dereferences null and the app segfaults a
/// couple of seconds later. Adding methods leaves the class identity — and the
/// metadata — exactly as AppKit made it.
///
/// `class_addMethod` never replaces an existing implementation, so this can't
/// clobber AppKit behaviour: none of these views implement any of them.
@MainActor
private enum StatusItemDropBridge {
    private static let bridgeLog = Logger(subsystem: "pl.incred.ArrBarr", category: "DownloadDrop")
    /// Which classes already carry our methods. Main-actor isolated — every
    /// caller is the install path, which is main-actor by construction.
    private static var patchedClasses = Set<ObjectIdentifier>()

    @discardableResult
    static func attach(to view: NSView) -> Bool {
        guard let cls: AnyClass = object_getClass(view) else { return false }

        // KVO re-isa's observed objects into `NSKVONotifying_*`; that subclass
        // can be swapped back out from under us, taking our methods with it.
        // Patching the real class underneath as well means the behaviour
        // survives KVO coming and going.
        var classesToPatch: [AnyClass] = [cls]
        if NSStringFromClass(cls).hasPrefix("NSKVONotifying_"), let real = class_getSuperclass(cls) {
            classesToPatch.append(real)
        }
        for target in classesToPatch where !patchedClasses.contains(ObjectIdentifier(target)) {
            addMethods(to: target)
            patchedClasses.insert(ObjectIdentifier(target))
        }
        // Magnet links dragged out of a browser arrive as plain text, not as a
        // URL — hence the string type alongside the file/URL ones.
        view.registerForDraggedTypes([.fileURL, .URL, .string])
        return true
    }

    private static func addMethods(to cls: AnyClass) {
        // NSDragOperation is an NSUInteger, hence the "Q" return encoding; the
        // BOOL-returning pair use "B", which is what ObjC BOOL is on arm64.
        let enter: @convention(block) (AnyObject, AnyObject) -> UInt = { _, sender in
            urls(from: sender).isEmpty ? 0 : NSDragOperation.copy.rawValue
        }
        let update: @convention(block) (AnyObject, AnyObject) -> UInt = { _, sender in
            // Without this the operation is renegotiated per mouse move and
            // some sources drop to "none" right after the badge appears.
            urls(from: sender).isEmpty ? 0 : NSDragOperation.copy.rawValue
        }
        let prepare: @convention(block) (AnyObject, AnyObject) -> Bool = { _, sender in
            !urls(from: sender).isEmpty
        }
        let perform: @convention(block) (AnyObject, AnyObject) -> Bool = { _, sender in
            let dropped = urls(from: sender)
            guard !dropped.isEmpty else { return false }
            // Deferred off this runloop pass on purpose: this runs inside
            // AppKit's drag-tracking loop, and opening a window (or activating
            // the app) from in there leaves the status item stuck in tracking —
            // the drop looks ignored and the icon stops responding entirely.
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .arrBarrDropDownloads,
                    object: nil,
                    userInfo: ["urls": dropped]
                )
            }
            return true
        }

        let added = [
            ("draggingEntered", class_addMethod(cls, #selector(NSView.draggingEntered(_:)), imp_implementationWithBlock(enter), "Q@:@")),
            ("draggingUpdated", class_addMethod(cls, #selector(NSView.draggingUpdated(_:)), imp_implementationWithBlock(update), "Q@:@")),
            ("prepareForDragOperation", class_addMethod(cls, #selector(NSView.prepareForDragOperation(_:)), imp_implementationWithBlock(prepare), "B@:@")),
            ("performDragOperation", class_addMethod(cls, #selector(NSView.performDragOperation(_:)), imp_implementationWithBlock(perform), "B@:@")),
        ]
        bridgeLog.notice(
            "\(NSStringFromClass(cls), privacy: .public): \(added.map { "\($0.0)=\($0.1)" }.joined(separator: " "), privacy: .public)"
        )
    }

    /// Payloads on the pasteboard we can actually download. Filtered here so
    /// the drag shows the "no" cursor over anything else, instead of accepting
    /// it and then silently doing nothing.
    /// AppKit delivers every dragging callback on the main thread, but the
    /// blocks installed as method implementations aren't typed as main-actor —
    /// and `NSDraggingInfo` isn't `Sendable`, so it can't cross into
    /// `assumeIsolated` on its own. The box carries it across that seam; the
    /// thread is genuinely the same one.
    private struct UncheckedSender: @unchecked Sendable { let value: AnyObject }

    private static func urls(from sender: AnyObject) -> [URL] {
        let boxed = UncheckedSender(value: sender)
        return MainActor.assumeIsolated {
            guard let info = boxed.value as? any NSDraggingInfo else { return [] }
            return payloads(on: info.draggingPasteboard)
        }
    }

    private static func payloads(on pasteboard: NSPasteboard) -> [URL] {
        var found = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        if let text = pasteboard.string(forType: .string),
           text.lowercased().hasPrefix("magnet:"),
           let magnet = URL(string: text) {
            found.append(magnet)
        }
        return found.filter {
            $0.scheme?.lowercased() == "magnet" || ["torrent", "nzb"].contains($0.pathExtension.lowercased())
        }
    }
}
