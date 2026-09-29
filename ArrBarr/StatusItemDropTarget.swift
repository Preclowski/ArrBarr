import AppKit
import ArrCore
import ObjectiveC
import os

/// Makes the menu-bar icon accept dropped torrents, nzbs and magnet links by adding
/// dragging methods to the status item's existing view classes. `.dropDestination`
/// on the MenuBarExtra label registers nothing, and an overlay view steals the click.
@MainActor
final class StatusItemDropTarget {
    private let log = Logger(category: "DownloadDrop")
    /// Weak and re-checked: SwiftUI rebuilds the status item's views on every badge
    /// change, and rebuilt views carry no drag types.
    private weak var attachedButton: NSView?
    private var watchdog: Timer?

    /// SwiftUI creates the status item after `applicationDidFinishLaunching`, so this
    /// retries; there is none in Dock-window mode, where `stop()` ends the retries.
    func install() {
        attachIfNeeded(log: true)
        // Re-attaches only when the button was replaced.
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachIfNeeded(log: false) }
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func attachIfNeeded(log logFailure: Bool) {
        guard let targets = Self.dropTargets() else {
            if logFailure { log.notice("status item views not found — menu-bar drops unavailable") }
            return
        }
        if targets.first === attachedButton, targets.allSatisfy({ !$0.registeredDraggedTypes.isEmpty }) { return }
        for target in targets { StatusItemDropBridge.attach(to: target) }
        if let root = targets.first, let window = root.window {
            let centre = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
            let hit = root.hitTest(centre)
            log.debug(
                "hit-test at icon centre: \(hit.map { String(describing: type(of: $0)) } ?? "nil", privacy: .public) types=\(hit?.registeredDraggedTypes.map(\.rawValue).joined(separator: ",") ?? "-", privacy: .public)"
            )
        }
        attachedButton = targets.first
        log.notice("menu-bar drop target attached to \(targets.count, privacy: .public) view(s)")
    }

    /// The whole chain, not just the button: drags hit-test into sibling
    /// `NSStatusBarShadowView`s whose ancestors never include the button.
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

/// Adds methods to the existing class: an `objc_allocateClassPair` subclass has
/// no Swift metadata and crashes in `swift_dynamicCast`.
@MainActor
private enum StatusItemDropBridge {
    private static let bridgeLog = Logger(category: "DownloadDrop")
    private static var patchedClasses = Set<ObjectIdentifier>()

    @discardableResult
    static func attach(to view: NSView) -> Bool {
        guard let cls: AnyClass = object_getClass(view) else { return false }

        // KVO can swap the `NSKVONotifying_*` subclass out, so patch the real class too.
        var classesToPatch: [AnyClass] = [cls]
        if NSStringFromClass(cls).hasPrefix("NSKVONotifying_"), let real = class_getSuperclass(cls) {
            classesToPatch.append(real)
        }
        for target in classesToPatch where !patchedClasses.contains(ObjectIdentifier(target)) {
            addMethods(to: target)
            patchedClasses.insert(ObjectIdentifier(target))
        }
        // Browser magnet links arrive as plain text.
        view.registerForDraggedTypes([.fileURL, .URL, .string])
        return true
    }

    private static func addMethods(to cls: AnyClass) {
        // "Q" for NSUInteger NSDragOperation; "B" is ObjC BOOL on arm64.
        let enter: @convention(block) (AnyObject, AnyObject) -> UInt = { _, sender in
            urls(from: sender).isEmpty ? 0 : NSDragOperation.copy.rawValue
        }
        let update: @convention(block) (AnyObject, AnyObject) -> UInt = { _, sender in
            // Otherwise some sources renegotiate to "none" right after the badge appears.
            urls(from: sender).isEmpty ? 0 : NSDragOperation.copy.rawValue
        }
        let prepare: @convention(block) (AnyObject, AnyObject) -> Bool = { _, sender in
            !urls(from: sender).isEmpty
        }
        let perform: @convention(block) (AnyObject, AnyObject) -> Bool = { _, sender in
            let dropped = urls(from: sender)
            guard !dropped.isEmpty else { return false }
            // Opening a window inside AppKit's drag-tracking loop leaves the status item stuck.
            DispatchQueue.main.async { AppMessages.post(AppMessages.DropDownloads(urls: dropped)) }
            return true
        }

        let added = [
            ("draggingEntered", class_addMethod(cls, #selector(NSView.draggingEntered(_:)), imp_implementationWithBlock(enter), "Q@:@")),
            ("draggingUpdated", class_addMethod(cls, #selector(NSView.draggingUpdated(_:)), imp_implementationWithBlock(update), "Q@:@")),
            ("prepareForDragOperation", class_addMethod(cls, #selector(NSView.prepareForDragOperation(_:)), imp_implementationWithBlock(prepare), "B@:@")),
            ("performDragOperation", class_addMethod(cls, #selector(NSView.performDragOperation(_:)), imp_implementationWithBlock(perform), "B@:@")),
        ]
        bridgeLog.debug(
            "\(NSStringFromClass(cls), privacy: .public): \(added.map { "\($0.0)=\($0.1)" }.joined(separator: " "), privacy: .public)"
        )
    }

    /// Dragging callbacks run on the main thread but the blocks aren't main-actor
    /// typed, and `NSDraggingInfo` isn't Sendable; this box crosses that seam.
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
