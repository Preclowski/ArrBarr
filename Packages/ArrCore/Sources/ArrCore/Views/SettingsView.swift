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

    @EnvironmentObject var configStore: ConfigStore
    @ObservedObject private var storeManager = StoreManager.shared
    @State private var demoModeOn: Bool = DemoMode.isActive
    /// iOS: 7-tap on the Version row enables Developer mode, since iOS
    /// users can't pass `--demo` on launch.
    @State private var versionTapCount: Int = 0
    @State private var devModeRevealed: Bool = DeveloperMode.isActive
    /// The app language at the moment Settings opened. We compare against
    /// `configStore.appLanguage` to decide whether the "restart required"
    /// footer should appear — `nil` until the view first appears.
    @State private var initialAppLanguage: String?

    private var languageChanged: Bool {
        guard let initial = initialAppLanguage else { return false }
        return initial != configStore.appLanguage
    }

    public var body: some View {
        Group {
            #if os(macOS)
            VStack(spacing: 0) {
                TabView {
                    generalPane
                        .tabItem { Label { Text("General", bundle: .module) } icon: { Image(systemName: "gearshape") } }
                    mediaManagersPane
                        .tabItem { Label { Text("Media Managers", bundle: .module) } icon: { Image(systemName: "server.rack") } }
                    downloadClientsPane
                        .tabItem { Label { Text("Download clients", bundle: .module) } icon: { Image(systemName: "arrow.down.circle") } }
                    aiPane
                        .tabItem { Label { Text("Assistant", bundle: .module) } icon: { Image(systemName: "sparkles") } }
                }
                bottomBar
            }
            #else
            // iOS: a single Form with every section inline. The macOS
            // TabView paradigm fights with the bottom tab bar, and a
            // grouped scrolling list is the iOS-native way to present
            // settings anyway. The "About" section at the very end is
            // where macOS's bottom-bar version+link footer lives.
            iOSCombinedForm
            #endif
        }
        .environment(\.locale, configStore.currentLocale)
        // Settings is hosted in its own NSWindow on macOS and as a tab on
        // iOS — neither path inherits the popover's `\.fontScale` env, so
        // the Text-size picker had no effect on Settings itself (the most
        // visible place where the user *previews* the change). Inject the
        // env right here; observing configStore re-renders on every step.
        .appFontScale(configStore)
        .preferredColorScheme(configStore.preferredColorScheme)
        .onAppear {
            if initialAppLanguage == nil { initialAppLanguage = configStore.appLanguage }
        }
        // Paywall presentation is handled centrally (iOS: a sheet on
        // iOSAppRoot's TabView; macOS: a dedicated NSWindow opened by
        // AppDelegate observing StoreManager.gatedFeature). The Download
        // Clients lock here just calls `gate(...)`, which sets gatedFeature and
        // lets those owners present. `storeManager` is still observed for the
        // `.disabled`/overlay lock state.
    }

    /// Section content for the language picker. Shared between the macOS
    /// General pane and the iOS combined form so the "restart required"
    /// affordance behaves identically on both platforms.
    /// Text-size preset picker — three discrete steps (Default / Larger /
    /// Largest = 1.0 / 1.10 / 1.20). Affects every `.scaledFont(size:)`
    /// site in the app via the `\.fontScale` env value injected at root.
    @ViewBuilder
    private var textSizePicker: some View {
        // Explicit `as Double` on every tag — without it, SwiftUI
        // infers some literals as Int, the Picker selection never
        // matches, and the scale silently sticks at whatever it was
        // (no compile error, no runtime warning, just nothing changes).
        Picker(selection: $configStore.fontScale) {
            Text("Default", bundle: .module).tag(1.0 as Double)
            Text("Larger", bundle: .module).tag(1.10 as Double)
            Text("Largest", bundle: .module).tag(1.20 as Double)
        } label: { Text("Text size", bundle: .module) }
    }

    /// Light / Dark / System appearance preset. Applied via
    /// `.preferredColorScheme` at every scene root.
    @ViewBuilder
    private var themePicker: some View {
        Picker(selection: $configStore.appearance) {
            Text("System", bundle: .module).tag("system")
            Text("Light", bundle: .module).tag("light")
            Text("Dark", bundle: .module).tag("dark")
        } label: { Text("Theme", bundle: .module) }
    }

    /// Shared "AI" section. One master toggle at the top kills the whole
    /// feature; provider controls only appear when AI is on.
    @ViewBuilder
    private var aiSection: some View {
        Section {
            Toggle(isOn: $configStore.aiEnabled) { Text("Enable AI", bundle: .module) }
        } header: { Text("Assistant", bundle: .module) }
        if configStore.aiEnabled {
            Section {
                Picker(selection: $configStore.chatProvider) {
                    // Hide Apple Intelligence on devices that don't support it.
                    ForEach(ChatProvider.allCases.filter {
                        $0 != .foundationModels || FoundationModelsAvailability.isSupported
                    }) { p in
                        Text(p.displayName).tag(p)
                    }
                } label: { Text("AI provider", bundle: .module) }
                if configStore.chatProvider == .openai {
                    TextField(text: $configStore.openai.baseURL,
                              prompt: Text(verbatim: "https://api.openai.com/v1")) {
                        Text("API base URL", bundle: .module)
                    }
                    .urlField()
                    SecureField(text: $configStore.openai.apiKey) { Text("API key", bundle: .module) }
                        .apiKeyField()
                    // LabeledContent keeps the "Model" label visible next to
                    // the value — a bare Form TextField hides its label once
                    // it has a value, leaving just a cryptic "gpt-4o-mini".
                    LabeledContent {
                        // Empty title — the LabeledContent `label:` below is
                        // the visible "Model" label; giving the TextField its
                        // own label too rendered "Model … Model … value".
                        TextField("", text: $configStore.openai.model,
                                  prompt: Text(verbatim: "gpt-4o-mini"))
                        #if os(iOS)
                        .multilineTextAlignment(.trailing)
                        #endif
                        .technicalField()
                    } label: {
                        Text("Model", bundle: .module)
                    }
                    if !configStore.openai.isConfigured {
                        Label {
                            Text("Add base URL, API key and model — AI stays off until then.", bundle: .module)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    Text("The model must support tool calling, and results vary by model. Library items may be sent to the model to tailor recommendations. Tip: free models on OpenRouter work well.", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if configStore.chatProvider == .foundationModels {
                    #if os(macOS)
                    if #unavailable(macOS 26.0) {
                        Label { Text("Apple Intelligence requires macOS 26.", bundle: .module) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    #else
                    if #unavailable(iOS 26.0) {
                        Label { Text("Apple Intelligence requires iOS 26.", bundle: .module) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    #endif
                }
                if configStore.whisparr.isConfigured {
                    Toggle(isOn: $configStore.aiKnowsAboutWhisparr) { Text("AI knows about Whisparr", bundle: .module) }
                }
            }
            Section {
                SecureField(text: $configStore.tmdbApiKey,
                            prompt: Text(verbatim: "v3 read key")) {
                    Text("TMDB API key", bundle: .module)
                }
                .apiKeyField()
                if let url = URL(string: "https://www.themoviedb.org/settings/api") {
                    Link(destination: url) {
                        Label { Text("Get a free TMDB key", bundle: .module) } icon: { Image(systemName: "link") }
                            .font(.caption)
                    }
                }
            } header: {
                Text("Discovery", bundle: .module)
            } footer: {
                Text(configStore.tmdbEnabled
                     ? String(localized: "Chat can search by actor, genre, and decade.", bundle: .module)
                     : String(localized: "Add a TMDB key to let chat search by actor, genre, and decade.", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    #if os(macOS)
    private var aiPane: some View {
        Form {
            aiSection
        }
        .formStyle(.grouped)
    }
    #endif

    #if os(macOS)
    private func relaunchApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }
    #endif

    #if os(iOS)
    /// Root settings list — each row drills into its own sub-form, the
    /// iOS-native (Settings.app) pattern. Replaces the one long combined
    /// Form so each concern lives on its own screen.
    private var iOSCombinedForm: some View {
        List {
            iosSettingsLink("General", systemImage: "gearshape") { iosGeneralForm }
            iosSettingsLink("Media managers", systemImage: "server.rack") { iosMediaManagersForm }
            iosSettingsLink("Download clients", systemImage: "arrow.down.circle") { iosDownloadClientsForm }
            iosSettingsLink("Assistant", systemImage: "sparkles") { iosAIForm }
            iosSettingsLink("Siri & Shortcuts", systemImage: "mic.fill") { iosSiriForm }
            iosSettingsLink("About", systemImage: "info.circle") { iosAboutForm }
        }
    }

    @ViewBuilder
    private var iosSiriForm: some View {
        Form {
            if #available(iOS 16.0, *) {
                SiriShortcutsSettingsContent()
            }
        }
        .navigationTitle(Text("Siri & Shortcuts", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func iosSettingsLink<Destination: View>(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label { Text(titleKey, bundle: .module) } icon: { Image(systemName: systemImage) }
        }
    }

    /// One row in the Media-managers / Download-clients submenu: brand icon +
    /// name + a green check when configured, pushing a dedicated per-service
    /// screen. Replaces the old single long form (every service stacked) —
    /// each service now lives on its own screen one tap deep.
    private func iosServiceLink<Content: View>(
        kind: ServiceKind,
        title: String,
        configured: Bool,
        @ViewBuilder fields: @escaping () -> Content
    ) -> some View {
        NavigationLink {
            Form { Section { fields() } }
                .navigationTitle(Text(verbatim: title))
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            HStack(spacing: 10) {
                ServiceIcon(kind: kind, size: 18)
                    .foregroundStyle(.primary)
                Text(verbatim: title)
                Spacer()
                if configured {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var iosMediaManagersForm: some View {
        iosServiceList(mediaManagerSpecs, title: "Media managers")
    }

    private var iosDownloadClientsForm: some View {
        iosServiceList(downloadClientSpecs, title: "Download clients")
            .disabled(!storeManager.isPro)
            .overlay {
                if !storeManager.isPro {
                    ProLockOverlay(feature: .downloadClients)
                }
            }
    }

    /// iOS chrome: each service is a `NavigationLink` row drilling into its
    /// own screen — same roster as macOS, different presentation.
    private func iosServiceList(_ specs: [ServiceSpec], title: LocalizedStringKey) -> some View {
        List {
            ForEach(specs) { spec in
                iosServiceLink(kind: spec.kind, title: spec.title,
                               configured: spec.config.wrappedValue.isConfigured) {
                    serviceFields(spec)
                }
            }
        }
        .navigationTitle(Text(title, bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var iosAIForm: some View {
        Form { aiSection }
            .navigationTitle(Text("Assistant", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
    }

    private var iosGeneralForm: some View {
        Form {
            // No language picker on iOS — it always follows the system
            // language (see ConfigStore: appLanguage is forced to "system"
            // on iOS).
            Section {
                ForEach(configStore.arrOrder, id: \.self) { key in
                    arrOrderRow(key: key)
                }
                .onMove(perform: moveArrOrder)
            } header: {
                HStack {
                    Text("Section order", bundle: .module)
                    Spacer()
                    EditButton()
                        .textCase(nil)
                        .font(.caption)
                }
            }
            // No theme picker on iOS — it always follows the system
            // appearance (forced in ConfigStore).
            // iOS has no "Show indexer issues" toggle and no refresh-interval
            // picker: indexer warnings are off, and foreground polling is a
            // fixed 5s while the app is open (iOS suspends apps in the
            // background, so there's no configurable background interval).
            // Both are forced in ConfigStore for iOS.
        }
        .navigationTitle(Text("General", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var iosAboutForm: some View {
        Form {
            if devModeRevealed {
                demoModeSection
            }
            Section {
                // Classic iOS Settings.app trick: tap Version 7 times to
                // reveal Developer options. LabeledContent swallows
                // gestures inside Form, so use a plain Button styled like
                // a row instead — its action fires reliably.
                Button {
                    versionTapCount += 1
                    if versionTapCount >= 7 && !devModeRevealed {
                        DeveloperMode.setEnabled(true)
                        withAnimation(.smooth(duration: 0.22)) { devModeRevealed = true }
                    }
                } label: {
                    HStack {
                        Text("Version", bundle: .module)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(Self.versionString)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Link(destination: URL(string: "https://github.com/Preclowski/ArrBarr")!) {
                    Label { Text(verbatim: "GitHub") } icon: { Image(systemName: "link") }
                }
                Link(destination: URL(string: "https://arrbarr.app")!) {
                    Label { Text("Website", bundle: .module) } icon: { Image(systemName: "globe") }
                }
                Link(destination: URL(string: "https://arrbarr.app/privacy-policy")!) {
                    Label { Text("Privacy Policy", bundle: .module) } icon: { Image(systemName: "hand.raised") }
                }
                Text(verbatim: "Made by 🥨")
                    .foregroundStyle(.secondary)
            } header: { Text("About", bundle: .module) }
            Section {
                Link(destination: URL(string: "https://dashboardicons.com")!) {
                    Label { Text(verbatim: "Dashboard Icons — CC BY 4.0") } icon: { Image(systemName: "paintpalette") }
                }
            } header: { Text("Acknowledgements", bundle: .module) } footer: {
                Text("Service icons by Dashboard Icons, licensed CC BY 4.0 (recoloured for the UI).", bundle: .module)
            }
        }
        .navigationTitle(Text("About", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
    }
    #endif

    /// Developer "Demo mode" controls — identical on both platforms; only the
    /// visibility condition differs (macOS keys off `DeveloperMode.isActive`,
    /// iOS off the 7-tap-revealed `devModeRevealed`), so callers wrap it.
    @ViewBuilder
    private var demoModeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { demoModeOn },
                set: { newValue in
                    guard newValue != demoModeOn else { return }
                    // Confirm via the callback BEFORE flipping local state — if
                    // the user cancels the relaunch, the toggle stays in sync.
                    let committed = onSetDemoMode?(newValue) ?? false
                    if committed { demoModeOn = newValue }
                }
            )) { Text("Demo mode", bundle: .module) }
            if demoModeOn {
                if let onTestNotification {
                    Button { onTestNotification() } label: { Text("Send test notification", bundle: .module) }
                }
                if let onShowWelcome {
                    Button { onShowWelcome() } label: { Text("Show welcome screen", bundle: .module) }
                }
            }
        } header: { Text("Developer options", bundle: .module) }
    }

    // MARK: - Service roster (shared data)

    /// One configurable service row. Both the macOS panes and the iOS forms
    /// render the *same* roster from this data — the only difference is the
    /// chrome (a `Section` vs a `NavigationLink`). Adding a service, or wiring
    /// a new per-service binding, happens in one place.
    private struct ServiceSpec: Identifiable {
        let kind: ServiceKind
        let title: String
        let config: Binding<ServiceConfig>
        var notify: Binding<Bool>? = nil
        var ageConfirmed: Binding<Bool>? = nil
        var nsfwFilter: Binding<Bool>? = nil
        var id: String { kind.rawValue }
    }

    private var mediaManagerSpecs: [ServiceSpec] {
        [
            .init(kind: .radarr, title: "Radarr", config: $configStore.radarr, notify: $configStore.notifyRadarr),
            .init(kind: .sonarr, title: "Sonarr", config: $configStore.sonarr, notify: $configStore.notifySonarr),
            .init(kind: .lidarr, title: "Lidarr", config: $configStore.lidarr, notify: $configStore.notifyLidarr),
            .init(kind: .whisparr, title: "Whisparr", config: $configStore.whisparr,
                  ageConfirmed: $configStore.whisparrAgeConfirmed, nsfwFilter: $configStore.blurWhisparrPosters),
        ]
    }

    private var downloadClientSpecs: [ServiceSpec] {
        [
            .init(kind: .sabnzbd, title: "SABnzbd", config: $configStore.sabnzbd),
            .init(kind: .nzbget, title: "NZBGet", config: $configStore.nzbget),
            .init(kind: .qbittorrent, title: "qBittorrent", config: $configStore.qbittorrent),
            .init(kind: .transmission, title: "Transmission", config: $configStore.transmission),
            .init(kind: .rtorrent, title: "rTorrent", config: $configStore.rtorrent),
            .init(kind: .deluge, title: "Deluge", config: $configStore.deluge),
        ]
    }

    /// The actual fields for one service — single wiring point for every spec
    /// binding, so neither platform repeats the argument list.
    private func serviceFields(_ spec: ServiceSpec) -> some View {
        ServiceFields(config: spec.config, kind: spec.kind,
                      notifyBinding: spec.notify,
                      ageConfirmedBinding: spec.ageConfirmed,
                      nsfwFilterBinding: spec.nsfwFilter)
    }

    // MARK: - Panes

    private var mediaManagersPane: some View { servicePane(mediaManagerSpecs) }
    private var downloadClientsPane: some View {
        servicePane(downloadClientSpecs)
            .disabled(!storeManager.isPro)
            .overlay {
                if !storeManager.isPro {
                    ProLockOverlay(feature: .downloadClients)
                }
            }
    }

    /// macOS chrome: one grouped `Section` per service, brand-icon header.
    private func servicePane(_ specs: [ServiceSpec]) -> some View {
        Form {
            ForEach(specs) { spec in
                Section {
                    serviceFields(spec)
                } header: { serviceSectionHeader(spec.kind, LocalizedStringKey(spec.title)) }
            }
        }
        .formStyle(.grouped)
    }

    /// Section header with the service's brand icon. Shared by the macOS panes
    /// and the iOS forms so every configured service is visually identifiable.
    @ViewBuilder
    private func serviceSectionHeader(_ kind: ServiceKind, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            ServiceIcon(kind: kind, size: 12)
                .foregroundStyle(.secondary)
            Text(title, bundle: .module)
        }
    }

    private var generalPane: some View {
        Form {
            Section {
                Toggle(isOn: $configStore.launchAtLogin) { Text("Launch at login", bundle: .module) }
                Picker(selection: $configStore.appLanguage) {
                    ForEach(ConfigStore.appLanguageOptions, id: \.code) { opt in
                        Text(LocalizedStringKey(opt.label)).tag(opt.code)
                    }
                } label: { Text("Language", bundle: .module) }
                themePicker
                textSizePicker
                notificationSoundPicker
                // Popover-display toggle merged in here — used to
                // live in its own "Popover" section but with the
                // upcoming-window picker gone there was only one
                // toggle left, which read as orphaned. App-level
                // toggles all sit under one heading now.
                Toggle(isOn: $configStore.showIndexerIssues) { Text("Show indexer issues warning", bundle: .module) }
            } header: {
                Text("Application", bundle: .module)
            } footer: {
                if languageChanged {
                    #if os(macOS)
                    HStack(spacing: 8) {
                        Text("Restart required to apply the new language.", bundle: .module)
                        Button { relaunchApp() } label: { Text("Relaunch", bundle: .module) }
                            .controlSize(.small)
                    }
                    #else
                    Text("Quit and reopen the app to apply the new language.", bundle: .module)
                    #endif
                }
            }
            Section {
                ForEach(configStore.arrOrder, id: \.self) { key in
                    arrOrderRow(key: key)
                }
                .onMove(perform: moveArrOrder)
            } header: { Text("Section order", bundle: .module) }
            Section {
                Picker(selection: $configStore.foregroundInterval) {
                    ForEach(ConfigStore.foregroundIntervalOptions, id: \.self) { interval in
                        Text(Self.formatInterval(interval)).tag(interval)
                    }
                } label: { Text("Popover open", bundle: .module) }
                Picker(selection: $configStore.backgroundInterval) {
                    ForEach(ConfigStore.backgroundIntervalOptions, id: \.self) { interval in
                        Text(Self.formatInterval(interval)).tag(interval)
                    }
                } label: { Text("Background", bundle: .module) }
            } header: { Text("Refresh Interval", bundle: .module) }
            if DeveloperMode.isActive {
                demoModeSection
            }
            if #available(macOS 13.0, *) {
                SiriShortcutsSettingsContent()
            }
        }
        .formStyle(.grouped)
    }

    /// Global notification-sound picker, inlined into the Application section.
    /// One setting for every queue banner, so it lives with the other
    /// app-level toggles rather than per-arr. Selecting a named sound previews
    /// it immediately — same affordance as macOS Sound preferences. iOS gets
    /// nothing (no `/System/Library/Sounds` enumeration); the default stays.
    @ViewBuilder
    private var notificationSoundPicker: some View {
        #if os(macOS)
        Picker(selection: $configStore.notificationSoundName) {
            Text("Default", bundle: .module).tag("")
            Text("None", bundle: .module).tag(ConfigStore.silentSoundName)
            Divider()
            ForEach(Self.systemSoundNames, id: \.self) { name in
                Text(name).tag(name)
            }
        } label: {
            HStack(spacing: 6) {
                Text("Notification sound", bundle: .module)
                Button { Self.previewSound(named: configStore.notificationSoundName) } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Text("Play", bundle: .module))
            }
        }
        .onChange(of: configStore.notificationSoundName) { _, newValue in
            Self.previewSound(named: newValue)
        }
        #endif
    }

    #if os(macOS)
    /// Sound files shipped in `/System/Library/Sounds`, sans extension and
    /// sorted. These are exactly the names `NSSound(named:)` and
    /// `UNNotificationSound(named: "<name>.aiff")` resolve.
    private static let systemSoundNames: [String] = {
        let dir = "/System/Library/Sounds"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files
            .filter { $0.hasSuffix(".aiff") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }()

    /// Plays a named system sound as a preview. No-op for the "Default" and
    /// "None" sentinels — neither maps to a previewable `NSSound`.
    private static func previewSound(named name: String) {
        guard !name.isEmpty, name != ConfigStore.silentSoundName else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
    #endif

    private static let arrRowHeight: CGFloat = 24

    @ViewBuilder
    private func arrOrderRow(key: String) -> some View {
        if let spec = orderRowSpec(for: key) {
            // Reordering is native (`.onMove`). Keep a grip glyph as the
            // "you can drag this" affordance (the iOS native grip only shows
            // in edit mode; macOS has none), but the actual drag is `.onMove`.
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .scaledFont(size: 11)
                Group {
                    if let source = QueueItem.Source(rawValue: key) {
                        ServiceIcon(source: source, size: 13)
                    } else {
                        Image(systemName: spec.symbol)
                    }
                }
                .foregroundStyle(.secondary)
                .frame(width: 16)
                Text(spec.title)
                Spacer()
                if let toggle = visibilityToggle(for: key) {
                    Toggle("", isOn: toggle)
                        .labelsHidden()
                        .controlSize(.small)
                        .toggleStyle(.switch)
                }
            }
            .frame(height: Self.arrRowHeight)
            .contentShape(Rectangle())
        }
    }

    /// Native reorder applied to the "Section order" ForEach.
    private func moveArrOrder(from: IndexSet, to: Int) {
        configStore.arrOrder.move(fromOffsets: from, toOffset: to)
    }

    private struct OrderRowSpec {
        let title: LocalizedStringKey
        let symbol: String
    }

    private func visibilityToggle(for key: String) -> Binding<Bool>? {
        if key == ConfigStore.tonightOrderKey { return $configStore.showTonight }
        if key == ConfigStore.needsYouOrderKey { return $configStore.showNeedsYou }
        return nil
    }

    private func orderRowSpec(for key: String) -> OrderRowSpec? {
        if key == ConfigStore.tonightOrderKey {
            return .init(title: "Upcoming", symbol: "moon.stars.fill")
        }
        if key == ConfigStore.needsYouOrderKey {
            return .init(title: "Needs you", symbol: "exclamationmark.bubble.fill")
        }
        if let source = QueueItem.Source(rawValue: key) {
            return .init(title: LocalizedStringKey(source.displayName), symbol: source.symbol)
        }
        return nil
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        // The footer's links and credits moved to the native "About ArrBarr"
        // panel (reachable from the popover's "…" menu), leaving just the
        // window's Close control here. Version still lives in the window title
        // ("ArrBarr Settings vX.Y").
        VStack(spacing: 0) {
            HStack {
                Spacer()
                #if os(macOS)
                Button { NSApp.keyWindow?.close() } label: { Text("Close", bundle: .module) }
                    .keyboardShortcut("w", modifiers: .command)
                    .modifier(GlassButtonStyle())
                    .controlSize(.large)
                #endif
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return short == build ? "v\(short)" : "v\(short) (\(build))"
    }

    private static func formatInterval(_ seconds: TimeInterval) -> String {
        if seconds == 0 {
            return String(localized: "Never", bundle: .module)
        } else if seconds < 60 {
            return "\(Int(seconds))s"
        } else {
            return "\(Int(seconds) / 60)m"
        }
    }

    private static func formatTonight(hours: Int) -> String {
        if hours < 24 {
            return String(format: String(localized: "%lld hours", bundle: .module), hours)
        }
        let days = hours / 24
        if days == 1 { return String(localized: "24 hours", bundle: .module) }
        return String(format: String(localized: "%lld days", bundle: .module), days)
    }
}

private struct ProLockOverlay: View {
    @ObservedObject private var store = StoreManager.shared
    let feature: ProFeature
    var body: some View {
        ZStack {
            Color.black.opacity(0.04)
            VStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.title2).foregroundStyle(.secondary)
                Button { store.gate(feature) } label: {
                    Text("Unlock ArrBarr Pro", bundle: .module)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.gate(feature) }
    }
}
