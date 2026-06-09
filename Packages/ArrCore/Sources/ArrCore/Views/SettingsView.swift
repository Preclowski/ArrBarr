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
    #if os(macOS)
    /// Which sidebar row is selected in the macOS System-Settings-style layout.
    @State private var macSelection: SettingsSection = .general
    /// Sidebar search query. Non-empty collapses the structured list into a
    /// flat, filtered set of matching rows.
    @State private var macSearch: String = ""
    /// Back/forward navigation history (like System Settings). `historyIndex`
    /// points at the current entry; `isNavigatingHistory` suppresses recording
    /// when a selection change came from the back/forward buttons themselves.
    @State private var history: [SettingsSection] = [.general]
    @State private var historyIndex: Int = 0
    @State private var isNavigatingHistory: Bool = false

    /// Sidebar rows for the macOS Settings window. Media Managers and Download
    /// clients are hub rows that open a card list (iOS-style); tapping a card
    /// drills into `.service(kind)`, a single-config page reached via history,
    /// not a sidebar row of its own.
    enum SettingsSection: Hashable {
        case general
        case mediaManagers
        case downloadClients
        case service(ServiceKind)
        case assistant
        case mcp
        case icloud
        case siri
        case about
    }
    #endif

    private var languageChanged: Bool {
        guard let initial = initialAppLanguage else { return false }
        return initial != configStore.appLanguage
    }

    public var body: some View {
        Group {
            #if os(macOS)
            macSidebarLayout
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
            Text("settings.default.button", bundle: .module).tag(1.0 as Double)
            Text("settings.larger.button", bundle: .module).tag(1.10 as Double)
            Text("settings.largest.button", bundle: .module).tag(1.20 as Double)
        } label: { Text("settings.textSize.button", bundle: .module) }
    }

    /// Light / Dark / System appearance preset. Applied via
    /// `.preferredColorScheme` at every scene root.
    @ViewBuilder
    private var themePicker: some View {
        Picker(selection: $configStore.appearance) {
            Text("settings.system.button", bundle: .module).tag("system")
            Text("settings.light.button", bundle: .module).tag("light")
            Text("settings.dark.button", bundle: .module).tag("dark")
        } label: { Text("settings.theme.button", bundle: .module) }
    }

    /// Shared "AI" section. One master toggle at the top kills the whole
    /// feature; provider controls only appear when AI is on.
    @ViewBuilder
    private var aiSection: some View {
        Section {
            Toggle(isOn: $configStore.aiEnabled) { Text("settings.enableAi.button", bundle: .module) }
        } header: { Text("settings.assistant.button", bundle: .module) }
        if configStore.aiEnabled {
            Section {
                Picker(selection: $configStore.chatProvider) {
                    // Hide Apple Intelligence on devices that don't support it.
                    ForEach(ChatProvider.allCases.filter {
                        $0 != .foundationModels || FoundationModelsAvailability.isSupported
                    }) { p in
                        Text(p.displayName).tag(p)
                    }
                } label: { Text("settings.aiProvider.button", bundle: .module) }
                if configStore.chatProvider == .openai {
                    TextField(text: $configStore.openai.baseURL,
                              prompt: Text(verbatim: "https://api.openai.com/v1")) {
                        Text("settings.apiBaseUrl.button", bundle: .module)
                    }
                    .urlField()
                    SecureField(text: $configStore.openai.apiKey) { Text("settings.apiKey2.button", bundle: .module) }
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
                        Text("settings.model.button", bundle: .module)
                    }
                    if !configStore.openai.apiKey.isEmpty && !configStore.openai.baseURL.isEmpty {
                        ApiKeyTestButton {
                            try await OpenAIProvider(config: configStore.openai).testConnection()
                        }
                    }
                    if !configStore.openai.isConfigured {
                        Label {
                            Text("settings.addBaseUrlApi.tooltip", bundle: .module)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    Text("settings.theModelMustSupport.tooltip", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if configStore.chatProvider == .foundationModels {
                    #if os(macOS)
                    if #unavailable(macOS 26.0) {
                        Label { Text("settings.appleIntelligenceRequiresMacos.tooltip", bundle: .module) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    #else
                    if #unavailable(iOS 26.0) {
                        Label { Text("settings.appleIntelligenceRequiresIos.tooltip", bundle: .module) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    #endif
                }
                if configStore.whisparr.isConfigured {
                    Toggle(isOn: $configStore.aiKnowsAboutWhisparr) { Text("settings.aiKnowsAboutWhisparr.button", bundle: .module) }
                }
            }
            Section {
                SecureField(text: $configStore.tmdbApiKey,
                            prompt: Text(verbatim: "v4 Read Access Token")) {
                    Text("settings.tmdbReadAccessToken.button", bundle: .module)
                }
                .apiKeyField()
                if !configStore.tmdbApiKey.isEmpty {
                    ApiKeyTestButton {
                        try await TMDBClient(apiKey: configStore.tmdbApiKey).testConnection()
                    }
                }
                if let url = URL(string: "https://www.themoviedb.org/settings/api") {
                    Link(destination: url) {
                        Label { Text("settings.getAFreeTmdb.button", bundle: .module) } icon: { Image(systemName: "link") }
                            .font(.caption)
                    }
                }
            } header: {
                Text("settings.discovery.button", bundle: .module)
            } footer: {
                Text(configStore.tmdbEnabled
                     ? String(localized: "settings.chatCanSearchBy.tooltip", bundle: .module)
                     : String(localized: "settings.addATmdbKey.tooltip", bundle: .module))
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

    // MARK: - macOS sidebar layout (System Settings style)

    /// Window-vibrant material for the custom sidebar column, so it matches a
    /// native sidebar (and the traffic-lights read on top of it).
    private struct SidebarVibrancy: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let v = NSVisualEffectView()
            v.material = .sidebar
            v.blendingMode = .behindWindow
            v.state = .followsWindowActiveState
            return v
        }
        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
    }


    /// NavigationSplitView with a sidebar list of sections and a detail pane.
    /// Replaces the old TabView + bottom "Close" bar — the window now closes
    /// via ⌘W / the red traffic-light, like native System Settings.
    private var macSidebarLayout: some View {
        // Hand-built two columns. NavigationSplitView on macOS 26 (Tahoe)
        // renders its sidebar as a floating "liquid glass" rounded card inset
        // from the window edges — which leaves the traffic-lights stranded off
        // the sidebar. A manual layout with our own vibrant material gives the
        // classic flush sidebar (traffic-lights ON it) the design calls for.
        HStack(spacing: 0) {
            sidebarColumn
                .frame(width: 232)
                .background(SidebarVibrancy().ignoresSafeArea())
            Divider()
                .ignoresSafeArea()
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.all)
        .onChange(of: macSelection) { _, newValue in
            recordHistory(newValue)
        }
    }

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            // Clear the floating traffic-lights at the top of the column.
            Color.clear.frame(height: 30)
            sidebarSearchField
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            List(selection: sidebarSelectionBinding) {
                if macSearch.isEmpty {
                    structuredSidebar
                } else {
                    ForEach(filteredSidebarEntries) { entry in sidebarEntryRow(entry) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            detailTopBar
            detailPane(for: macSelection)
        }
    }

    /// Top bar of the detail column: back/forward as a segmented pill (like
    /// System Settings' `‹ | ›`) then the large section title — aligned with
    /// the floating traffic-lights of the sidebar.
    private var detailTopBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                Button { goBack() } label: {
                    Image(systemName: "chevron.backward")
                        .frame(width: 30, height: 24)
                        .contentShape(Rectangle())
                }
                .disabled(!canGoBack)
                .help(Text("settings.back.button", bundle: .module))
                Divider().frame(height: 15)
                Button { goForward() } label: {
                    Image(systemName: "chevron.forward")
                        .frame(width: 30, height: 24)
                        .contentShape(Rectangle())
                }
                .disabled(!canGoForward)
                .help(Text("settings.forward.button", bundle: .module))
            }
            .buttonStyle(.borderless)
            .font(.body.weight(.medium))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )

            navTitle(for: macSelection)
                .font(.title2.weight(.bold))

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    /// The List highlights a top-level row, but the *content* can be a service
    /// page nested under a hub. Map the active service back to its hub so the
    /// owning row (Media Managers / Download clients) stays selected while
    /// you're inside Radarr etc. Setting it (a user click) drives `macSelection`.
    private var sidebarSelectionBinding: Binding<SettingsSection?> {
        Binding(
            get: { sidebarParent(of: macSelection) },
            set: { if let new = $0 { macSelection = new } }
        )
    }

    private func sidebarParent(of section: SettingsSection) -> SettingsSection {
        if case .service(let kind) = section {
            return downloadClientSpecs.contains { $0.kind == kind } ? .downloadClients : .mediaManagers
        }
        return section
    }

    /// Apple-style search field living at the top of the sidebar body.
    private var sidebarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            TextField(text: $macSearch) { Text("search.search.button", bundle: .module) }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !macSearch.isEmpty {
                Button { macSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.7))
        )
    }

    /// The normal (non-searching) sidebar: flat rows. Media Managers and
    /// Download clients are hubs that open a card list in the detail.
    @ViewBuilder
    private var structuredSidebar: some View {
        Label { Text("settings.general.button", bundle: .module) } icon: { Image(systemName: "gearshape") }
            .tag(SettingsSection.general)
        Label { Text("settings.mediaManagers.button", bundle: .module) } icon: { Image(systemName: "server.rack") }
            .tag(SettingsSection.mediaManagers)
        Label { Text("settings.downloadClients.button", bundle: .module) } icon: { Image(systemName: "arrow.down.circle") }
            .tag(SettingsSection.downloadClients)
        Label { Text("settings.assistant.button", bundle: .module) } icon: { Image(systemName: "sparkles") }
            .tag(SettingsSection.assistant)
        Label { Text("settings.mcp.label", bundle: .module) } icon: { Image(systemName: "point.3.connected.trianglepath.dotted") }
            .tag(SettingsSection.mcp)
        if AppCapabilities.isAppStore {
            Label { Text("settings.icloud.label", bundle: .module) } icon: { Image(systemName: "icloud") }
                .tag(SettingsSection.icloud)
        }
        Label { Text("settings.siriShortcuts.button", bundle: .module) } icon: { Image(systemName: "mic.fill") }
            .tag(SettingsSection.siri)
        Label { Text("settings.about.button", bundle: .module) } icon: { Image(systemName: "info.circle") }
            .tag(SettingsSection.about)
    }

    // MARK: - Sidebar search

    /// A flat, searchable directory of every sidebar destination. `kind` drives
    /// a brand `ServiceIcon`; when nil the `systemImage` SF Symbol is used.
    private struct SidebarEntry: Identifiable {
        let section: SettingsSection
        let title: String
        let kind: ServiceKind?
        let systemImage: String
        var id: SettingsSection { section }
    }

    private var sidebarEntries: [SidebarEntry] {
        var items: [SidebarEntry] = [
            .init(section: .general, title: String(localized: "settings.general.button", bundle: .module), kind: nil, systemImage: "gearshape"),
            .init(section: .mediaManagers, title: String(localized: "settings.mediaManagers.button", bundle: .module), kind: nil, systemImage: "server.rack"),
            .init(section: .downloadClients, title: String(localized: "settings.downloadClients.button", bundle: .module), kind: nil, systemImage: "arrow.down.circle"),
        ]
        items += (mediaManagerSpecs + downloadClientSpecs).map {
            .init(section: .service($0.kind), title: $0.title, kind: $0.kind, systemImage: "")
        }
        items += [
            .init(section: .assistant, title: String(localized: "settings.assistant.button", bundle: .module), kind: nil, systemImage: "sparkles"),
            .init(section: .mcp, title: String(localized: "settings.mcp.label", bundle: .module), kind: nil, systemImage: "point.3.connected.trianglepath.dotted"),
        ]
        if AppCapabilities.isAppStore {
            items.append(.init(section: .icloud, title: String(localized: "settings.icloud.label", bundle: .module), kind: nil, systemImage: "icloud"))
        }
        items += [
            .init(section: .siri, title: String(localized: "settings.siriShortcuts.button", bundle: .module), kind: nil, systemImage: "mic.fill"),
            .init(section: .about, title: String(localized: "settings.about.button", bundle: .module), kind: nil, systemImage: "info.circle"),
        ]
        return items
    }

    private var filteredSidebarEntries: [SidebarEntry] {
        let q = macSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return sidebarEntries.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    private func sidebarEntryRow(_ entry: SidebarEntry) -> some View {
        Label {
            Text(verbatim: entry.title)
        } icon: {
            if let kind = entry.kind {
                ServiceIcon(kind: kind, size: 14)
            } else {
                Image(systemName: entry.systemImage)
            }
        }
        .tag(entry.section)
    }

    // MARK: - Back/forward history

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex < history.count - 1 }

    /// Record a selection change in the history stack, unless it originated
    /// from a back/forward button (which sets `isNavigatingHistory`).
    private func recordHistory(_ section: SettingsSection) {
        if isNavigatingHistory { isNavigatingHistory = false; return }
        // Truncate any forward entries — a fresh navigation forks history.
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(section)
        historyIndex = history.count - 1
    }

    private func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        isNavigatingHistory = true
        macSelection = history[historyIndex]
    }

    private func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        isNavigatingHistory = true
        macSelection = history[historyIndex]
    }

    /// Window title for the selected section.
    private func navTitle(for section: SettingsSection) -> Text {
        switch section {
        case .general: return Text("settings.general.button", bundle: .module)
        case .mediaManagers: return Text("settings.mediaManagers.button", bundle: .module)
        case .downloadClients: return Text("settings.downloadClients.button", bundle: .module)
        case .service(let kind): return Text(verbatim: kind.displayName)
        case .assistant: return Text("settings.assistant.button", bundle: .module)
        case .mcp: return Text("settings.mcp.label", bundle: .module)
        case .icloud: return Text("settings.icloud.label", bundle: .module)
        case .siri: return Text("settings.siriShortcuts.button", bundle: .module)
        case .about: return Text("settings.about.button", bundle: .module)
        }
    }

    @ViewBuilder
    private func detailPane(for section: SettingsSection) -> some View {
        switch section {
        case .general: generalPane
        case .mediaManagers: serviceHubPane(mediaManagerSpecs, locked: false)
        case .downloadClients: serviceHubPane(downloadClientSpecs, locked: true)
        case .service(let kind): singleServicePane(for: kind)
        case .assistant: aiPane
        case .mcp: MCPSettingsPane()
        case .icloud: ICloudSettingsView()
        case .siri: siriPane
        case .about: aboutPane
        }
    }

    /// Hub page: a card list of services (iOS-style). Tapping a card drills
    /// into that service's single-config page via `macSelection` (so the
    /// back/forward arrows return here). Download clients stay Pro-gated.
    private func serviceHubPane(_ specs: [ServiceSpec], locked: Bool) -> some View {
        Form {
            Section {
                ForEach(specs) { spec in
                    Button {
                        macSelection = .service(spec.kind)
                    } label: {
                        HStack(spacing: 10) {
                            ServiceIcon(kind: spec.kind, size: 18)
                            Text(verbatim: spec.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            if spec.config.wrappedValue.isConfigured {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.green)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(locked && !storeManager.isPro)
        .overlay {
            if locked && !storeManager.isPro {
                ProLockOverlay(feature: .downloadClients)
            }
        }
    }

    /// One service's config on its own page (one configuration per page). The
    /// roster (`mediaManagerSpecs` / `downloadClientSpecs`) is shared with iOS;
    /// download clients stay Pro-gated, same as the old combined pane.
    @ViewBuilder
    private func singleServicePane(for kind: ServiceKind) -> some View {
        if let spec = (mediaManagerSpecs + downloadClientSpecs).first(where: { $0.kind == kind }) {
            let isDownloadClient = downloadClientSpecs.contains { $0.kind == kind }
            Form {
                Section {
                    serviceFields(spec)
                } header: { serviceSectionHeader(spec.kind, LocalizedStringKey(spec.title)) }
            }
            .formStyle(.grouped)
            .disabled(isDownloadClient && !storeManager.isPro)
            .overlay {
                if isDownloadClient && !storeManager.isPro {
                    ProLockOverlay(feature: .downloadClients)
                }
            }
        }
    }

    /// Siri & Shortcuts on its own sidebar row (was inlined at the bottom of
    /// the General pane under the TabView layout).
    private var siriPane: some View {
        Form {
            if #available(macOS 13.0, *) {
                SiriShortcutsSettingsContent()
            }
        }
        .formStyle(.grouped)
    }

    /// About pane — version, project links, acknowledgements, and the
    /// Developer/Demo controls (gated on Developer mode). Mirrors the iOS
    /// About form; under the old macOS layout this content lived in the
    /// native "About ArrBarr" panel + the General pane's demo section.
    private var aboutPane: some View {
        Form {
            if DeveloperMode.isActive {
                demoModeSection
            }
            Section {
                LabeledContent {
                    Text(Self.versionString).foregroundStyle(.secondary)
                } label: {
                    Text("settings.version.button", bundle: .module)
                }
                Link(destination: URL(string: "https://github.com/Preclowski/ArrBarr")!) {
                    Label { Text(verbatim: "GitHub") } icon: { Image(systemName: "link") }
                }
                Link(destination: URL(string: "https://arrbarr.app")!) {
                    Label { Text("settings.website.button", bundle: .module) } icon: { Image(systemName: "globe") }
                }
                Link(destination: URL(string: "https://arrbarr.app/privacy-policy")!) {
                    Label { Text("settings.privacyPolicy.button", bundle: .module) } icon: { Image(systemName: "hand.raised") }
                }
                Text(verbatim: "Made by 🥨")
                    .foregroundStyle(.secondary)
            } header: { Text("settings.about.button", bundle: .module) }
            Section {
                Link(destination: URL(string: "https://dashboardicons.com")!) {
                    Label { Text(verbatim: "Dashboard Icons — CC BY 4.0") } icon: { Image(systemName: "paintpalette") }
                }
            } header: { Text("settings.acknowledgements.button", bundle: .module) } footer: {
                Text("settings.serviceIconsByDashboard.tooltip", bundle: .module)
            }
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
            if AppCapabilities.isAppStore {
                iosSettingsLink("iCloud", systemImage: "icloud") { ICloudSettingsView() }
            }
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
        .navigationTitle(Text("settings.siriShortcuts.button", bundle: .module))
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
            .navigationTitle(Text("settings.assistant.button", bundle: .module))
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
                    Text("settings.sectionOrder.button", bundle: .module)
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
        .navigationTitle(Text("settings.general.button", bundle: .module))
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
                        Text("settings.version.button", bundle: .module)
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
                    Label { Text("settings.website.button", bundle: .module) } icon: { Image(systemName: "globe") }
                }
                Link(destination: URL(string: "https://arrbarr.app/privacy-policy")!) {
                    Label { Text("settings.privacyPolicy.button", bundle: .module) } icon: { Image(systemName: "hand.raised") }
                }
                Text(verbatim: "Made by 🥨")
                    .foregroundStyle(.secondary)
            } header: { Text("settings.about.button", bundle: .module) }
            Section {
                Link(destination: URL(string: "https://dashboardicons.com")!) {
                    Label { Text(verbatim: "Dashboard Icons — CC BY 4.0") } icon: { Image(systemName: "paintpalette") }
                }
            } header: { Text("settings.acknowledgements.button", bundle: .module) } footer: {
                Text("settings.serviceIconsByDashboard.tooltip", bundle: .module)
            }
        }
        .navigationTitle(Text("settings.about.button", bundle: .module))
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
            )) { Text("settings.demoMode.button", bundle: .module) }
            if demoModeOn {
                if let onTestNotification {
                    Button { onTestNotification() } label: { Text("settings.sendTestNotification.button", bundle: .module) }
                }
                if let onShowWelcome {
                    Button { onShowWelcome() } label: { Text("settings.showWelcomeScreen.button", bundle: .module) }
                }
            }
        } header: { Text("settings.developerOptions.button", bundle: .module) }
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
                Toggle(isOn: $configStore.launchAtLogin) { Text("settings.launchAtLogin.button", bundle: .module) }
                #if os(macOS)
                Toggle(isOn: $configStore.detachedWindow) {
                    Text("settings.showInDockAs.button", bundle: .module)
                    Text("settings.detachFromTheMenu.tooltip", bundle: .module)
                }
                #endif
                Picker(selection: $configStore.appLanguage) {
                    ForEach(ConfigStore.appLanguageOptions, id: \.code) { opt in
                        Text(LocalizedStringKey(opt.label)).tag(opt.code)
                    }
                } label: { Text("settings.language.button", bundle: .module) }
                themePicker
                textSizePicker
                notificationSoundPicker
                // Popover-display toggle merged in here — used to
                // live in its own "Popover" section but with the
                // upcoming-window picker gone there was only one
                // toggle left, which read as orphaned. App-level
                // toggles all sit under one heading now.
                Toggle(isOn: $configStore.showIndexerIssues) { Text("settings.showIndexerIssuesWarning.label", bundle: .module) }
            } header: {
                Text("settings.application.button", bundle: .module)
            } footer: {
                if languageChanged {
                    #if os(macOS)
                    HStack(spacing: 8) {
                        Text("settings.restartRequiredToApply.tooltip", bundle: .module)
                        Button { relaunchApp() } label: { Text("settings.relaunch.button", bundle: .module) }
                            .controlSize(.small)
                    }
                    #else
                    Text("settings.quitAndReopenThe.tooltip", bundle: .module)
                    #endif
                }
            }
            Section {
                ForEach(configStore.arrOrder, id: \.self) { key in
                    arrOrderRow(key: key)
                }
                .onMove(perform: moveArrOrder)
            } header: { Text("settings.sectionOrder.button", bundle: .module) }
            Section {
                Picker(selection: $configStore.foregroundInterval) {
                    ForEach(ConfigStore.foregroundIntervalOptions, id: \.self) { interval in
                        Text(Self.formatInterval(interval)).tag(interval)
                    }
                } label: { Text("settings.popoverOpen.button", bundle: .module) }
                Picker(selection: $configStore.backgroundInterval) {
                    ForEach(ConfigStore.backgroundIntervalOptions, id: \.self) { interval in
                        Text(Self.formatInterval(interval)).tag(interval)
                    }
                } label: { Text("settings.background.button", bundle: .module) }
            } header: { Text("settings.refreshInterval.button", bundle: .module) }
            // Developer/Demo controls moved to the About pane; Siri & Shortcuts
            // is now its own sidebar row (see siriPane).
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
            Text("settings.default.button", bundle: .module).tag("")
            Text("search.none.button", bundle: .module).tag(ConfigStore.silentSoundName)
            Divider()
            ForEach(Self.systemSoundNames, id: \.self) { name in
                Text(name).tag(name)
            }
        } label: {
            HStack(spacing: 6) {
                Text("settings.notificationSound.button", bundle: .module)
                Button { Self.previewSound(named: configStore.notificationSoundName) } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Text("settings.play.button", bundle: .module))
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

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return short == build ? "v\(short)" : "v\(short) (\(build))"
    }

    private static func formatInterval(_ seconds: TimeInterval) -> String {
        if seconds == 0 {
            return String(localized: "settings.never.button", bundle: .module)
        } else if seconds < 60 {
            return "\(Int(seconds))s"
        } else {
            return "\(Int(seconds) / 60)m"
        }
    }

    private static func formatTonight(hours: Int) -> String {
        if hours < 24 {
            return String.localizedStringWithFormat(NSLocalizedString("unit.hours", bundle: .module, comment: ""), hours)
        }
        let days = hours / 24
        if days == 1 { return String(localized: "settings.twentyFourHours.label", bundle: .module) }
        return String.localizedStringWithFormat(NSLocalizedString("unit.days", bundle: .module, comment: ""), days)
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
                    Text("settings.unlockArrbarrPro.button", bundle: .module)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.gate(feature) }
    }
}
