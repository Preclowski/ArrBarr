import AppKit
import UserNotifications
import ArrCore

extension AppDelegate {
    // MARK: - Notification categories

    func registerNotificationCategories() {
        let openAction = UNNotificationAction(
            identifier: NotificationCoalescer.openActionIdentifier,
            title: String(localized: "Open in browser", bundle: .arrCore),
            options: [.foreground]
        )
        let pauseAction = UNNotificationAction(
            identifier: NotificationCoalescer.pauseActionIdentifier,
            title: String(localized: "Pause", bundle: .arrCore),
            options: []
        )
        let resumeAction = UNNotificationAction(
            identifier: NotificationCoalescer.resumeActionIdentifier,
            title: String(localized: "Start downloading", bundle: .arrCore),
            options: []
        )
        let removeAction = UNNotificationAction(
            identifier: NotificationCoalescer.removeActionIdentifier,
            title: String(localized: "Remove", bundle: .arrCore),
            options: [.destructive]
        )

        // A batched banner can't target one item, so only "Open".
        let batchCategory = UNNotificationCategory(
            identifier: NotificationCoalescer.categoryIdentifier,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        let downloadingCategory = UNNotificationCategory(
            identifier: NotificationCoalescer.downloadingCategoryIdentifier,
            actions: [openAction, pauseAction, removeAction],
            intentIdentifiers: [],
            options: []
        )
        let pausedCategory = UNNotificationCategory(
            identifier: NotificationCoalescer.pausedCategoryIdentifier,
            actions: [openAction, resumeAction, removeAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([
            batchCategory, downloadingCategory, pausedCategory,
        ])
    }
}

extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        switch action {
        case UNNotificationDefaultActionIdentifier:
            // No public API opens the MenuBarExtra panel programmatically.
            break
        case NotificationCoalescer.openActionIdentifier:
            openArrQueue(from: userInfo)
        case NotificationCoalescer.pauseActionIdentifier:
            performQueueAction(from: userInfo) { vm, item in
                Task { await vm.pause(item) }
            }
        case NotificationCoalescer.resumeActionIdentifier:
            performQueueAction(from: userInfo) { vm, item in
                Task { await vm.resume(item) }
            }
        case NotificationCoalescer.removeActionIdentifier:
            performQueueAction(from: userInfo) { vm, item in
                Task { await vm.delete(item) }
            }
        default:
            break
        }
    }

    private func openArrQueue(from userInfo: [AnyHashable: Any]) {
        guard let base = userInfo[NotificationCoalescer.userInfoBaseURLKey] as? String,
              let url = ArrActivityURLBuilder.queueURL(forBase: base),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        Task { @MainActor in NSWorkspace.shared.open(url) }
    }

    private func performQueueAction(
        from userInfo: [AnyHashable: Any],
        run: @escaping @MainActor (QueueViewModel, QueueItem) -> Void
    ) {
        guard let sourceRaw = userInfo[NotificationCoalescer.userInfoSourceKey] as? String,
              let source = QueueItem.Source(rawValue: sourceRaw),
              let arrQueueId = userInfo[NotificationCoalescer.userInfoQueueIdKey] as? Int
        else { return }
        Task { @MainActor in
            // The VM may not have polled yet if the popover was never opened.
            if findItem(source: source, arrQueueId: arrQueueId) == nil {
                await queueVM.refresh()
            }
            guard let item = findItem(source: source, arrQueueId: arrQueueId) else {
                Self.log.notice(
                    "notification action for \(source.rawValue, privacy: .public) queue item \(arrQueueId, privacy: .public): no longer in the queue, ignored"
                )
                return
            }
            Self.log.notice(
                "notification action ran on \(source.rawValue, privacy: .public) queue item \(arrQueueId, privacy: .public)"
            )
            run(queueVM, item)
        }
    }

    private func findItem(source: QueueItem.Source, arrQueueId: Int) -> QueueItem? {
        queueVM.items(for: source).first { $0.arrQueueId == arrQueueId }
    }
}
