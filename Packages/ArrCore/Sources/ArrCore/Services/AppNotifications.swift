import Foundation

public extension Notification.Name {
    /// Posted by AppDelegate when the user picks "Add…" from the status menu.
    /// PopoverContentView listens for this and opens the search overlay.
    static let arrBarrTriggerAdd = Notification.Name("ArrBarrTriggerAdd")
}
