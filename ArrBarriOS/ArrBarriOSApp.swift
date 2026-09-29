import SwiftUI
import ArrCore
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
                        await DemoMode.switchLive(true)
                    }
                    // `useDemoStore` covers live toggles, not booting into a persisted demo state.
                    WidgetDataStore.setDemoActive(DemoMode.isActive)
                    WidgetCenter.shared.reloadAllTimelines()
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
