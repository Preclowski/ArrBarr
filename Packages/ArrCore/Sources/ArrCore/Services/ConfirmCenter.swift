import SwiftUI
import Foundation

/// Catalog keys, so both the SwiftUI card and an AppKit alert can render it.
public struct PendingConfirm: Sendable, Identifiable {
    public let id = UUID()
    public var title: String
    public var message: String?
    public var confirmLabel: String
    public var cancelLabel: String
    public var isDestructive: Bool
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

/// State, not an event: macOS tears the MenuBarExtra panel down when a context menu takes focus, so a posted
/// message would be lost. With no surface left to draw the card, macOS falls back to a native alert.
public final class ConfirmCenter: ObservableObject {
    public static let shared = ConfirmCenter()

    @Published public private(set) var pending: PendingConfirm?

    /// False means nobody can draw the card.
    public var hasVisibleHost = false

    public func request(_ p: PendingConfirm) {
        pending = p
        #if os(macOS)
        if !hasVisibleHost {
            NativeConfirmAlert.present(p, locale: ConfigStore.shared.currentLocale)
        }
        #endif
    }

    public static func request(_ p: PendingConfirm) { shared.request(p) }

    public func confirm(suppressing: Bool = false) {
        guard let p = pending else { return }
        pending = nil
        if suppressing { p.onSuppress() }
        p.onConfirm()
    }

    public func cancel() { pending = nil }
}
