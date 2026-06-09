import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Notification action buttons (shared)
//
// Pause / Resume / Remove / Open straight from a grab notification. macOS
// wires this in its AppDelegate; this shared helper lets iOS register the same
// categories and handle the responses (iOS has no app delegate of its own).
// Identifiers come from NotificationCoalescer so both platforms stay in sync.
public enum NotificationActions {

    /// Build the action categories (same set the macOS AppDelegate uses).
    public static func categories() -> [UNNotificationCategory] {
        let open = UNNotificationAction(
            identifier: NotificationCoalescer.openActionIdentifier,
            title: String(localized: "detail.openInBrowser.button", bundle: .module),
            options: [.foreground]
        )
        let pause = UNNotificationAction(
            identifier: NotificationCoalescer.pauseActionIdentifier,
            title: String(localized: "queue.pause.button", bundle: .module),
            options: []
        )
        let resume = UNNotificationAction(
            identifier: NotificationCoalescer.resumeActionIdentifier,
            title: String(localized: "intents.startDownloading.button", bundle: .module),
            options: []
        )
        let remove = UNNotificationAction(
            identifier: NotificationCoalescer.removeActionIdentifier,
            title: String(localized: "common.remove.button", bundle: .module),
            options: [.destructive]
        )
        return [
            UNNotificationCategory(identifier: NotificationCoalescer.categoryIdentifier,
                                   actions: [open], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationCoalescer.downloadingCategoryIdentifier,
                                   actions: [open, pause, remove], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationCoalescer.pausedCategoryIdentifier,
                                   actions: [open, resume, remove], intentIdentifiers: [], options: []),
        ]
    }

    public static func register() {
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories()))
    }

    /// Run a tapped action. Values are pre-extracted (Sendable) by the delegate.
    @MainActor
    public static func handle(action: String, source: String?, arrQueueId: Int?, baseURL: String?) async {
        switch action {
        case NotificationCoalescer.openActionIdentifier:
            openQueue(baseURL: baseURL)
        case NotificationCoalescer.pauseActionIdentifier:
            await act(source: source, arrQueueId: arrQueueId) { vm, item in await vm.pause(item) }
        case NotificationCoalescer.resumeActionIdentifier:
            await act(source: source, arrQueueId: arrQueueId) { vm, item in await vm.resume(item) }
        case NotificationCoalescer.removeActionIdentifier:
            await act(source: source, arrQueueId: arrQueueId) { vm, item in await vm.delete(item) }
        default:
            break
        }
    }

    @MainActor
    private static func act(source: String?, arrQueueId: Int?,
                            run: (QueueViewModel, QueueItem) async -> Void) async {
        guard let sourceRaw = source, let src = QueueItem.Source(rawValue: sourceRaw),
              let qid = arrQueueId else { return }
        let vm = QueueViewModel.shared
        // The shared VM may not have polled yet — refresh so the item exists.
        if vm.items(for: src).first(where: { $0.arrQueueId == qid }) == nil {
            await vm.refresh()
        }
        guard let item = vm.items(for: src).first(where: { $0.arrQueueId == qid }) else { return }
        await run(vm, item)
    }

    @MainActor
    private static func openQueue(baseURL: String?) {
        guard let base = baseURL,
              let url = ArrActivityURLBuilder.queueURL(forBase: base),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

/// UNUserNotificationCenter delegate for iOS (macOS uses its AppDelegate).
/// Shows banners in-foreground and routes action taps to `NotificationActions`.
public final class ArrNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = ArrNotificationDelegate()

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        // Extract Sendable values before hopping actors (UNNotificationResponse
        // / userInfo aren't Sendable).
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let source = info[NotificationCoalescer.userInfoSourceKey] as? String
        let qid = info[NotificationCoalescer.userInfoQueueIdKey] as? Int
        let base = info[NotificationCoalescer.userInfoBaseURLKey] as? String
        Task { @MainActor in
            await NotificationActions.handle(action: action, source: source, arrQueueId: qid, baseURL: base)
            completionHandler()
        }
    }
}
