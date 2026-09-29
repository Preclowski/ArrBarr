import AppKit
import SwiftUI
import ArrCore

extension AppDelegate {
    // MARK: - Paywall

    /// Host the paywall in a real, focus-stable NSWindow. Presenting it inside
    /// the MenuBarExtra panel breaks: the panel resigns key (and self-closes)
    /// the moment StoreKit's purchase sheet appears, aborting the purchase.
    func showPaywall() {
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

    func closePaywall() {
        guard let win = paywallWindow else { return }
        paywallWindow = nil
        win.close()
    }

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
            onShowWelcome: { [weak self] in self?.openWelcome() },
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
        // Hidden, but still what VoiceOver and the Window menu call it.
        win.title = String(localized: "common.settings.button", bundle: .arrCore)
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

    func showWelcomeIfNeeded() {
        // Pre-welcome builds already configured services: mark them caught up so the next major-update welcome still fires.
        let isUpgradeFromPreWelcome = configStore.welcomeSeenVersion == nil
            && hasAnyConfiguredArr
        if isUpgradeFromPreWelcome && !WelcomeContent.shouldForceShow() {
            configStore.welcomeSeenVersion = WelcomeContent.currentVersion
            return
        }
        guard WelcomeContent.shouldShow(seen: configStore.welcomeSeenVersion) else { return }
        openWelcome()
    }

    private var hasAnyConfiguredArr: Bool {
        // A demo-seeded user has `enabled = true` but no `baseURL`.
        !configStore.radarr.baseURL.isEmpty
            || !configStore.sonarr.baseURL.isEmpty
            || !configStore.lidarr.baseURL.isEmpty
    }

    private func openWelcome() {
        if let win = welcomeWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = WelcomeView(
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
}
