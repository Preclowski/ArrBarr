import SwiftUI
import Foundation

/// A confirmation waiting for an answer. Carries the copy (catalog keys, so
/// both the SwiftUI card and an AppKit alert can render it) plus the
/// `onConfirm` closure that fires when the user approves.
public struct PendingConfirm: Sendable, Identifiable {
    public let id = UUID()
    public var title: String
    public var message: String?
    public var confirmLabel: String
    public var cancelLabel: String
    public var isDestructive: Bool
    /// Catalog key of a "don't show again" checkbox; `onSuppress` fires when
    /// the user confirms with it ticked.
    public var suppressionLabel: String?
    public var onConfirm: @MainActor () -> Void
    public var onSuppress: @MainActor () -> Void

    public init(
        title: String,
        message: String? = nil,
        confirmLabel: String,
        cancelLabel: String = "Cancel",
        isDestructive: Bool = false,
        suppressionLabel: String? = nil,
        onConfirm: @escaping @MainActor () -> Void,
        onSuppress: @escaping @MainActor () -> Void = {}
    ) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.isDestructive = isDestructive
        self.suppressionLabel = suppressionLabel
        self.onConfirm = onConfirm
        self.onSuppress = onSuppress
    }
}

/// Where a confirmation lives between "a row asked for it" and "the user
/// answered".
///
/// It is state, not an event. A context menu is the reason: macOS tears the
/// MenuBarExtra panel down the moment the menu takes focus, so by the time the
/// user picks "Remove from queue" the surface that would have caught a posted
/// message — and the `@State` it would have stored it in — is already gone, and
/// the confirmation never appeared. Held here, the request survives that; and
/// when no surface is left to draw the card, macOS answers with a native alert
/// instead of swallowing the action.
public final class ConfirmCenter: ObservableObject {
    public static let shared = ConfirmCenter()

    @Published public private(set) var pending: PendingConfirm?

    /// Set by the surface that renders `pending` (the panel / detached window)
    /// while it is on screen. False means nobody can draw the card.
    public var hasVisibleHost = false

    public func request(_ p: PendingConfirm) {
        pending = p
        #if os(macOS)
        if !hasVisibleHost {
            NativeConfirmAlert.present(p, locale: ConfigStore.shared.currentLocale)
        }
        #endif
    }

    /// Any view in the tree can ask for a confirmation; the host renders it.
    public static func request(_ p: PendingConfirm) { shared.request(p) }

    public func confirm(suppressing: Bool = false) {
        guard let p = pending else { return }
        pending = nil
        if suppressing { p.onSuppress() }
        p.onConfirm()
    }

    public func cancel() { pending = nil }
}
