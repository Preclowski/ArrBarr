import AppKit
import SwiftUI
import Combine
import UserNotifications
import CoreSpotlight
import ArrCore
import ArrMCPServer
import Logging
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var paywallWindow: NSWindow?
    /// Mixed drops queue as more than one batch — see `enqueueDrops`.
    private var addDownloadWindow: NSWindow?
    private var pendingDropBatches: [[DownloadDrop]] = []
    private let statusItemDropTarget = StatusItemDropTarget()
    private var statusItemRightClickMonitor: Any?
    private let configStore = ConfigStore.shared
    private let queueVM = QueueViewModel.shared
    private lazy var mcpController = MCPServerController()
    private var cancellables = Set<AnyCancellable>()
    private var dropMessages: Task<Void, Never>?

    /// Held for the process lifetime: an accessory app with no visible window is App Nap's prime target,
    /// which stretches the 30 s poll to minutes. Still lets the Mac sleep.
    private var antiAppNap: (any NSObjectProtocol)?

    /// Must run before the first `Logger` is created, hence `mcpController` is lazy.
    private static let bootstrapLogging: Void = {
        LoggingSystem.bootstrap { OSLogForwardingHandler(label: $0) }
    }()

    /// Launched at login and never watched while it starts, so lifecycle is only answerable from the log.
    nonisolated private static let log = Logger(category: "Lifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerNotificationCategories()
        UNUserNotificationCenter.current().delegate = self

        antiAppNap = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Keep arr queue polling and download notifications timely"
        )

        DemoMode.seedConfigsIfNeeded(configStore)

        // `.preferredColorScheme` doesn't reach the menu-bar popover or the hosted windows; `NSApp.appearance` does.
        applyAppearance(configStore.appearance)
        configStore.$appearance
            .sink { [weak self] in self?.applyAppearance($0) }
            .store(in: &cancellables)

        // The sink fires once on subscribe with the current value, then on every toggle.
        configStore.$detachedWindow
            .removeDuplicates()
            .sink { [weak self] in self?.applyWindowMode($0) }
            .store(in: &cancellables)

        // Hosted in a real NSWindow: the MenuBarExtra panel auto-dismisses when StoreKit's purchase UI takes focus.
        StoreManager.shared.$gatedFeature
            .receive(on: RunLoop.main)
            .sink { [weak self] feature in
                if feature != nil { self?.showPaywall() } else { self?.closePaywall() }
            }
            .store(in: &cancellables)

        // The SwiftUI side can't reach the window plumbing, so drops arrive as a message.
        dropMessages = Task { [weak self] in
            for await message in NotificationCenter.default.messages(of: nil as AppMessageBus?, for: AppMessages.DropDownloads.self) {
                self?.enqueueDrops(message.urls.compactMap(DownloadDrop.init(url:)))
            }
        }

        // Installed on a delay because SwiftUI creates the status item after this callback returns.
        statusItemDropTarget.install()
        installStatusItemRightClickMenu()

        _ = Self.bootstrapLogging
        wireMCPServer()

        showWelcomeIfNeeded()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        Task.detached { await AppCaches.purgeExpired() }

        // `--clear-intents` wipes ArrBarr's Spotlight entries and skips reindexing.
        if CommandLine.arguments.contains("--clear-intents") {
            Task { @MainActor in
                await SpotlightIndexer.clearIndex()
                NSLog("ArrBarr: cleared Spotlight intents index (--clear-intents)")
            }
        } else {
            SpotlightIndexer.reindex(configStore: configStore)
        }

        LibraryPosterSampler.warmUp(configStore: configStore)

        // WebSockets don't reliably survive sleep and the OS can take 30-90 s to surface the dead socket,
        // so force a reconnect right after wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Self.log.notice("system woke — forcing realtime reconnect")
            Task { @MainActor in self?.queueVM.systemDidWake() }
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let mode = configStore.detachedWindow ? "window" : "menu bar"
        Self.log.notice(
            "launched \(version, privacy: .public) in \(mode, privacy: .public) mode\(DemoMode.isActive ? " (demo)" : "", privacy: .public)"
        )
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

    // MARK: - MCP server

    private func wireMCPServer() {
        Task {
            await mcpController.setStatusHandler { [weak self] status in
                Task { @MainActor in MCPServerStatusModel.shared.status = MCPServerStatus(status) }
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
        if cs.mcpRequireAuth && cs.mcpAuthToken.isEmpty {
            // Mint a token rather than start a server whose auth can never pass (the validator fails closed on empty).
            cs.mcpAuthToken = MCPTokenStore.generate()
            return
        }
        let inputs = MCPServerController.BackendInputs(
            sonarr: cs.sonarr, radarr: cs.radarr, lidarr: cs.lidarr, whisparr: cs.whisparr,
            aiKnowsAboutWhisparr: cs.aiKnowsAboutWhisparr, tmdbApiKey: cs.tmdbApiKey,
            downloadClients: DownloadClientConfigs(
                qbittorrent: cs.qbittorrent, transmission: cs.transmission, nzbget: cs.nzbget,
                sabnzbd: cs.sabnzbd, rtorrent: cs.rtorrent, deluge: cs.deluge),
            mediaServer: cs.mediaServer)
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

    /// Picks up posters cached while browsing. Throttled inside `reindex`.
    func applicationDidBecomeActive(_ notification: Notification) {
        SpotlightIndexer.reindex(configStore: configStore)
    }

    /// Opens the title's detail in ArrBarr, or the arr's web UI when `spotlightOpensInApp` is off.
    func application(_ application: NSApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
            return false
        }
        // Also falls through when the identifier is unparseable (a stale entry from an older id format).
        guard configStore.spotlightOpensInApp, let ref = SpotlightIndexer.parse(id) else {
            Self.log.notice(
                "spotlight hit → browser (opensInApp=\(self.configStore.spotlightOpensInApp, privacy: .public), parsed=\(SpotlightIndexer.parse(id) != nil, privacy: .public))"
            )
            Task { @MainActor in
                if let url = await SpotlightIndexer.browserURL(forIdentifier: id, configStore: configStore) {
                    NSWorkspace.shared.open(url)
                }
            }
            return true
        }
        Self.log.notice(
            "spotlight hit → \(ref.source.rawValue, privacy: .public) \(ref.id, privacy: .public) in app"
        )
        openSpotlightDetail(source: ref.source, entityId: ref.id)
        return true
    }

    /// The MenuBarExtra panel can't be opened programmatically, so this uses the detached window. A freshly
    /// built window needs a beat for `PopoverContentView`'s listener to mount before the post lands.
    private func openSpotlightDetail(source: QueueItem.Source, entityId: Int) {
        let wasOpen = mainWindow != nil
        openMainWindow()
        Task { @MainActor in
            if !wasOpen { try? await Task.sleep(nanoseconds: 450_000_000) }
            DetailRequest.post(DetailRequest.syntheticItem(source: source, entityId: entityId, title: ""))
        }
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
        .appFontScale(configStore)
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

    // MARK: - Dropped / opened downloads

    /// Dock drop, Finder "Open With" and `magnet:` links all land here. Undownloadable items are ignored,
    /// not refused: a drag may carry a stray file alongside the torrents.
    func application(_ application: NSApplication, open urls: [URL]) {
        enqueueDrops(urls.compactMap(DownloadDrop.init(url:)))
    }

    /// Torrent and usenet go in separate batches: a `.nzb` and a `.torrent` reach different clients even within one arr,
    /// so one "which arr?" answer can't cover both. The second batch opens when the first window closes.
    func enqueueDrops(_ drops: [DownloadDrop]) {
        guard !drops.isEmpty else { return }
        for kind in DownloadKind.allCases {
            let batch = drops.filter { $0.kind == kind }
            if !batch.isEmpty { pendingDropBatches.append(batch) }
        }
        showNextDropBatch()
    }

    private func showNextDropBatch() {
        guard !pendingDropBatches.isEmpty else { return }
        // One window at a time. Surface the open one, or a second drop looks lost.
        if let existing = addDownloadWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let batch = pendingDropBatches.removeFirst()

        let view = AddDownloadView(drops: batch) { [weak self] in
            self?.addDownloadWindow?.close()
        }
        .environmentObject(configStore)
        // Standalone scene: without the injected font-scale preset every scaledFont renders at 1.0.
        .appFontScale(configStore)

        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = String(localized: "Add download", bundle: .arrCore)
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        // Size before centring: `NSHostingController` reports zero size until layout, and centring a zero frame
        // can park the window off-screen, where it looks like a hang.
        win.setContentSize(hosting.view.fittingSize == .zero ? NSSize(width: 420, height: 260) : hosting.view.fittingSize)
        win.center()
        if let screen = NSScreen.main, !screen.visibleFrame.intersects(win.frame) {
            win.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - win.frame.width / 2,
                y: screen.visibleFrame.midY - win.frame.height / 2
            ))
        }
        // An accessory app doesn't activate on Dock drop, so the window would open behind the user's app.
        win.level = .floating
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.addDownloadWindow = nil
                self?.showNextDropBatch()
            }
        }
        addDownloadWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Status-item right-click menu

    /// `MenuBarExtra(.window)` has no right-click affordance, so a local monitor sniffs the status item's window class;
    /// failure degrades to right-click opening the panel.
    private func installStatusItemRightClickMenu() {
        statusItemRightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self,
                  let window = event.window,
                  String(describing: type(of: window)).contains("StatusBar"),
                  let contentView = window.contentView
            else { return event }
            NSMenu.popUpContextMenu(self.statusItemContextMenu(), with: event, for: contentView)
            return nil
        }
    }

    private func statusItemContextMenu() -> NSMenu {
        let bundle = Bundle.arrCore
        let menu = NSMenu()
        let settings = NSMenuItem(
            title: String(localized: "common.settings2.button", bundle: bundle),
            action: #selector(statusMenuOpenSettings), keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(
            title: String(localized: "settings.aboutArrbarr.button", bundle: bundle),
            action: #selector(statusMenuShowAbout), keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: String(localized: "common.quitArrbarr.button", bundle: bundle),
            action: #selector(statusMenuQuit), keyEquivalent: ""
        )
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func statusMenuOpenSettings() { openSettings() }
    @objc private func statusMenuShowAbout() { showAbout() }
    @objc private func statusMenuQuit() { NSApp.terminate(nil) }

    // MARK: - About

    /// Hosted in a real `NSWindow` so it survives the menu-bar panel closing on focus loss.
    func showAbout() {
        if let win = aboutWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: AboutView().environmentObject(configStore))
        let win = NSWindow(contentViewController: hosting)
        win.title = String(localized: "settings.about.button", bundle: .arrCore)
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false
        win.center()

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.aboutWindow = nil }
        }

        aboutWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        // Resizable, or the NavigationSplitView fights its column constraints and can't reveal the sidebar toggle.
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        win.setContentSize(NSSize(width: 780, height: 540))
        win.contentMinSize = NSSize(width: 700, height: 470)
        win.isReleasedWhenClosed = false
        // Full-size content + transparent titlebar so the custom sidebar material reaches the top-left under the traffic lights.
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
        // Pre-welcome builds already configured services: mark them caught up so the next major-update welcome still fires.
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
        // A demo-seeded user has `enabled = true` but no `baseURL`.
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
                self?.openSettings()
            },
            onTryDemo: { [weak self] in self?.enableDeveloperModeAndRelaunch() },
            onFinish: { [weak self] in
                self?.welcomeWindow?.performClose(nil)
            }
        ).environmentObject(configStore)
        .appFontScale(configStore)

        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = String(localized: "Welcome to ArrBarr", bundle: .arrCore)
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.standardWindowButton(.closeButton)?.isHidden = true
        // Must match WelcomeView's `.frame(width:height:)`, or NSWindow background shows around the content.
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
        // Only flips developer mode, like `--demo`; both flags are read once at process start, so relaunch.
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
        configStore.useDemoStore(enabled)
        if !enabled {
            // Only the demo suite — the real profile in `.standard` is never touched.
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

    private var mainWindow: NSWindow?

    /// Set before the first window appears so the app doesn't visibly flip from accessory to Dock on launch.
    func applicationWillFinishLaunching(_ notification: Notification) {
        if configStore.detachedWindow {
            NSApp.setActivationPolicy(.regular)
        }
    }

    /// The menu-bar icon is toggled separately via `MenuBarExtra(isInserted:)` on the same flag.
    private func applyWindowMode(_ detached: Bool) {
        if detached {
            NSApp.setActivationPolicy(.regular)
            openMainWindow()
        } else {
            mainWindow?.close()
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func openMainWindow() {
        if let win = mainWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // PopoverContentView draws on clear; the menu-bar panel supplies the glass, so this window must supply its own.
        let view = PopoverContentView(
            viewModel: queueVM,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onShowAbout: { [weak self] in self?.showAbout() },
            onQuit: { NSApp.terminate(nil) },
            onCloseWindow: { [weak self] in self?.mainWindow?.close() }
        )
        .environmentObject(configStore)
        .background(WindowGlassBackground().ignoresSafeArea())
        // NavigationStack's back chevron doesn't render in a hand-built NSWindow; DetailView draws its own here.
        .environment(\.isDetachedWindow, true)
        // `sceneBridgingOptions` stays []: the back chevron never bridges to a hand-built NSWindow anyway,
        // and bridging the rest only duplicated the title and toolbar buttons.
        let hosting = NSHostingController(rootView: view)
        // No titlebar inset: the tab bar shares the traffic lights' row; PopoverContentView insets the leading edge.
        if #available(macOS 13.3, *) { hosting.safeAreaRegions = [] }
        let win = NSWindow(contentViewController: hosting)
        // A non-empty title can still paint over the content header with a hidden titlebar.
        win.title = ""
        // Fixed size: PopoverContentView is hard-sized. `.titled` + `.closable` stay so text fields can focus
        // and Cmd-W works, though the system buttons are hidden.
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.setContentSize(NSSize(width: 400, height: 600))
        win.isOpaque = false
        win.backgroundColor = .clear
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.center()

        // Closing must not quit the app; drop the reference so the next Dock click rebuilds the window.
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if configStore.detachedWindow && mainWindow == nil {
            openMainWindow()
        }
        return true
    }
}

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

private extension MCPServerStatus {
    init(_ s: MCPServerController.Status) {
        switch s {
        case .stopped: self = .stopped
        case .running(let url): self = .running(url: url)
        case .failed(let message): self = .failed(message: message)
        }
    }
}
