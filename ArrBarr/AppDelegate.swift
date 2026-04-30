import AppKit
import SwiftUI
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
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

        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        DemoMode.seedConfigsIfNeeded(configStore)

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

        let view = SettingsView().environmentObject(configStore)
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
