import SwiftUI
import ArrCore
import AppIntents
import UserNotifications
import WidgetKit

@main
struct ArrBarriOSApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Apply the chosen in-app language to the process before the first
        // localized lookup, so model-layer String(localized:) (download statuses,
        // notifications, history) matches the UI instead of the system language.
        ConfigStore.applyAppLanguageToProcess()
        #if APPSTORE
        AppCapabilities.configure(isAppStore: true)
        #endif
        // iOS has no AppDelegate, so wire notifications here: a delegate that
        // shows in-foreground banners + handles Pause/Resume/Remove/Open
        // action taps, the action categories, and authorization.
        UNUserNotificationCenter.current().delegate = ArrNotificationDelegate.shared
        NotificationActions.register()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Paywall is App Store-only; no backend injected elsewhere → unlocked.
        #if APPSTORE
        StoreManager.shared.use(StoreKitBackend())
        KVSyncCoordinator.startShared()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            iOSAppRoot()
                // Drop poster/portrait files unused for 30+ days — the disk
                // cache lives in Caches/ (OS-purgeable) so it never fills the
                // disk, but this trims the long tail. macOS does the same in
                // its AppDelegate.
                .task { await PosterStore.shared.purge() }
                // QA / screenshot hook: launch with env ARRBARR_DEMO_SUITE=1 to
                // enter demo mode without the Settings toggle (iOS can't relaunch
                // itself). Mirrors the in-app toggle exactly — persist the flag,
                // repoint ConfigStore to the demo suite, seed configs.
                .task {
                    if ProcessInfo.processInfo.environment["ARRBARR_DEMO_SUITE"] == "1",
                       !DemoMode.isActive {
                        UserDefaults.standard.set(true, forKey: DemoMode.key)
                        ConfigStore.shared.useDemoStore(true)
                        DemoMode.seedConfigsIfNeeded(ConfigStore.shared)
                    }
                    // Keep the widget's demo mirror in sync on every launch —
                    // `useDemoStore` covers live toggles, but booting straight
                    // into a persisted demo state must also update the mirror.
                    WidgetDataStore.setDemoActive(DemoMode.isActive)
                    WidgetCenter.shared.reloadAllTimelines()
                }
                // Widget deep links (arrbarr://). Phase 1 only emits
                // `.library`, which simply foregrounds the app onto its
                // default view; later phases route to specific destinations.
                .onOpenURL { url in
                    switch WidgetDeepLink(url: url) {
                    case .library:
                        break
                    case nil:
                        break
                    }
                }
        }
        // When the app backgrounds, refresh widget timelines so any config or
        // demo-mode change the user just made is reflected on the home screen
        // (the group suite is already in sync; this just nudges WidgetKit).
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}

/// Ready-made Siri / Shortcuts / Spotlight phrases. Mirrors the macOS
/// provider. `\(.applicationName)` is required by Apple in zero-config
/// phrases. Lives in the app target for App Intents metadata discovery.
struct ArrBarrAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowDownloadQueueIntent(),
            phrases: [
                "What's downloading in \(.applicationName)",
                "Show \(.applicationName) downloads",
            ],
            shortTitle: "Download queue",
            systemImageName: "arrow.down.circle"
        )
        AppShortcut(
            intent: ShowUpcomingIntent(),
            phrases: [
                "What's coming up in \(.applicationName)",
                "What's up next in \(.applicationName)",
                "What's next in \(.applicationName)",
                "Show \(.applicationName) upcoming",
            ],
            shortTitle: "Upcoming",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: CheckArrHealthIntent(),
            phrases: [
                "Is \(.applicationName) healthy",
                "Check \(.applicationName) status",
            ],
            shortTitle: "Service health",
            systemImageName: "stethoscope"
        )
    }
}
