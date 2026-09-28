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
    var settingsWindow: NSWindow?
    var aboutWindow: NSWindow?
    #if DEBUG
    var shelfDebugWindow: NSWindow?
    #endif
    var welcomeWindow: NSWindow?
    var paywallWindow: NSWindow?
    /// Mixed drops queue as more than one batch — see `enqueueDrops`.
    var addDownloadWindow: NSWindow?
    var pendingDropBatches: [[DownloadDrop]] = []
    private let statusItemDropTarget = StatusItemDropTarget()
    var statusItemRightClickMonitor: Any?
    let configStore = ConfigStore.shared
    let queueVM = QueueViewModel.shared
    lazy var mcpController = MCPServerController()
    var cancellables = Set<AnyCancellable>()
    private var dropMessages: Task<Void, Never>?

    /// Held for the process lifetime: an accessory app with no visible window is App Nap's prime target,
    /// which stretches the 30 s poll to minutes. Still lets the Mac sleep.
    private var antiAppNap: (any NSObjectProtocol)?

    /// Must run before the first `Logger` is created, hence `mcpController` is lazy.
    private static let bootstrapLogging: Void = {
        LoggingSystem.bootstrap { OSLogForwardingHandler(label: $0) }
    }()

    /// Launched at login and never watched while it starts, so lifecycle is only answerable from the log.
    nonisolated static let log = Logger(category: "Lifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerNotificationCategories()
        UNUserNotificationCenter.current().delegate = self

        antiAppNap = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Keep arr queue polling and download notifications timely"
        )

        DemoMode.seedConfigsIfNeeded(configStore)

        #if DEBUG
        if let spec = UserDefaults.standard.string(forKey: "ShelfDebug") {
            let win = NSWindow(contentViewController: NSHostingController(rootView: ShelfDebugView(spec: spec).environmentObject(configStore)))
            win.title = "ShelfDebug"
            win.styleMask = [.titled]
            win.setFrameTopLeftPoint(NSPoint(x: 60, y: 900))
            win.makeKeyAndOrderFront(nil)
            shelfDebugWindow = win
        }
        #endif

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
