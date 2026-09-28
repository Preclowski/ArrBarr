import SwiftUI
import ArrCore
import AppIntents
import UserNotifications
import WidgetKit

/// The Info.plist must advertise landscape for rotation to work at all, so the portrait lock lives here;
/// a playing trailer (`TrailerSession`) is the one exception.
final class OrientationGate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        TrailerSession.allowsLandscape ? [.portrait, .landscapeLeft, .landscapeRight] : .portrait
    }
}

@main
struct ArrBarriOSApp: App {
    @UIApplicationDelegateAdaptor(OrientationGate.self) private var orientationGate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before the first localized lookup, so model-layer `String(localized:)` matches the in-app language.
        ConfigStore.applyAppLanguageToProcess()
        #if APPSTORE
        AppCapabilities.configure(isAppStore: true)
        #endif
        // iOS has no AppDelegate, so notifications are wired here.
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
                .task { await AppCaches.purgeExpired() }
                // Launch with ARRBARR_DEMO_SUITE=1 to enter demo mode (iOS can't relaunch itself).
                .task {
                    if ProcessInfo.processInfo.environment["ARRBARR_DEMO_SUITE"] == "1",
                       !DemoMode.isActive {
                        UserDefaults.standard.set(true, forKey: DemoMode.key)
                        ConfigStore.shared.useDemoStore(true)
                        DemoMode.seedConfigsIfNeeded(ConfigStore.shared)
                    }
                    // `useDemoStore` covers live toggles, not booting into a persisted demo state.
                    WidgetDataStore.setDemoActive(DemoMode.isActive)
                    WidgetCenter.shared.reloadAllTimelines()
                }
                .onOpenURL { url in
                    switch WidgetDeepLink(url: url) {
                    case .library:
                        break
                    case nil:
                        break
                    }
                }
        }
        // Nudge WidgetKit so config or demo changes show on the home screen.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}

/// `\(.applicationName)` is required in zero-config phrases; lives in the app target for App Intents discovery.
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
