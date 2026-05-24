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
    @State private var draggingKey: String?
    @State private var dragOffset: CGFloat = 0
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
                    usenetPane
                        .tabItem { Label { Text("Usenet", bundle: .module) } icon: { Image(systemName: "doc.zipper") } }
                    torrentsPane
                        .tabItem { Label { Text("Torrents", bundle: .module) } icon: { Image(systemName: "arrow.triangle.2.circlepath") } }
                    aiPane
                        .tabItem { Label { Text("AI", bundle: .module) } icon: { Image(systemName: "sparkles") } }
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
        .onAppear {
            if initialAppLanguage == nil { initialAppLanguage = configStore.appLanguage }
        }
    }

    /// Section content for the language picker. Shared between the macOS
    /// General pane and the iOS combined form so the "restart required"
    /// affordance behaves identically on both platforms.
    @ViewBuilder
    private var languageSection: some View {
        Section {
            Picker(selection: $configStore.appLanguage) {
                ForEach(ConfigStore.appLanguageOptions, id: \.code) { opt in
                    Text(LocalizedStringKey(opt.label)).tag(opt.code)
                }
            } label: { Text("Language", bundle: .module) }
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
    }

    /// Shared "AI" section. One master toggle at the top kills the whole
    /// feature; provider controls only appear when AI is on.
    @ViewBuilder
    private var aiSection: some View {
        Section {
            Toggle(isOn: $configStore.aiEnabled) { Text("Enable AI", bundle: .module) }
        } header: { Text("AI", bundle: .module) }
        if configStore.aiEnabled {
            Section {
                Picker(selection: $configStore.chatProvider) {
                    ForEach(ChatProvider.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                } label: { Text("AI provider", bundle: .module) }
                if configStore.chatProvider == .openai {
                    TextField("API base URL", text: $configStore.openai.baseURL,
                              prompt: Text(verbatim: "https://api.openai.com/v1"))
                    SecureField(text: $configStore.openai.apiKey) { Text("API key", bundle: .module) }
                    TextField("Model", text: $configStore.openai.model,
                              prompt: Text(verbatim: "gpt-4o-mini"))
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
            } header: { Text("Model", bundle: .module) }
            Section {
                SecureField("TMDB API key", text: $configStore.tmdbApiKey,
                            prompt: Text(verbatim: "v3 read key"))
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
    private var iOSCombinedForm: some View {
        Form {
            Section {
                ServiceFields(config: $configStore.radarr, kind: .radarr,
                              notifyBinding: $configStore.notifyRadarr)
            } header: { Text("Radarr", bundle: .module) }
            Section {
                ServiceFields(config: $configStore.sonarr, kind: .sonarr,
                              notifyBinding: $configStore.notifySonarr)
            } header: { Text("Sonarr", bundle: .module) }
            Section {
                ServiceFields(config: $configStore.lidarr, kind: .lidarr,
                              notifyBinding: $configStore.notifyLidarr)
            } header: { Text("Lidarr", bundle: .module) }
            Section {
                ServiceFields(config: $configStore.whisparr, kind: .whisparr)
                if configStore.whisparr.enabled {
                    Toggle(isOn: $configStore.blurWhisparrPosters) { Text("Blur posters #nsfw", bundle: .module) }
                }
            } header: { Text("Whisparr", bundle: .module) }
            Section {
                ServiceFields(config: $configStore.sabnzbd, kind: .sabnzbd)
            } header: { Text("SABnzbd", bundle: .module) }
            Section {
                ServiceFields(config: $configStore.nzbget, kind: .nzbget)
            } header: { Text("NZBGet", bundle: .module) }
            Section {
                ServiceFields(config: $configStore.qbittorrent, kind: .qbittorrent)
            } header: { Text("qBittorrent", bundle: .module) }
            Section {
                ServiceFields(config: $configStore.transmission, kind: .transmission)
            } header: { Text("Transmission", bundle: .module) }
            Section {
                ServiceFields(config: $configStore.rtorrent, kind: .rtorrent)
            } header: { Text("rTorrent", bundle: .module) }
            Section {
                ServiceFields(config: $configStore.deluge, kind: .deluge)
            } header: { Text("Deluge", bundle: .module) }
            languageSection
            Section {
                ForEach(configStore.arrOrder, id: \.self) { key in
                    arrOrderRow(key: key)
                }
            } header: { Text("Section order", bundle: .module) }
            Section {
                Toggle(isOn: $configStore.showIndexerIssues) { Text("Show indexer issues warning", bundle: .module) }
                // "Upcoming window" picker removed — banner is now
                // hard-locked to 7 days.
            } header: { Text("Display", bundle: .module) }
            Section {
                // iOS only: foreground (= "while app is open") interval.
                // Background polling is gone here — iOS suspends apps shortly
                // after backgrounding so a periodic timer can't survive.
                Picker(selection: $configStore.foregroundInterval) {
                    ForEach(ConfigStore.foregroundIntervalOptions, id: \.self) { interval in
                        Text(Self.formatInterval(interval)).tag(interval)
                    }
                } label: { Text("While open", bundle: .module) }
            } header: { Text("Refresh", bundle: .module) }
            aiSection
            if devModeRevealed {
                Section {
                    Toggle("Demo mode", isOn: Binding(
                        get: { demoModeOn },
                        set: { newValue in
                            guard newValue != demoModeOn else { return }
                            let committed = onSetDemoMode?(newValue) ?? false
                            if committed { demoModeOn = newValue }
                        }
                    ))
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
                    Label { Text("GitHub", bundle: .module) } icon: { Image(systemName: "link") }
                }
                Text(verbatim: "Made with 🥨")
                    .foregroundStyle(.secondary)
            } header: { Text("About", bundle: .module) }
        }
    }
    #endif

    // MARK: - Panes

    private var mediaManagersPane: some View {
        Form {
            Section {
                ServiceFields(config: $configStore.radarr, kind: .radarr,
                              notifyBinding: $configStore.notifyRadarr)
            } header: { Text("Radarr", bundle: .module) }
            Section {
                ServiceFields(config: $configStore.sonarr, kind: .sonarr,
                              notifyBinding: $configStore.notifySonarr)
            } header: { Text("Sonarr", bundle: .module) }
            Section {
                ServiceFields(config: $configStore.lidarr, kind: .lidarr,
                              notifyBinding: $configStore.notifyLidarr)
            } header: { Text("Lidarr", bundle: .module) }
            Section {
                ServiceFields(config: $configStore.whisparr, kind: .whisparr)
                if configStore.whisparr.enabled {
                    Toggle(isOn: $configStore.blurWhisparrPosters) { Text("Blur posters #nsfw", bundle: .module) }
                }
            } header: { Text("Whisparr", bundle: .module) }
        }
        .formStyle(.grouped)
    }

    private var usenetPane: some View {
        Form {
            Section {
                ServiceFields(config: $configStore.sabnzbd, kind: .sabnzbd)
            } header: { Text("SABnzbd", bundle: .module) }
            Section {
                ServiceFields(config: $configStore.nzbget, kind: .nzbget)
            } header: { Text("NZBGet", bundle: .module) }
        }
        .formStyle(.grouped)
    }

    private var torrentsPane: some View {
        Form {
            Section {
                ServiceFields(config: $configStore.qbittorrent, kind: .qbittorrent)
            } header: { Text("qBittorrent", bundle: .module) }
            Section {
                ServiceFields(config: $configStore.transmission, kind: .transmission)
            } header: { Text("Transmission", bundle: .module) }
            Section {
                ServiceFields(config: $configStore.rtorrent, kind: .rtorrent)
            } header: { Text("rTorrent", bundle: .module) }
            Section {
                ServiceFields(config: $configStore.deluge, kind: .deluge)
            } header: { Text("Deluge", bundle: .module) }
        }
        .formStyle(.grouped)
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
                    HStack(spacing: 8) {
                        Text("Restart required to apply the new language.", bundle: .module)
                        Button { relaunchApp() } label: { Text("Relaunch", bundle: .module) }
                            .controlSize(.small)
                    }
                }
            }
            Section {
                ForEach(configStore.arrOrder, id: \.self) { key in
                    arrOrderRow(key: key)
                }
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
                Section {
                    Toggle("Demo mode", isOn: Binding(
                        get: { demoModeOn },
                        set: { newValue in
                            guard newValue != demoModeOn else { return }
                            // Confirm via the callback BEFORE flipping local
                            // state — if the user cancels the relaunch, the
                            // toggle stays in sync with reality.
                            let committed = onSetDemoMode?(newValue) ?? false
                            if committed { demoModeOn = newValue }
                        }
                    ))
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
        }
        .formStyle(.grouped)
    }

    private static let arrRowHeight: CGFloat = 24

    @ViewBuilder
    private func arrOrderRow(key: String) -> some View {
        if let spec = orderRowSpec(for: key) {
            let isDragging = draggingKey == key
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 11))
                Image(systemName: spec.symbol)
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
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isDragging ? Color.primary.opacity(0.08) : .clear)
                    .padding(.horizontal, -6)
            )
            .offset(y: isDragging ? dragOffset : 0)
            .zIndex(isDragging ? 1 : 0)
            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.85), value: configStore.arrOrder)
            .gesture(arrDragGesture(key: key))
        }
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

    private func arrDragGesture(key: String) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if draggingKey != key { draggingKey = key }
                dragOffset = value.translation.height

                guard let from = configStore.arrOrder.firstIndex(of: key) else { return }
                let steps = Int((dragOffset / Self.arrRowHeight).rounded())
                let target = max(0, min(configStore.arrOrder.count - 1, from + steps))
                if target != from {
                    var newOrder = configStore.arrOrder
                    let item = newOrder.remove(at: from)
                    newOrder.insert(item, at: target)
                    configStore.arrOrder = newOrder
                    dragOffset -= CGFloat(target - from) * Self.arrRowHeight
                }
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    draggingKey = nil
                    dragOffset = 0
                }
            }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(Self.versionString)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .help("ArrBarr \(Self.versionString)")
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(verbatim: "Made with 🥨")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Link(destination: URL(string: "https://github.com/Preclowski/ArrBarr")!) {
                    HStack(spacing: 3) {
                        Image(systemName: "link")
                            .font(.system(size: 10, weight: .semibold))
                        Text(verbatim: "GitHub")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                #endif
                .help(Text("github.com/Preclowski/ArrBarr", bundle: .module))
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
            return String(localized: "Never")
        } else if seconds < 60 {
            return "\(Int(seconds))s"
        } else {
            return "\(Int(seconds) / 60)m"
        }
    }

    private static func formatTonight(hours: Int) -> String {
        if hours < 24 {
            return String(format: String(localized: "%lld hours"), hours)
        }
        let days = hours / 24
        if days == 1 { return String(localized: "24 hours") }
        return String(format: String(localized: "%lld days"), days)
    }
}

private struct ServiceFields: View {
    @Binding var config: ServiceConfig
    let kind: ServiceKind
    var notifyBinding: Binding<Bool>? = nil

    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    public var body: some View {
        Toggle("Enabled", isOn: $config.enabled.animation())

        if config.enabled, let notifyBinding {
            Toggle("Notify on new grabs", isOn: notifyBinding)
        }

        if config.enabled {
            TextField("URL", text: $config.baseURL, prompt: Text(kind.urlPlaceholder))
                .autocorrectionDisabled(true)

            if kind.requiresApiKey {
                SecureField("API Key", text: $config.apiKey, prompt: Text("Paste your API key", bundle: .module))
            }

            if kind.requiresLogin {
                TextField("Username", text: $config.username, prompt: Text("admin", bundle: .module))
                    .autocorrectionDisabled(true)
                SecureField("Password", text: $config.password, prompt: Text("Password", bundle: .module))
            }

            HStack(spacing: 8) {
                Button { runTest() } label: { Text("Test Connection", bundle: .module) }
                    .modifier(GlassButtonStyle())
                    .controlSize(.small)
                    .disabled(testState == .testing || !config.isConfigured)

                switch testState {
                case .idle:
                    EmptyView()
                case .testing:
                    ProgressView().controlSize(.small)
                case .success(let msg):
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                case .failure(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(msg)
                }
            }
            .onChange(of: config) { _, _ in
                if testState != .idle && testState != .testing { testState = .idle }
            }
        }
    }

    private func runTest() {
        testState = .testing
        let snapshot = config
        let kind = self.kind
        Task {
            do {
                let result = try await ConnectionTester.test(kind: kind, config: snapshot)
                await MainActor.run { testState = .success(result) }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { testState = .failure(message) }
            }
        }
    }
}

private enum ConnectionTester {
    static func test(kind: ServiceKind, config: ServiceConfig) async throws -> String {
        switch kind {
        case .radarr:       return try await RadarrClient(config: config).testConnection()
        case .sonarr:       return try await SonarrClient(config: config).testConnection()
        case .lidarr:       return try await LidarrClient(config: config).testConnection()
        case .whisparr:     return try await WhisparrClient(config: config).testConnection()
        case .sabnzbd:      return try await SabnzbdClient(config: config).testConnection()
        case .nzbget:       return try await NzbgetClient(config: config).testConnection()
        case .qbittorrent:  return try await QbittorrentClient(config: config).testConnection()
        case .transmission: return try await TransmissionClient(config: config).testConnection()
        case .rtorrent:     return try await RtorrentClient(config: config).testConnection()
        case .deluge:       return try await DelugeClient(config: config).testConnection()
        }
    }
}
