import AppKit
import SwiftUI
import Combine
import UserNotifications
import CoreSpotlight
import ArrCore
import ArrMCPServer
import Logging

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var paywallWindow: NSWindow?
    private let configStore = ConfigStore.shared
    private let queueVM = QueueViewModel.shared
    private lazy var mcpController = MCPServerController()
    private var cancellables = Set<AnyCancellable>()

    /// Route swift-log (MCP server, NIO) into os.Logger. Runs exactly once;
    /// must happen before the first `Logger` is created (hence `mcpController`
    /// is lazy and first touched in `wireMCPServer`).
    private static let bootstrapLogging: Void = {
        LoggingSystem.bootstrap { OSLogForwardingHandler(label: $0) }
    }()

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

        // Dock-icon vs menu-bar-only mode. The sink fires once on subscribe
        // with the current value (the initial apply), then on every toggle.
        configStore.$detachedWindow
            .removeDuplicates()
            .sink { [weak self] in self?.applyWindowMode($0) }
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

        _ = Self.bootstrapLogging
        wireMCPServer()

        showWelcomeIfNeeded()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        Task.detached { await ImageCache.shared.purgeOlderThan(30) }

        // Index the library into Spotlight (search "american pie" → result).
        // `--clear-intents` instead wipes ArrBarr's own Spotlight entries and
        // skips reindexing — a one-shot way to clear stale icons.
        if CommandLine.arguments.contains("--clear-intents") {
            Task { @MainActor in
                await SpotlightIndexer.clearIndex()
                NSLog("ArrBarr: cleared Spotlight intents index (--clear-intents)")
            }
        } else {
            SpotlightIndexer.reindex(configStore: configStore)
        }

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

    // MARK: - MCP server

    /// Mirror the server's live status into ConfigStore (for the Settings pane)
    /// and (re)start/stop it whenever the relevant config changes.
    private func wireMCPServer() {
        Task {
            await mcpController.setStatusHandler { [weak self] status in
                Task { @MainActor in self?.configStore.mcpServerStatus = MCPServerStatus(status) }
            }
        }
        let cs = configStore
        let triggers: [AnyPublisher<Void, Never>] = [
            cs.$mcpEnabled.map { _ in () }.eraseToAnyPublisher(),
            cs.$mcpHostPort.map { _ in () }.eraseToAnyPublisher(),
            cs.$mcpRequireAuth.map { _ in () }.eraseToAnyPublisher(),
            cs.$mcpAuthToken.map { _ in () }.eraseToAnyPublisher(),
            cs.$mcpDisabledTools.map { _ in () }.eraseToAnyPublisher(),
            cs.$sonarr.map { _ in () }.eraseToAnyPublisher(),
            cs.$radarr.map { _ in () }.eraseToAnyPublisher(),
            cs.$lidarr.map { _ in () }.eraseToAnyPublisher(),
            cs.$whisparr.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in self?.applyMCPConfig() }
            .store(in: &cancellables)
        applyMCPConfig()
    }

    private func applyMCPConfig() {
        let cs = configStore
        guard cs.mcpEnabled else { Task { await mcpController.stop() }; return }
        let inputs = MCPServerController.BackendInputs(
            sonarr: cs.sonarr, radarr: cs.radarr, lidarr: cs.lidarr, whisparr: cs.whisparr,
            aiKnowsAboutWhisparr: cs.aiKnowsAboutWhisparr, tmdbApiKey: cs.tmdbApiKey,
            downloadClients: DownloadClientConfigs(
                qbittorrent: cs.qbittorrent, transmission: cs.transmission, nzbget: cs.nzbget,
                sabnzbd: cs.sabnzbd, rtorrent: cs.rtorrent, deluge: cs.deluge))
        let config = MCPServerController.Config(
            hostPort: cs.mcpHostPort, requireAuth: cs.mcpRequireAuth, token: cs.mcpAuthToken,
            disabledTools: cs.mcpDisabledTools, backendInputs: inputs)
        Task { await mcpController.restart(with: config) }
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
        // System-Settings-style sidebar layout: the window needs to be
        // resizable so the NavigationSplitView behaves (a fixed-size split
        // view fights its column constraints and can't reveal the sidebar
        // toggle). Traffic-light cluster fully enabled, like native Settings.
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        win.setContentSize(NSSize(width: 780, height: 540))
        win.contentMinSize = NSSize(width: 700, height: 470)
        win.isReleasedWhenClosed = false
        // The Settings UI is a hand-built two-column layout (a custom vibrant
        // sidebar + a detail column). fullSizeContentView + a transparent
        // titlebar let that content fill the whole window, so the sidebar
        // material reaches the top-left with the traffic-lights floating on it
        // (System Settings look). Title text hidden — the section name shows in
        // the detail column's own top bar.
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.title = ""
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

    // MARK: - Detached window (Dock-icon mode)

    /// The real, titlebar'd window shown in detached mode. Hosts the same
    /// `PopoverContentView` as the menu-bar panel, on the same shared models.
    private var mainWindow: NSWindow?

    /// Set the activation policy *before* the first window appears so the app
    /// doesn't visibly flip from accessory to Dock on launch. The window itself
    /// is created later in `applicationDidFinishLaunching` once the UI is up.
    func applicationWillFinishLaunching(_ notification: Notification) {
        if configStore.detachedWindow {
            NSApp.setActivationPolicy(.regular)
        }
    }

    /// Pure function of the `detachedWindow` preference: pick the activation
    /// policy and show/hide the real window. The menu-bar icon is toggled
    /// independently in SwiftUI via `MenuBarExtra(isInserted:)` bound to the
    /// same flag, so the two surfaces are never visible at once.
    private func applyWindowMode(_ detached: Bool) {
        if detached {
            NSApp.setActivationPolicy(.regular)
            openMainWindow()
        } else {
            mainWindow?.close()   // willClose handler nils the reference
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Show (or re-show) the detached window. Idempotent: an existing window is
    /// just brought to front.
    func openMainWindow() {
        if let win = mainWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // PopoverContentView draws on a clear background — in the menu-bar
        // panel the system supplies the vibrant glass behind it. The detached
        // window must supply that backdrop itself, otherwise the clear content
        // sits on a flat opaque window. A behind-window `NSVisualEffectView`
        // gives the same material the popover uses (rendered as Liquid Glass on
        // macOS 26), so the two surfaces look identical.
        let view = PopoverContentView(
            viewModel: queueVM,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onShowAbout: { [weak self] in self?.showAbout() },
            onQuit: { NSApp.terminate(nil) }
        )
        .environmentObject(configStore)
        .background(WindowGlassBackground().ignoresSafeArea())
        // This window is a hand-built NSWindow where NavigationStack's automatic
        // `< Back` chevron does not render (only the MenuBarExtra scene gets it
        // for free). Flag the content so DetailView draws its own in-content back
        // button here, while the menu-bar panel keeps the native chevron.
        .environment(\.isDetachedWindow, true)
        // NOTE: we intentionally leave `hosting.sceneBridgingOptions` at its
        // default ([]). Bridging would push SwiftUI's `.navigationTitle` and
        // `.toolbar` items into the titlebar — but the NavigationStack automatic
        // `< Back` chevron never bridges to a hand-built NSWindow anyway
        // (verified empirically), and bridging the rest only duplicated the
        // title + surfaced toolbar buttons we don't want up there. DetailView
        // draws its own back button + title in-content instead (`.isDetachedWindow`).
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "ArrBarr"
        // Fixed 400×600 (PopoverContentView is a hard-sized, internally-scrolling
        // layout — no `.resizable`, which would only add empty gutters).
        // `.fullSizeContentView` + transparent titlebar lets the glass backdrop
        // fill the whole window including under the (now SwiftUI-owned) titlebar.
        win.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        win.setContentSize(NSSize(width: 400, height: 600))
        win.isOpaque = false
        win.backgroundColor = .clear
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.center()

        // Red close button must not tear down the app — it returns to the Dock
        // icon. We drop our reference so the next Dock click (or toggle) rebuilds
        // a fresh window; `applicationShouldTerminateAfterLastWindowClosed`
        // keeps the process alive.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mainWindow = nil }
        }

        mainWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the last window (the detached main window, or Settings/About in
    /// accessory mode) never quits ArrBarr — it lives in the menu bar or Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon after the window was closed reopens it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if configStore.detachedWindow && mainWindow == nil {
            openMainWindow()
        }
        return true
    }
}

/// Behind-window vibrant material for the detached window, matching the
/// menu-bar popover's backdrop. `.popover` keeps the two surfaces visually
/// identical; on macOS 26 the system renders it as Liquid Glass.
private struct WindowGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
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

private extension MCPServerStatus {
    /// Bridge the server controller's status (ArrMCPServer) into ArrCore's
    /// display enum — identical shapes, different modules.
    init(_ s: MCPServerController.Status) {
        switch s {
        case .stopped: self = .stopped
        case .running(let url): self = .running(url: url)
        case .failed(let message): self = .failed(message: message)
        }
    }
}
