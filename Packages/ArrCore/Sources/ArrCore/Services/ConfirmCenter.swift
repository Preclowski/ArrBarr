import SwiftUI
import Foundation

/// Payload for `arrBarrConfirmRequest` notifications. Carries the
/// confirmation copy + an `onConfirm` closure that fires when the user
/// approves. Deep-tree views (queue row trash icons) post one of these
/// and `PopoverContentView` renders the inline overlay at panel width.
public struct PendingConfirm {
    public var title: LocalizedStringKey
    public var message: LocalizedStringKey?
    public var confirmLabel: LocalizedStringKey
    public var cancelLabel: LocalizedStringKey
    public var isDestructive: Bool
    public var onConfirm: () -> Void

    public init(
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        confirmLabel: LocalizedStringKey,
        cancelLabel: LocalizedStringKey = "Cancel",
        isDestructive: Bool = false,
        onConfirm: @escaping () -> Void
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
    /// Posts a `PendingConfirm` through `NotificationCenter` so any
    /// view in the tree can fire one without needing access to a
    /// shared `ObservableObject`. `PopoverContentView`'s `.onReceive`
    /// listener picks it up and stores it in @State for rendering.
    @MainActor public static func request(_ p: PendingConfirm) {
        NotificationCenter.default.post(
            name: .arrBarrConfirmRequest,
            object: nil,
            userInfo: ["payload": p]
        )
    }
}
