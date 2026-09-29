import AppIntents
import ArrCore

/// Compiled into both app targets: the App Intents metadata processor only discovers a provider in the app itself.
/// `\(.applicationName)` is required in zero-config phrases; their translations live in `AppShortcuts.xcstrings`.
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
