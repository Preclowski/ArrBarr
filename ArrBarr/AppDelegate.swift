import AppKit
import SwiftUI
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var escMonitor: Any?
    private var outsideClickMonitor: Any?

    private let configStore = ConfigStore.shared
    private let queueVM = QueueViewModel()
    private var badgeObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusBarTitle(active: queueVM.activeCount)
        registerNotificationCategories()
        UNUserNotificationCenter.current().delegate = self

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        let root = PopoverContentView(
            viewModel: queueVM,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        .environmentObject(configStore)

        // Don't enable any sizingOptions on the hosting controller. With
        // .preferredContentSize / .intrinsicContentSize, NSHostingController
        // pushes a fresh size to NSPopover on every SwiftUI body invalidation
        // — and a refresh fires several @Published changes per cycle, which
        // causes NSPopover to repaint its window each time. That repaint is
        // the popover-wide blink the user keeps reporting. Instead, we
        // measure the SwiftUI content's preferred size once when the popover
        // opens (see togglePopover) and pin the popover to that size for the
        // duration the popover is shown.
        let hosting = NSHostingController(rootView: root)
        popover.contentSize = NSSize(width: 400, height: 600)
        popover.contentViewController = hosting

        DemoMode.seedConfigsIfNeeded(configStore)

        showWelcomeIfNeeded()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        Task.detached { await ImageCache.shared.purgeOlderThan(30) }

        badgeObserver = Publishers.CombineLatest3(queueVM.$radarr, queueVM.$sonarr, queueVM.$lidarr)
            .sink { [weak self] radarr, sonarr, lidarr in
                let active = (radarr + sonarr + lidarr).filter { $0.status != .completed }.count
                self?.updateStatusBarTitle(active: active)
            }
    }

    // MARK: - Status item

    private func updateStatusBarTitle(active: Int) {
        guard let button = statusItem.button else { return }

        let a11yLabel = active > 0
            ? "ArrBarr — \(active) active download\(active == 1 ? "" : "s")"
            : "ArrBarr — no active downloads"
        let symbolName = active > 0 ? "arrow.down.circle.fill" : "arrow.down.circle"
        let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: a11yLabel)
        icon?.isTemplate = true

        if active > 0 {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = CGRect(x: 0, y: -3, width: 16, height: 16)
            let mutable = NSMutableAttributedString()
            mutable.append(NSAttributedString(attachment: attachment))
            mutable.append(NSAttributedString(
                string: " \(active)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
                ]
            ))
            button.attributedTitle = mutable
            button.image = nil
        } else {
            button.image = icon
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    // MARK: - Notification categories

    private func registerNotificationCategories() {
        let openAction = UNNotificationAction(
            identifier: NotificationCoalescer.openActionIdentifier,
            title: String(localized: "Open in browser"),
            options: [.foreground]
        )
        let pauseAction = UNNotificationAction(
            identifier: NotificationCoalescer.pauseActionIdentifier,
            title: String(localized: "Pause"),
            options: []
        )
        let resumeAction = UNNotificationAction(
            identifier: NotificationCoalescer.resumeActionIdentifier,
            title: String(localized: "Start downloading"),
            options: []
        )
        let removeAction = UNNotificationAction(
            identifier: NotificationCoalescer.removeActionIdentifier,
            title: String(localized: "Remove"),
            options: [.destructive]
        )

        // Multi-item batch — only "Open" is meaningful; pause/remove can't
        // target a specific item from a batched banner.
        let batchCategory = UNNotificationCategory(
            identifier: NotificationCoalescer.categoryIdentifier,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        // Single item that's currently downloading.
        let downloadingCategory = UNNotificationCategory(
            identifier: NotificationCoalescer.downloadingCategoryIdentifier,
            actions: [openAction, pauseAction, removeAction],
            intentIdentifiers: [],
            options: []
        )
        // Single item that's currently paused (or queued waiting on the
        // download client).
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

    // MARK: - Popover

    @objc private func statusItemClicked(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.option) {
            showStatusMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        queueVM.startForegroundPolling()
        installEscMonitor()
        // Re-measure once on open so the popover hugs the SwiftUI content
        // for the current state (history vs queue vs empty). After this,
        // the size stays put until the popover closes — refresh-driven
        // body invalidations no longer cause a window resize/repaint.
        DispatchQueue.main.async { [weak self] in
            guard let self, let hosting = self.popover.contentViewController else { return }
            let fitting = hosting.view.fittingSize
            if fitting.width > 0 && fitting.height > 0 {
                self.popover.contentSize = fitting
            }
        }
    }

    private func installEscMonitor() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.popover.isShown == true {
                self?.popover.performClose(nil)
                return nil
            }
            return event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
    }

    private func removeEscMonitor() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Refresh"), action: #selector(menuRefresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: String(localized: "Quit ArrBarr"), action: #selector(menuQuit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuRefresh() { Task { await queueVM.refresh() } }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: - Settings

    private func openSettings() {
        if popover.isShown { popover.performClose(nil) }

        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(
            onShowWelcome: { [weak self] in self?.openWelcome(force: true) },
            onTestNotification: { [weak self] in self?.queueVM.fireTestNotification() }
        ).environmentObject(configStore)
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = String(localized: "ArrBarr Settings")
        win.styleMask = [.titled]
        win.setContentSize(NSSize(width: 520, height: 460))
        win.isReleasedWhenClosed = false
        win.center()

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.settingsWindow = nil }
        }

        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Welcome

    private func showWelcomeIfNeeded() {
        // Upgrade from a pre-welcome build: they already configured services
        // before the welcome screen existed. Showing first-run would be
        // confusing; silently mark them caught up so the next major-update
        // welcome still fires.
        let isUpgradeFromPreWelcome = configStore.welcomeSeenVersion == nil
            && hasAnyConfiguredArr
        if isUpgradeFromPreWelcome && !WelcomeContent.shouldForceShow() {
            configStore.welcomeSeenVersion = WelcomeContent.currentVersion
            return
        }
        guard let variant = WelcomeContent.variant(seen: configStore.welcomeSeenVersion) else { return }
        openWelcome(variant: variant)
    }

    private var hasAnyConfiguredArr: Bool {
        // A demo-seeded user has `enabled = true` but no `baseURL`; only count
        // real configurations.
        !configStore.radarr.baseURL.isEmpty
            || !configStore.sonarr.baseURL.isEmpty
            || !configStore.lidarr.baseURL.isEmpty
    }

    private func openWelcome(force: Bool = false) {
        let variant: WelcomeContent.Variant = {
            if force { return .firstRun }
            return WelcomeContent.variant(seen: configStore.welcomeSeenVersion) ?? .firstRun
        }()
        openWelcome(variant: variant)
    }

    private func openWelcome(variant: WelcomeContent.Variant) {
        if let win = welcomeWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = WelcomeView(
            variant: variant,
            onDismiss: { [weak self] in self?.welcomeWindow?.performClose(nil) },
            onAddService: { [weak self] in
                // Open Settings on top of the welcome window — don't close
                // welcome. The user can configure and come back to finish
                // the tour.
                self?.openSettings()
            },
            onTryDemo: { [weak self] in self?.enableDemoModeAndRelaunch() },
            onFinish: { [weak self] in
                // Done at the end of the tour: close welcome, then pop the
                // status-bar popover so the user lands on the thing they
                // just learned about.
                self?.welcomeWindow?.performClose(nil)
                self?.openPopover()
            }
        ).environmentObject(configStore)

        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = String(localized: "Welcome to ArrBarr")
        // Apple "What's New" style: no titlebar text, content extends under
        // the title bar (we draw our own close button in the top-right), and
        // the user can drag the window from anywhere on the background.
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        // We draw our own X close button in the content's top-right corner —
        // hide the standard traffic-light close so the window has just one
        // unambiguous dismiss control.
        win.standardWindowButton(.closeButton)?.isHidden = true
        // MUST match WelcomeView's `.frame(width:height:)` — a mismatch leaves
        // a strip of NSWindow background showing through where the SwiftUI
        // content stops, which reads as "window inside the window".
        win.setContentSize(NSSize(width: 400, height: 440))
        win.isReleasedWhenClosed = false
        win.center()

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.configStore.welcomeSeenVersion = WelcomeContent.currentVersion
                self.welcomeWindow = nil
            }
        }

        welcomeWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func enableDemoModeAndRelaunch() {
        // DemoMode.isActive is evaluated once at process start, so flipping the
        // UserDefaults flag mid-run has no effect until next launch. Set the
        // flag, tell the user, then relaunch ourselves.
        UserDefaults.standard.set(true, forKey: "ArrBarrDemo")

        let alert = NSAlert()
        alert.messageText = String(localized: "Demo mode enabled")
        alert.informativeText = String(localized: "ArrBarr will relaunch now to load demo content.")
        alert.addButton(withTitle: String(localized: "Relaunch"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let url = Bundle.main.bundleURL
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        queueVM.stopForegroundPolling()
        queueVM.setTonightExpanded(false)
        removeEscMonitor()
    }
}

extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    /// Show the banner even when the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Tap on banner / "Open in browser" → opens the arr's queue page.
    /// Pause / Resume / Remove → looks up the QueueItem by source + arrQueueId
    /// in the current QueueViewModel state and calls the matching action.
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
            // Tapping the banner body opens the menu-bar popover —
            // that's the app's primary surface and likely what the user
            // expects after seeing a status update.
            Task { @MainActor in self.openPopover() }
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
            // Find the item in the current snapshot. If the user hasn't opened
            // the popover since launch the VM may not have polled yet — kick
            // a refresh first so the item is present.
            if findItem(source: source, arrQueueId: arrQueueId) == nil {
                await queueVM.refresh()
            }
            guard let item = findItem(source: source, arrQueueId: arrQueueId) else { return }
            run(queueVM, item)
        }
    }

    private func findItem(source: QueueItem.Source, arrQueueId: Int) -> QueueItem? {
        let pool: [QueueItem]
        switch source {
        case .radarr: pool = queueVM.radarr
        case .sonarr: pool = queueVM.sonarr
        case .lidarr: pool = queueVM.lidarr
        }
        return pool.first { $0.arrQueueId == arrQueueId }
    }
}
