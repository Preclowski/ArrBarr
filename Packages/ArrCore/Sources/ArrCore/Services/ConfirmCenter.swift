import SwiftUI
import Foundation

/// Payload of `AppMessages.ConfirmRequest`. Carries the
/// confirmation copy + an `onConfirm` closure that fires when the user
/// approves. Deep-tree views (queue row trash icons) post one of these
/// and `PopoverContentView` renders the inline overlay at panel width.
public struct PendingConfirm: Sendable {
    public var title: LocalizedStringKey
    public var message: LocalizedStringKey?
    public var confirmLabel: LocalizedStringKey
    public var cancelLabel: LocalizedStringKey
    public var isDestructive: Bool
    public var onConfirm: @MainActor () -> Void

    public init(
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        confirmLabel: LocalizedStringKey,
        cancelLabel: LocalizedStringKey = "Cancel",
        isDestructive: Bool = false,
        onConfirm: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.isDestructive = isDestructive
        self.onConfirm = onConfirm
    }
}

public enum ConfirmCenter {
    /// Any view in the tree can ask for a confirmation; the host stores it in @State and renders the overlay.
    @MainActor public static func request(_ p: PendingConfirm) { AppMessages.post(AppMessages.ConfirmRequest(payload: p)) }
}
