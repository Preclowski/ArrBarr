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
    /// `@Bindable` because the queue state is `@Observable`, not a `$`-projected store.
    @Bindable var queueUI = QueueUIState.shared
    @ObservedObject private var storeManager = StoreManager.shared
    @State private var demoModeOn: Bool = DemoMode.isActive
    @State private var telemetryReport: String?
    /// iOS: 7 taps on the Version row enable Developer mode (no launch args there).
    @State private var versionTapCount: Int = 0
    @State private var devModeRevealed: Bool = DeveloperMode.isActive
    /// App language when Settings opened; drives the "restart required" footer.
    @State private var initialAppLanguage: String?
    @State private var artworkBytes: Int64?
    @State private var isClearingArtwork = false
    @State private var dataCacheBytes: Int64?
    @State private var isClearingDataCache = false
    #if os(macOS)
    @State private var macSelection: SettingsSection = .general
    @State private var macSearch: String = ""
    /// `isNavigatingHistory` suppresses recording when back/forward caused the change.
    @State private var history: [SettingsSection] = [.general]
    @State private var historyIndex: Int = 0
    @State private var isNavigatingHistory: Bool = false

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

    private var languageChanged: Bool {
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
    private var textSizePicker: some View {
        // `as Double` on every tag: SwiftUI infers some literals as Int and the
        // selection then silently never matches.
        Picker(selection: $configStore.fontScale) {
            Text("settings.default.button", bundle: .module).tag(1.0 as Double)
            Text("settings.larger.button", bundle: .module).tag(1.10 as Double)
            Text("settings.largest.button", bundle: .module).tag(1.20 as Double)
        } label: { Text("settings.textSize.button", bundle: .module) }
    }

    @ViewBuilder
    private var themePicker: some View {
        Picker(selection: $configStore.appearance) {
            Text("settings.system.button", bundle: .module).tag("system")
            Text("settings.light.button", bundle: .module).tag("light")
            Text("settings.dark.button", bundle: .module).tag("dark")
        } label: { Text("settings.theme.button", bundle: .module) }
    }

    @ViewBuilder
    private var aiSection: some View {
        Section {
            Toggle(isOn: $configStore.aiEnabled) { Text("settings.enableAi.button", bundle: .module) }
        } header: { Text("settings.assistant.button", bundle: .module) }
        if configStore.aiEnabled {
            Section {
                Picker(selection: $configStore.chatProvider) {
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
                    // A bare Form TextField hides its label once it has a value.
                    LabeledContent {
                        // Empty title: LabeledContent supplies the label; a second one renders twice.
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
                        ApiKeyTestButton(test: {
                            try await OpenAIProvider(config: configStore.openai).testConnection()
                        }, service: .openai)
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
        }
    }

    /// Under General, not AI: the TMDB key also powers cast strips and discovery.
    private var tmdbSection: some View {
        Section {
            SecureField(text: $configStore.tmdbApiKey,
                        prompt: Text(verbatim: "v4 Read Access Token")) {
                Text("settings.tmdbReadAccessToken.button", bundle: .module)
            }
            .apiKeyField()
            if !configStore.tmdbApiKey.isEmpty {
                ApiKeyTestButton(test: {
                    try await configStore.tmdbClient.testConnection()
                }, service: .tmdb)
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

    /// Prowlarr only names indexers for manual-search rows. No `ServiceKind`, so the
    /// fields are spelled out here, matching `ServiceFields`.
    @ViewBuilder
    private var prowlarrFields: some View {
        Toggle(isOn: $configStore.prowlarr.enabled) {
            Text("settings.enabled.button", bundle: .module)
        }
        if configStore.prowlarr.enabled {
            TextField(text: prowlarrURLBinding,
                      prompt: Text(verbatim: "http://192.168.1.10:9696")) {
                Text("settings.url.label", bundle: .module)
            }
            .urlField()
            SecureField(text: $configStore.prowlarr.apiKey,
                        prompt: Text("settings.pasteYourApiKey.button", bundle: .module)) {
                Text("settings.apiKey.button", bundle: .module)
            }
            .apiKeyField()
            if let reason = prowlarrIncompleteReason {
                Label {
                    Text(verbatim: reason)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if configStore.prowlarr.isConfigured {
                ApiKeyTestButton(test: { try await configStore.testProwlarr() },
                                 service: .prowlarr)
            }
        }
    }

    /// A URL pasted from Prowlarr's address bar carries a `#/…` route `URL(string:)` rejects.
    private var prowlarrURLBinding: Binding<String> {
        Binding(
            get: { configStore.prowlarr.baseURL },
            set: { configStore.prowlarr.baseURL = ServiceFields.sanitizedBaseURL($0) }
        )
    }

    private var prowlarrIncompleteReason: String? {
        guard configStore.prowlarr.enabled else { return nil }
        if !configStore.prowlarr.isConfigured {
            return String(localized: "settings.enterAValidUrl.tooltip", bundle: .module)
        }
        if configStore.prowlarr.apiKey.isEmpty {
            return String(localized: "settings.apiKeyIsRequired.tooltip", bundle: .module)
        }
        return nil
    }

    private var prowlarrRowLabel: some View {
        HStack(spacing: 10) {
            #if os(macOS)
            // Invisible grip keeps the leading edge aligned with the arr cards at any text size.
            Image(systemName: "line.3.horizontal")
                .scaledFont(size: 11)
                .hidden()
                .accessibilityHidden(true)
            #endif
            ServiceIcon(prowlarr: 18)
                .accessibilityHidden(true)
            Text(verbatim: "Prowlarr")
                .foregroundStyle(.primary)
            Spacer()
            if configStore.prowlarr.isConfigured {
                ConnectionStatusDot(service: .prowlarr)
            }
            #if os(macOS)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            #endif
        }
        .contentShape(Rectangle())
    }

    /// No brand asset ships for Prowlarr, so row and header share an SF Symbol.
    private var prowlarrHeader: some View {
        HStack(spacing: 6) {
            ServiceIcon(prowlarr: 12)
                .accessibilityHidden(true)
            Text(verbatim: "Prowlarr")
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

    /// Window-vibrant material so the custom sidebar matches a native one.
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


    private var macSidebarLayout: some View {
        // Hand-built columns: NavigationSplitView on macOS 26 insets the sidebar as a
        // floating glass card, stranding the traffic lights off it.
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
            // Clears the traffic lights.
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

    private var detailTopBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                // Icon-only buttons need explicit labels for VoiceOver.
                Button { goBack() } label: {
                    Image(systemName: "chevron.backward")
                        .frame(width: 30, height: 24)
                        .contentShape(Rectangle())
                }
                .disabled(!canGoBack)
                .help(Text("settings.back.button", bundle: .module))
                .accessibilityLabel(Text("settings.back.button", bundle: .module))
                Divider().frame(height: 15)
                Button { goForward() } label: {
                    Image(systemName: "chevron.forward")
                        .frame(width: 30, height: 24)
                        .contentShape(Rectangle())
                }
                .disabled(!canGoForward)
                .help(Text("settings.forward.button", bundle: .module))
                .accessibilityLabel(Text("settings.forward.button", bundle: .module))
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

    /// Maps an active service page back to its hub so the hub row stays highlighted.
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
        if case .prowlarr = section { return .mediaManagers }
        return section
    }

    private var sidebarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
                .accessibilityHidden(true)
            TextField(text: $macSearch) { Text("search.search.button", bundle: .module) }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !macSearch.isEmpty {
                Button { macSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search", bundle: .module))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.7))
        )
    }

    @ViewBuilder
    private var structuredSidebar: some View {
        Label { Text("settings.general.button", bundle: .module) } icon: { Image(systemName: "gearshape") }
            .tag(SettingsSection.general)
        Label { Text("settings.status.button", bundle: .module) } icon: { Image(systemName: "waveform.path.ecg") }
            .tag(SettingsSection.status)
        Label { Text("settings.mediaManagers.button", bundle: .module) } icon: { Image(systemName: "server.rack") }
            .tag(SettingsSection.mediaManagers)
        Label { Text("settings.downloadClients.button", bundle: .module) } icon: { Image(systemName: "arrow.down.circle") }
            .tag(SettingsSection.downloadClients)
        Label { Text("settings.mediaServer.label", bundle: .module) } icon: { Image(systemName: "play.tv") }
            .tag(SettingsSection.mediaServer)
        Label { Text("settings.assistant.button", bundle: .module) } icon: { Image(systemName: "sparkles") }
            .tag(SettingsSection.assistant)
        Label { Text("settings.quiz.label", bundle: .module) } icon: { Image(systemName: "rectangle.stack") }
            .tag(SettingsSection.quiz)
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

    private struct SidebarEntry: Identifiable {
        let section: SettingsSection
        let title: String
        let kind: ServiceKind?
        let systemImage: String
        var isProwlarr: Bool = false
        var id: SettingsSection { section }
    }

    private var sidebarEntries: [SidebarEntry] {
        var items: [SidebarEntry] = [
            .init(section: .general, title: String(localized: "settings.general.button", bundle: .module), kind: nil, systemImage: "gearshape"),
            .init(section: .status, title: String(localized: "settings.status.button", bundle: .module), kind: nil, systemImage: "waveform.path.ecg"),
            .init(section: .mediaManagers, title: String(localized: "settings.mediaManagers.button", bundle: .module), kind: nil, systemImage: "server.rack"),
            .init(section: .downloadClients, title: String(localized: "settings.downloadClients.button", bundle: .module), kind: nil, systemImage: "arrow.down.circle"),
        ]
        items += (mediaManagerSpecs + downloadClientSpecs).map {
            .init(section: .service($0.kind), title: $0.title, kind: $0.kind, systemImage: "")
        }
        items.append(.init(section: .prowlarr, title: "Prowlarr", kind: nil,
                           systemImage: "", isProwlarr: true))
        items += [
            .init(section: .mediaServer, title: String(localized: "settings.mediaServer.label", bundle: .module), kind: nil, systemImage: "play.tv"),
            .init(section: .assistant, title: String(localized: "settings.assistant.button", bundle: .module), kind: nil, systemImage: "sparkles"),
            .init(section: .quiz, title: String(localized: "settings.quiz.label", bundle: .module), kind: nil, systemImage: "rectangle.stack"),
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
            } else if entry.isProwlarr {
                ServiceIcon(prowlarr: 14)
            } else {
                Image(systemName: entry.systemImage)
            }
        }
        .accessibilityLabel(Text(verbatim: entry.title))
        .tag(entry.section)
    }

    // MARK: - Back/forward history

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex < history.count - 1 }

    private func recordHistory(_ section: SettingsSection) {
        if isNavigatingHistory { isNavigatingHistory = false; return }
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

    private func navTitle(for section: SettingsSection) -> Text {
        switch section {
        case .general: return Text("settings.general.button", bundle: .module)
        case .status: return Text("settings.status.button", bundle: .module)
        case .mediaManagers: return Text("settings.mediaManagers.button", bundle: .module)
        case .downloadClients: return Text("settings.downloadClients.button", bundle: .module)
        case .service(let kind): return Text(verbatim: kind.displayName)
        case .prowlarr: return Text(verbatim: "Prowlarr")
        case .mediaServer: return Text("settings.mediaServer.label", bundle: .module)
        case .assistant: return Text("settings.assistant.button", bundle: .module)
        case .quiz: return Text("settings.quiz.label", bundle: .module)
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
        case .status: ServerStatusView()
        case .mediaManagers: serviceHubPane(mediaManagerSpecs, locked: false, reorderable: true)
        case .downloadClients: serviceHubPane(downloadClientSpecs, locked: true)
        case .service(let kind): singleServicePane(for: kind)
        case .prowlarr: prowlarrPane
        case .mediaServer: MediaServerSettingsPane()
        case .assistant: aiPane
        case .quiz: QuizSettingsPane()
        case .mcp: MCPSettingsPane()
        case .icloud: ICloudSettingsView()
        case .siri: siriPane
        case .about: aboutPane
        }
    }

    /// Hub page: cards drill into a service page via `macSelection`. `reorderable`
    /// makes the card order the queue's section order.
    private func serviceHubPane(
        _ specs: [ServiceSpec],
        locked: Bool,
        reorderable: Bool = false
    ) -> some View {
        Form {
            Section {
                ForEach(reorderable ? orderedByQueueSections(specs) : specs) { spec in
                    Button {
                        macSelection = .service(spec.kind)
                    } label: {
                        HStack(spacing: 10) {
                            // Grip, brand mark and chevron are decoration; `.onMove` has its own VoiceOver affordance.
                            if reorderable {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.tertiary)
                                    .scaledFont(size: 11)
                                    .accessibilityHidden(true)
                            }
                            ServiceIcon(kind: spec.kind, size: 18)
                                .accessibilityHidden(true)
                            Text(verbatim: spec.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            // Live health dot, not a "configured" tick: a tick lies when the service is unreachable.
                            if spec.config.wrappedValue.isConfigured {
                                ConnectionStatusDot(service: .arr(spec.kind))
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onMove(perform: reorderable ? moveMediaManagers : nil)
                // Prowlarr sits outside the `ForEach`, so it has no grip and never reorders.
                if reorderable {
                    Button {
                        macSelection = .prowlarr
                    } label: {
                        prowlarrRowLabel
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                if reorderable {
                    Text("settings.dragToReorderQueue.footer", bundle: .module)
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

    private var prowlarrPane: some View {
        Form {
            Section {
                prowlarrFields
            } header: { prowlarrHeader }
        }
        .formStyle(.grouped)
    }

    private var siriPane: some View {
        Form {
            if #available(macOS 13.0, *) {
                SiriShortcutsSettingsContent()
            }
        }
        .formStyle(.grouped)
    }

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
                Link(destination: URL(string: "https://arrbarr.app/privacy")!) {
                    Label { Text("settings.privacyPolicy.button", bundle: .module) } icon: { Image(systemName: "hand.raised") }
                }
                Text(verbatim: "Made by 🥨")
                    .foregroundStyle(.secondary)
            } header: { Text("settings.about.button", bundle: .module) }
            // Plain rows, no glyphs: attribution, not actions.
            Section {
                Link(destination: URL(string: "https://dashboardicons.com")!) {
                    Text(verbatim: "Dashboard Icons — CC BY 4.0")
                }
                Link(destination: URL(string: "https://selfh.st/icons")!) {
                    Text(verbatim: "selfh.st Icons — CC BY 4.0")
                }
            } header: { Text("settings.acknowledgements.button", bundle: .module) } footer: {
                Text("settings.serviceIconsByDashboard.tooltip", bundle: .module)
            }
            // TMDB's terms require the mark and this disclaimer under their own row.
            // Verbatim: a licence notice, not UI copy.
            Section {
                Link(destination: URL(string: "https://www.themoviedb.org")!) {
                    Label {
                        Text(verbatim: "TMDB")
                    } icon: {
                        // `brand-tmdb` is a template asset and gets tinted; TMDB's mark must keep its colours.
                        Image("rating-tmdb", bundle: .module)
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    }
                }
            } footer: {
                Text(verbatim: "This product uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.")
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
    private var iOSCombinedForm: some View {
        List {
            iosSettingsLink("settings.general.button", systemImage: "gearshape") { iosGeneralForm }
            iosSettingsLink("settings.status.button", systemImage: "waveform.path.ecg") { ServerStatusView() }
            iosSettingsLink("Media managers", systemImage: "server.rack") { iosMediaManagersForm }
            iosSettingsLink("Download clients", systemImage: "arrow.down.circle") { iosDownloadClientsForm }
            iosSettingsLink("settings.mediaServer.label", systemImage: "play.tv") { MediaServerSettingsPane() }
            iosSettingsLink("settings.assistant.button", systemImage: "sparkles") { iosAIForm }
            iosSettingsLink("settings.quiz.label", systemImage: "rectangle.stack") { QuizSettingsPane() }
            if AppCapabilities.isAppStore {
                iosSettingsLink("iCloud", systemImage: "icloud") { ICloudSettingsView() }
            }
            iosSettingsLink("settings.siriShortcuts.button", systemImage: "mic.fill") { iosSiriForm }
            iosSettingsLink("settings.about.button", systemImage: "info.circle") { iosAboutForm }
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
                    .accessibilityHidden(true)
                Text(verbatim: title)
                Spacer()
                if configured {
                    ConnectionStatusDot(service: .arr(kind))
                }
            }
        }
    }

    private var iosMediaManagersForm: some View {
        iosServiceList(mediaManagerSpecs, title: "Media managers", reorderable: true)
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

    /// Media managers are `reorderable` (section order); `.onMove` needs edit mode
    /// on iOS, hence the EditButton.
    private func iosServiceList(_ specs: [ServiceSpec], title: LocalizedStringKey,
                                reorderable: Bool = false) -> some View {
        List {
            Section {
                ForEach(reorderable ? orderedByQueueSections(specs) : specs) { spec in
                    iosServiceLink(kind: spec.kind, title: spec.title,
                                   configured: spec.config.wrappedValue.isConfigured) {
                        serviceFields(spec)
                    }
                }
                .onMove(perform: reorderable ? moveMediaManagers : nil)
                // Outside the `ForEach`: Prowlarr is no queue source, nothing to reorder against.
                if reorderable {
                    NavigationLink {
                        Form { Section { prowlarrFields } }
                            .navigationTitle(Text(verbatim: "Prowlarr"))
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        prowlarrRowLabel
                    }
                }
            } footer: {
                if reorderable {
                    Text("settings.dragToReorderQueue.footer", bundle: .module)
                }
            }
        }
        .navigationTitle(Text(title, bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if reorderable {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
    }

    private var iosAIForm: some View {
        Form { aiSection }
            .navigationTitle(Text("settings.assistant.button", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
    }

    private var iosGeneralForm: some View {
        Form {
            // No language picker on iOS: ConfigStore forces "system".
            queueGroupingSection
            upcomingSection
            needsYouSection
            tmdbSection
            storageSection
            // No theme, warnings or refresh-interval controls on iOS: ConfigStore forces them.
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
                // 7 taps reveal Developer options. LabeledContent swallows gestures inside
                // Form, so a Button styled as a row.
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
                Link(destination: URL(string: "https://arrbarr.app/privacy")!) {
                    Label { Text("settings.privacyPolicy.button", bundle: .module) } icon: { Image(systemName: "hand.raised") }
                }
                Text(verbatim: "Made by 🥨")
                    .foregroundStyle(.secondary)
            } header: { Text("settings.about.button", bundle: .module) }
            // Plain rows, no glyphs: attribution, not actions.
            Section {
                Link(destination: URL(string: "https://dashboardicons.com")!) {
                    Text(verbatim: "Dashboard Icons — CC BY 4.0")
                }
                Link(destination: URL(string: "https://selfh.st/icons")!) {
                    Text(verbatim: "selfh.st Icons — CC BY 4.0")
                }
            } header: { Text("settings.acknowledgements.button", bundle: .module) } footer: {
                Text("settings.serviceIconsByDashboard.tooltip", bundle: .module)
            }
            // TMDB's terms require the mark and this disclaimer under their own row.
            // Verbatim: a licence notice, not UI copy.
            Section {
                Link(destination: URL(string: "https://www.themoviedb.org")!) {
                    Label {
                        Text(verbatim: "TMDB")
                    } icon: {
                        // `brand-tmdb` is a template asset and gets tinted; TMDB's mark must keep its colours.
                        Image("rating-tmdb", bundle: .module)
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    }
                }
            } footer: {
                Text(verbatim: "This product uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.")
            }
        }
        .navigationTitle(Text("settings.about.button", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
    }
    #endif

    /// Callers wrap this: macOS gates on `DeveloperMode.isActive`, iOS on `devModeRevealed`.
    @ViewBuilder
    private var demoModeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { demoModeOn },
                set: { newValue in
                    guard newValue != demoModeOn else { return }
                    // Ask before flipping local state so a cancelled relaunch keeps the toggle in sync.
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
            Button { telemetryReport = configStore.gateway.telemetry.report() } label: { Text("settings.mediaKitTelemetry.button", bundle: .module) }
        } header: { Text("settings.developerOptions.button", bundle: .module) }
        .sheet(isPresented: Binding(get: { telemetryReport != nil }, set: { if !$0 { telemetryReport = nil } })) {
            VStack(alignment: .trailing, spacing: 12) {
                ScrollView {
                    Text(telemetryReport ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { telemetryReport = nil } label: { Text("common.done.button", bundle: .module) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            .frame(minWidth: 560, minHeight: 380)
        }
    }

    // MARK: - Service roster (shared data)

    /// Shared roster for macOS panes and iOS forms; only the chrome differs.
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

    private func serviceFields(_ spec: ServiceSpec) -> some View {
        ServiceFields(config: spec.config, kind: spec.kind,
                      notifyBinding: spec.notify,
                      ageConfirmedBinding: spec.ageConfirmed,
                      nsfwFilterBinding: spec.nsfwFilter)
    }

    // MARK: - Panes

    @ViewBuilder
    private func serviceSectionHeader(_ kind: ServiceKind, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            ServiceIcon(kind: kind, size: 12)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title, bundle: .module)
        }
    }

    private var generalPane: some View {
        Form {
            Section {
                Toggle(isOn: $configStore.launchAtLogin) { Text("settings.launchAtLogin.button", bundle: .module) }
                #if os(macOS)
                Picker(selection: $configStore.detachedWindow) {
                    Text("settings.interfaceMode.menuBar", bundle: .module).tag(false)
                    Text("settings.interfaceMode.window", bundle: .module).tag(true)
                } label: { Text("settings.interfaceMode.label", bundle: .module) }
                #endif
                Picker(selection: $configStore.appLanguage) {
                    ForEach(ConfigStore.appLanguageOptions, id: \.code) { opt in
                        Text(LocalizedStringKey(opt.label)).tag(opt.code)
                    }
                } label: { Text("settings.language.button", bundle: .module) }
                themePicker
                textSizePicker
                notificationSoundPicker
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
            // Section order is dragged on the Media-managers page.
            queueGroupingSection
            upcomingSection
            needsYouSection
            tmdbSection
            storageSection
            // No refresh-interval pickers: both intervals are hard-locked (see `ConfigStore.foregroundInterval`).
        }
        .formStyle(.grouped)
    }

    /// macOS only: iOS cannot enumerate `/System/Library/Sounds`.
    @ViewBuilder
    private var notificationSoundPicker: some View {
        #if os(macOS)
        // Play acts on the popup's value, so it sits beside the popup via LabeledContent.
        LabeledContent {
            HStack(spacing: 6) {
                Button { Self.previewSound(named: configStore.notificationSoundName) } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                // "Default" is whatever the system picks at delivery time.
                .disabled(configStore.notificationSoundName.isEmpty
                          || configStore.notificationSoundName == ConfigStore.silentSoundName)
                .help(Text("settings.play.button", bundle: .module))
                .accessibilityLabel(Text("settings.play.button", bundle: .module))

                Picker(selection: $configStore.notificationSoundName) {
                    Text("settings.default.button", bundle: .module).tag("")
                    Text("search.none.button", bundle: .module).tag(ConfigStore.silentSoundName)
                    Divider()
                    ForEach(Self.systemSoundNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
            }
        } label: {
            Text("settings.notificationSound.button", bundle: .module)
        }
        .onChange(of: configStore.notificationSoundName) { _, newValue in
            Self.previewSound(named: newValue)
        }
        #endif
    }

    #if os(macOS)
    /// Names that `NSSound(named:)` and `UNNotificationSound(named: "<name>.aiff")` resolve.
    private static let systemSoundNames: [String] = {
        let dir = "/System/Library/Sounds"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files
            .filter { $0.hasSuffix(".aiff") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }()

    private static func previewSound(named name: String) {
        guard !name.isEmpty, name != ConfigStore.silentSoundName else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
    #endif

    // MARK: - Queue sections

    /// One picker is both the on/off switch and the default disclosure state.
    private var queueGroupingSection: some View {
        Section {
            Picker(selection: $queueUI.queueTitleGrouping) {
                Text("settings.queueGrouping.off.option", bundle: .module)
                    .tag(QueueTitleGroupingMode.off)
                Text("settings.queueGrouping.collapsed.option", bundle: .module)
                    .tag(QueueTitleGroupingMode.collapsed)
                Text("settings.queueGrouping.expanded.option", bundle: .module)
                    .tag(QueueTitleGroupingMode.expanded)
            } label: { Text("settings.queueGrouping.label", bundle: .module) }
        } header: { Text("Queue", bundle: .module) }
    }

    /// One switch: the window is hard-locked to 7 days.
    private var upcomingSection: some View {
        Section {
            Toggle(isOn: $configStore.showTonight) {
                Text("settings.showUpcomingInQueue.label", bundle: .module)
            }
            Picker(selection: $configStore.tonightVisibleCount) {
                ForEach(ConfigStore.tonightVisibleOptions, id: \.self) { option in
                    if option == 0 {
                        Text("search.all.button", bundle: .module).tag(0)
                    } else {
                        Text(verbatim: "\(option)").tag(option)
                    }
                }
            } label: {
                Text("settings.upcomingVisibleCount.label", bundle: .module)
            }
            .disabled(!configStore.showTonight)
        } header: { Text("Upcoming", bundle: .module) }
    }

    @ViewBuilder
    private var storageSection: some View {
        Section {
            LabeledContent {
                if let artworkBytes {
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: artworkBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            } label: {
                Text("settings.imageCache.label", bundle: .module)
            }
            Button {
                clearArtworkCache()
            } label: {
                Label { Text("settings.clearImageCache.button", bundle: .module) } icon: { Image(systemName: "trash") }
            }
            .disabled(isClearingArtwork || (artworkBytes ?? 0) == 0)
            LabeledContent {
                if let dataCacheBytes {
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: dataCacheBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            } label: {
                Text("settings.dataCache.label", bundle: .module)
            }
            Button {
                clearDataCache()
            } label: {
                Label { Text("settings.clearDataCache.button", bundle: .module) } icon: { Image(systemName: "trash") }
            }
            .disabled(isClearingDataCache || (dataCacheBytes ?? 0) == 0)
        } header: {
            Text("settings.storage.label", bundle: .module)
        }
    }

    private func refreshArtworkBytes() {
        Task { artworkBytes = await AppCaches.artworkBytes() }
    }

    private func refreshDataCacheBytes() {
        Task { dataCacheBytes = await configStore.gateway.dataCacheBytes() }
    }

    private func clearDataCache() {
        isClearingDataCache = true
        Task {
            await configStore.gateway.purgeDataCache()
            dataCacheBytes = await configStore.gateway.dataCacheBytes()
            isClearingDataCache = false
        }
    }

    private func clearArtworkCache() {
        isClearingArtwork = true
        Task {
            await AppCaches.clearArtwork()
            // The icon tier backs the Spotlight index; restore its thumbnails now.
            SpotlightIndexer.reindex(configStore: configStore)
            artworkBytes = await AppCaches.artworkBytes()
            isClearingArtwork = false
        }
    }

    /// Only the severity picker depends on the section being visible, so only it
    /// is disabled with it.
    @ViewBuilder
    private var needsYouSection: some View {
        Section {
            Toggle(isOn: $configStore.showNeedsYou) {
                Text("settings.showSection.label", bundle: .module)
            }
            // iOS is errors-only: ConfigStore forces showWarnings off on every load.
            #if os(macOS)
            Picker(selection: $configStore.showWarnings) {
                Text("settings.errorsOnly.option", bundle: .module).tag(false)
                Text("settings.errorsAndWarnings.option", bundle: .module).tag(true)
            } label: { Text("settings.needsYouSeverity.label", bundle: .module) }
                .disabled(!configStore.showNeedsYou)
            #endif
            Toggle(isOn: $configStore.notifyHealth) {
                Text("settings.notifyHealth.label", bundle: .module)
            }
        } header: { Text("Needs you", bundle: .module) }
    }

    /// `arrOrder` also carries Upcoming / Needs you; those are filtered out here.
    private func orderedByQueueSections(_ specs: [ServiceSpec]) -> [ServiceSpec] {
        let ranked = configStore.arrOrder.compactMap { key in specs.first { $0.kind.rawValue == key } }
        let rankedKinds = Set(ranked.map(\.kind))
        return ranked + specs.filter { !rankedKinds.contains($0.kind) }
    }

    /// Permutes arrs only among arr slots, so Upcoming and Needs you keep their place.
    private func moveMediaManagers(from source: IndexSet, to destination: Int) {
        var order = configStore.arrOrder
        let slots = order.indices.filter { QueueItem.Source(rawValue: order[$0]) != nil }
        var keys = slots.map { order[$0] }
        keys.move(fromOffsets: source, toOffset: destination)
        for (slot, key) in zip(slots, keys) { order[slot] = key }
        configStore.arrOrder = order
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return short == build ? "v\(short)" : "v\(short) (\(build))"
    }


}

/// Internal: the media-server pane in another file uses it.
struct ProLockOverlay: View {
    @ObservedObject private var store = StoreManager.shared
    let feature: ProFeature
    var body: some View {
        ZStack {
            Color.black.opacity(0.04)
            VStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.title2).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
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
