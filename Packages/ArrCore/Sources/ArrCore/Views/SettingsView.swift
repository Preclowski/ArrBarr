import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public struct SettingsView: View {
    var onShowWelcome: (() -> Void)? = nil
    var onTestNotification: (() -> Void)? = nil
    var onSetDemoMode: ((Bool) -> Bool)? = nil

    public init(
        onShowWelcome: (() -> Void)? = nil,
        onTestNotification: (() -> Void)? = nil,
        onSetDemoMode: ((Bool) -> Bool)? = nil
    ) {
        self.onShowWelcome = onShowWelcome
        self.onTestNotification = onTestNotification
        self.onSetDemoMode = onSetDemoMode
    }

    @Environment(ConfigStore.self) var configStore
    /// `@Bindable` because the queue state is `@Observable`, not a `$`-projected store.
    @Bindable var queueUI = QueueUIState.shared
    var storeManager: StoreManager { .shared }
    @State var demoModeOn: Bool = DemoMode.isActive
    @State var telemetryReport: String?
    /// iOS: 7 taps on the Version row enable Developer mode (no launch args there).
    @State var versionTapCount: Int = 0
    @State var devModeRevealed: Bool = DeveloperMode.isActive
    /// App language when Settings opened; drives the "restart required" footer.
    @State private var initialAppLanguage: String?
    @State var artworkBytes: Int64?
    @State var isClearingArtwork = false
    @State var dataCacheBytes: Int64?
    @State var isClearingDataCache = false
    #if os(macOS)
    @State var macSelection: SettingsSection = .general
    @State var macSearch: String = ""
    /// `isNavigatingHistory` suppresses recording when back/forward caused the change.
    @State var history: [SettingsSection] = [.general]
    @State var historyIndex: Int = 0
    @State var isNavigatingHistory: Bool = false

    /// Media Managers and Download clients are hub rows; `.service(kind)` is reached
    /// from a hub card via history, not from the sidebar.
    enum SettingsSection: Hashable {
        case general
        case status
        case mediaManagers
        case downloadClients
        case service(ServiceKind)
        /// Prowlarr has no `ServiceKind` (it is not a queue source).
        case prowlarr
        case mediaServer
        case assistant
        case quiz
        case mcp
        case icloud
        case siri
        case about
    }
    #endif

    var languageChanged: Bool {
        guard let initial = initialAppLanguage else { return false }
        return initial != configStore.appLanguage
    }

    public var body: some View {
        Group {
            #if os(macOS)
            macSidebarLayout
            #else
            // iOS: one grouped Form; a TabView fights the bottom tab bar.
            iOSCombinedForm
            #endif
        }
        .environment(\.locale, configStore.currentLocale)
        // Settings has its own window/tab, so it does not inherit the popover's `\.fontScale`.
        .appFontScale(configStore)
        .preferredColorScheme(configStore.preferredColorScheme)
        .onAppear {
            if initialAppLanguage == nil { initialAppLanguage = configStore.appLanguage }
        }
        .task { refreshArtworkBytes(); refreshDataCacheBytes() }
        // Paywall is presented by iOSAppRoot (sheet) / AppDelegate (NSWindow) observing `gatedFeature`.
    }

    /// Text-size presets (1.0 / 1.10 / 1.20), read via the `\.fontScale` env.
    @ViewBuilder
    var textSizePicker: some View {
        // `as Double` on every tag: SwiftUI infers some literals as Int and the
        // selection then silently never matches.
        Picker(selection: Bindable(configStore).fontScale) {
            Text("settings.default.button", bundle: .module).tag(1.0 as Double)
            Text("settings.larger.button", bundle: .module).tag(1.10 as Double)
            Text("settings.largest.button", bundle: .module).tag(1.20 as Double)
        } label: { Text("settings.textSize.button", bundle: .module) }
    }

    @ViewBuilder
    var themePicker: some View {
        Picker(selection: Bindable(configStore).appearance) {
            Text("settings.system.button", bundle: .module).tag("system")
            Text("settings.light.button", bundle: .module).tag("light")
            Text("settings.dark.button", bundle: .module).tag("dark")
        } label: { Text("settings.theme.button", bundle: .module) }
    }

    /// `v3.2.1-abc1234`; the suffix is absent when the build wasn't given `ARRBARR_GIT_SHA`.
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = "v" + (info?["CFBundleShortVersionString"] as? String ?? "?")
        guard let sha = info?["ArrBarrGitCommit"] as? String, !sha.isEmpty else { return version }
        return version + "-" + sha
    }
}
