import AppKit
import SwiftUI
import Combine
import UserNotifications
import CoreSpotlight
import ArrCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var paywallWindow: NSWindow?
    private let configStore = ConfigStore.shared
    private let queueVM = QueueViewModel.shared
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerNotificationCategories()
        UNUserNotificationCenter.current().delegate = self

        DemoMode.seedConfigsIfNeeded(configStore)

        // Drive the whole app's appearance from the preset. On macOS the
        // per-scene `.preferredColorScheme` doesn't reach the menu-bar popover
        // or the NSHostingController-backed windows; `NSApp.appearance` does,
        // and applies to every window at once.
        applyAppearance(configStore.appearance)
        configStore.$appearance
            .sink { [weak self] in self?.applyAppearance($0) }
            .store(in: &cancellables)

        // Paywall presentation (App Store builds). The gate lives in ArrCore as
        // a published `gatedFeature`. We deliberately do NOT present it as a
        // sheet inside the MenuBarExtra panel — that panel auto-dismisses the
        // instant it resigns key, which happens the moment StoreKit's purchase
        // UI takes focus. So mirror the Settings/About pattern and host the
        // paywall in a real NSWindow that survives focus changes.
        StoreManager.shared.$gatedFeature
            .receive(on: RunLoop.main)
            .sink { [weak self] feature in
                if feature != nil { self?.showPaywall() } else { self?.closePaywall() }
            }
            .store(in: &cancellables)

        showWelcomeIfNeeded()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        Task.detached { await ImageCache.shared.purgeOlderThan(30) }

        // Index the library into Spotlight (search "american pie" → result).
        SpotlightIndexer.reindex(configStore: configStore)

        // Wake handler — WebSockets don't survive a Mac sleep cycle
        // reliably; the OS can take 30-90 s to surface the dead socket,
        // during which SignalR pushes silently drop. Force a tear-and-
        // rebuild of every realtime connection right after wake so the
        // data the user sees on the next panel open is current.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.queueVM.systemDidWake() }
        }
    }

    // MARK: - Notification categories

    private func registerNotificationCategories() {
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

    private func applyAppearance(_ pref: String) {
        switch pref {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }
    }

    // MARK: - Spotlight

    /// Re-index when the app is re-activated so posters cached while browsing
    /// get picked up (cached-only thumbnails). Throttled inside `reindex`.
    func applicationDidBecomeActive(_ notification: Notification) {
        SpotlightIndexer.reindex(configStore: configStore)
    }

    /// A Spotlight result was clicked. The menu-bar app has no window to host
    /// a detail view, so open the item in the arr's web UI instead.
    func application(_ application: NSApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
            return false
        }
        Task { @MainActor in
            if let url = await SpotlightIndexer.browserURL(forIdentifier: id, configStore: configStore) {
                NSWorkspace.shared.open(url)
            }
        }
        return true
    }

    // MARK: - Paywall

    /// Host the paywall in a real, focus-stable NSWindow. Presenting it inside
    /// the MenuBarExtra panel breaks: the panel resigns key (and self-closes)
    /// the moment StoreKit's purchase sheet appears, aborting the purchase.
    private func showPaywall() {
        if let win = paywallWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = PaywallView(context: StoreManager.shared.gatedFeature) {
            StoreManager.shared.dismissPaywall()
        }
        .environmentObject(configStore)
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = String(localized: "Control", bundle: .arrCore)
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 400, height: 560))
        win.isReleasedWhenClosed = false
        win.center()
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.paywallWindow = nil
                // Closing the window cancels the gate so state stays consistent.
                StoreManager.shared.dismissPaywall()
            }
        }
        paywallWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePaywall() {
        guard let win = paywallWindow else { return }
        paywallWindow = nil
        win.close()
    }

    // MARK: - About

    /// Native macOS About window. The standard panel renders the app icon,
    /// name, version and copyright automatically; we supply a `.credits`
    /// attributed string for the "Made by" line plus the clickable links
    /// (GitHub / Website / Privacy Policy / icon attribution) that used to
    /// live in the Settings footer.
    func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .credits: Self.aboutCredits
        ]
        // The standard panel's default icon comes from Launch Services, which
        // can serve a stale cached icon. Load the current compiled AppIcon
        // straight from the asset catalog so the panel always matches the
        // shipped icon.
        if let icon = NSImage(named: "AppIcon") {
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var aboutCredits: NSAttributedString {
        let bundle = Bundle.arrCore
        let result = NSMutableAttributedString()

        func appendLine(_ title: String, _ urlString: String) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .link: URL(string: urlString)!,
            ]
            result.append(NSAttributedString(string: title + "\n", attributes: attrs))
        }
        func appendPlain(_ text: String, size: CGFloat = 11, color: NSColor = .secondaryLabelColor) {
            result.append(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: color,
            ]))
        }

        appendPlain("Made by 🥨\n\n", size: 12, color: .labelColor)
        // Order: app first, then privacy, then source.
        appendLine(String(localized: "Website", bundle: bundle), "https://arrbarr.app")
        appendLine(String(localized: "Privacy Policy", bundle: bundle), "https://arrbarr.app/privacy-policy")
        appendLine("GitHub", "https://github.com/Preclowski/ArrBarr")
        appendPlain("\n")
        result.append(NSAttributedString(string: "Dashboard Icons · CC BY 4.0", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .link: URL(string: "https://dashboardicons.com")!,
        ]))

        // Centre everything so the credits read as a tidy block under the
        // auto-rendered icon / name / version.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 3
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: - Settings

    func openSettings() {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(
            onShowWelcome: { [weak self] in self?.openWelcome(force: true) },
            onTestNotification: { [weak self] in self?.queueVM.fireTestNotification() },
            onSetDemoMode: { [weak self] enabled in self?.setDemoModeAndRelaunch(enabled) ?? false }
        ).environmentObject(configStore)
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        win.title = String(localized: "ArrBarr Settings", bundle: .arrCore) + (shortVersion.isEmpty ? "" : " v\(shortVersion)")
        // `.closable` shows the standard traffic-light cluster with the red
        // close button active; minimize + zoom render greyed-out (no
        // `.miniaturizable` / `.resizable`), matching "three buttons, only
        // close enabled".
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 520, height: 460))
        win.isReleasedWhenClosed = false
        // Centre the title. macOS left-aligns standard titles, so hide the
        // native one and host a centred label as a full-width titlebar
        // accessory.
        win.titleVisibility = .hidden
        installCenteredTitle(win.title, in: win)
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

    /// Pin a centred title label into the window's titlebar container. macOS
    /// has no API to centre the native title (it's left-aligned after the
    /// traffic lights), so with `titleVisibility = .hidden` we add our own
    /// label centred to the titlebar's full width.
    private func installCenteredTitle(_ title: String, in win: NSWindow) {
        guard let titlebar = win.standardWindowButton(.closeButton)?.superview else { return }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: titlebar.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: titlebar.centerYAnchor),
        ])
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
            onTryDemo: { [weak self] in self?.enableDeveloperModeAndRelaunch() },
            onFinish: { [weak self] in
                // Close welcome. The MenuBarExtra icon is already
                // visible — user clicks it themselves to land on the
                // panel they just learned about.
                self?.welcomeWindow?.performClose(nil)
            }
        ).environmentObject(configStore)

        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = String(localized: "Welcome to ArrBarr", bundle: .arrCore)
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

    private func enableDeveloperModeAndRelaunch() {
        // Welcome-screen handoff: only flip the developer-mode flag, matching
        // `--demo` launch-arg semantics. Fixtures stay off until the user
        // explicitly toggles "Demo mode" inside the now-visible Developer
        // options section. The two flags are evaluated once at process start,
        // so we relaunch to take effect.
        UserDefaults.standard.set(true, forKey: DeveloperMode.key)

        let alert = NSAlert()
        alert.messageText = String(localized: "Developer options enabled", bundle: .arrCore)
        alert.informativeText = String(localized: "ArrBarr will relaunch. Open Settings → General to enable Demo mode and load preview content.", bundle: .arrCore)
        alert.addButton(withTitle: String(localized: "Relaunch", bundle: .arrCore))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .arrCore))
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        relaunchSelf()
    }

    private func setDemoModeAndRelaunch(_ enabled: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = enabled
            ? String(localized: "Demo mode enabled", bundle: .arrCore)
            : String(localized: "Demo mode disabled", bundle: .arrCore)
        alert.informativeText = String(localized: "ArrBarr will relaunch now to apply the change.", bundle: .arrCore)
        alert.addButton(withTitle: String(localized: "Relaunch", bundle: .arrCore))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .arrCore))
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return false }

        UserDefaults.standard.set(enabled, forKey: DemoMode.key)
        // Re-point the live store now (belt-and-suspenders before relaunch).
        configStore.useDemoStore(enabled)
        if !enabled {
            // Wipe the demo profile entirely (configs + seed flag) so the next
            // enable re-seeds a clean demo. Targets ONLY the demo suite — the
            // real profile in `.standard` is never touched.
            DemoMode.resetDemoStore()
        }
        relaunchSelf()
        return true
    }

    private func relaunchSelf() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
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
            // Tapping the banner body is a no-op now that MenuBarExtra
            // owns the panel — there's no public API to open it
            // programmatically. The user clicks the menu-bar icon.
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
        queueVM.items(for: source).first { $0.arrQueueId == arrQueueId }
    }
}
