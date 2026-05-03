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
        let category = UNNotificationCategory(
            identifier: NotificationCoalescer.categoryIdentifier,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
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
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
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

        let view = SettingsView(onShowWelcome: { [weak self] in
            self?.openWelcome(force: true)
        }).environmentObject(configStore)
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
            if force {
                return configStore.welcomeSeenVersion == nil
                    ? .firstRun
                    : .whatsNew(version: WelcomeContent.currentVersion)
            }
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
                self?.welcomeWindow?.performClose(nil)
                self?.openSettings()
            },
            onTryDemo: { [weak self] in self?.enableDemoModeAndRelaunch() }
        ).environmentObject(configStore)

        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = String(localized: "Welcome to ArrBarr")
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 600, height: 680))
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

    /// Tapping the banner OR pressing the "Open in browser" action both open
    /// the arr's `/activity/queue` page using the base URL we stored in userInfo.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let action = response.actionIdentifier
        guard action == UNNotificationDefaultActionIdentifier
              || action == NotificationCoalescer.openActionIdentifier
        else { return }
        guard let base = response.notification.request.content.userInfo[NotificationCoalescer.userInfoBaseURLKey] as? String,
              let url = ArrActivityURLBuilder.queueURL(forBase: base),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        Task { @MainActor in NSWorkspace.shared.open(url) }
    }
}
