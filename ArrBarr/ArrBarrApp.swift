import SwiftUI
import ArrCore
import AppIntents

@main
struct ArrBarrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Observe shared models so the menu-bar icon label rebuilds when the
    // active count changes. The AppDelegate uses the same `.shared`
    // instances for badge updates / notifications.
    @State private var queueVM = QueueViewModel.shared
    @ObservedObject private var configStore = ConfigStore.shared

    init() {
        // Paywall is App Store-only. In every other build (Debug, GitHub/OSS
        // Release) no backend is injected, so StoreManager stays unlocked and
        // no StoreKit code is compiled in.
        #if APPSTORE
        StoreManager.shared.use(StoreKitBackend())
        #endif
    }

    var body: some Scene {
        // ArrBarr's menu-bar surface. `style: .window` opens a small
        // detached panel under the icon (Apple Wallet / Music mini-player
        // pattern) instead of NSPopover's arrow-anchored balloon. The
        // window backing gives SwiftUI a proper window context, so
        // NavigationStack drill-downs render native `< title` chrome
        // automatically — which was the whole reason we migrated off
        // NSPopover.
        MenuBarExtra {
            PopoverContentView(
                viewModel: queueVM,
                onOpenSettings: { appDelegate.openSettings() },
                onShowAbout: { appDelegate.showAbout() },
                onQuit: { NSApp.terminate(nil) }
            )
            .environmentObject(configStore)
        } label: {
            // Custom pirate-popcorn glyph (template image, auto-tinted by the
            // menu bar). Compose glyph + active count in an HStack: a custom
            // (non-symbol) image inside a `Label` suppresses the title in the
            // status item, so build the row explicitly instead.
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
            }
    }
}

/// Ready-made Siri / Shortcuts / Spotlight phrases. `\(.applicationName)` is
/// required by Apple in zero-config phrases. Lives in the app target so the
/// App Intents metadata processor discovers it.
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
