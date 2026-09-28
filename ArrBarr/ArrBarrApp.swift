import SwiftUI
import ArrCore
import AppIntents

@main
struct ArrBarrApp: App {
    // Before every other stored property, so the flag is set before `ConfigStore.shared`
    // picks its secret store. `#if APPSTORE` is live here, unlike inside ArrCore.
    #if APPSTORE
    private let _capabilities: Void = { AppCapabilities.configure(isAppStore: true) }()
    #endif

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var queueVM = QueueViewModel.shared
    @ObservedObject private var configStore = ConfigStore.shared

    init() {
        // Before the first localized lookup, so model-layer strings match the UI language.
        ConfigStore.applyAppLanguageToProcess()
        #if APPSTORE
        StoreManager.shared.use(StoreKitBackend())
        KVSyncCoordinator.startShared()
        #endif
    }

    var body: some Scene {
        // `style: .window` gives SwiftUI a real window context, so NavigationStack renders native chrome.
        // Read-only `isInserted` setter: the Settings toggle owns visibility, not ⌘-drag.
        MenuBarExtra(isInserted: Binding(
            get: { !configStore.detachedWindow },
            set: { _ in }
        )) {
            PopoverContentView(
                viewModel: queueVM,
                onOpenSettings: { appDelegate.openSettings() },
                onShowAbout: { appDelegate.showAbout() },
                onQuit: { NSApp.terminate(nil) }
            )
            .environmentObject(configStore)
        } label: {
            // A custom (non-symbol) image inside a `Label` suppresses the title in the status item.
            let active = queueVM.activeCount
            HStack(spacing: 2) {
                Image("MenuBarGlyph").renderingMode(.template)
                if active > 0 {
                    Text("\(active)")
                }
            }
        }
        .menuBarExtraStyle(.window)

        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) { }
                CommandGroup(replacing: .appInfo) {
                    Button {
                        appDelegate.showAbout()
                    } label: {
                        Text("About ArrBarr", bundle: .arrCore)
                    }
                }
            }
    }
}

/// `\(.applicationName)` is required in zero-config phrases. Lives in the app target
/// so the App Intents metadata processor discovers it.
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
