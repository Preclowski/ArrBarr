import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var configStore: ConfigStore
    @State private var draftRadarr: ServiceConfig = .empty
    @State private var draftSonarr: ServiceConfig = .empty
    @State private var draftLidarr: ServiceConfig = .empty
    @State private var draftSabnzbd: ServiceConfig = .empty
    @State private var draftQbittorrent: ServiceConfig = .empty
    @State private var draftNzbget: ServiceConfig = .empty
    @State private var draftTransmission: ServiceConfig = .empty
    @State private var draftRtorrent: ServiceConfig = .empty
    @State private var draftDeluge: ServiceConfig = .empty
    @State private var draftForegroundInterval: TimeInterval = 5
    @State private var draftBackgroundInterval: TimeInterval = 30
    @State private var draftNotifyRadarr = false
    @State private var draftNotifySonarr = false
    @State private var draftNotifyLidarr = false
    @State private var draftLaunchAtLogin = false
    @State private var draftAppLanguage: String = "system"
    @State private var draftArrOrder: [String] = ConfigStore.defaultArrOrder
    @State private var showUnsavedAlert = false
    @State private var draggingKey: String?
    @State private var dragOffset: CGFloat = 0

    private var hasChanges: Bool {
        draftRadarr != configStore.radarr
        || draftSonarr != configStore.sonarr
        || draftLidarr != configStore.lidarr
        || draftSabnzbd != configStore.sabnzbd
        || draftQbittorrent != configStore.qbittorrent
        || draftNzbget != configStore.nzbget
        || draftTransmission != configStore.transmission
        || draftRtorrent != configStore.rtorrent
        || draftDeluge != configStore.deluge
        || draftForegroundInterval != configStore.foregroundInterval
        || draftBackgroundInterval != configStore.backgroundInterval
        || draftNotifyRadarr != configStore.notifyRadarr
        || draftNotifySonarr != configStore.notifySonarr
        || draftNotifyLidarr != configStore.notifyLidarr
        || draftLaunchAtLogin != configStore.launchAtLogin
        || draftAppLanguage != configStore.appLanguage
        || draftArrOrder != configStore.arrOrder
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalPane
                    .tabItem { Label("General", systemImage: "gearshape") }
                mediaManagersPane
                    .tabItem { Label("Media Managers", systemImage: "server.rack") }
                usenetPane
                    .tabItem { Label("Usenet", systemImage: "doc.zipper") }
                torrentsPane
                    .tabItem { Label("Torrents", systemImage: "arrow.triangle.2.circlepath") }
            }

            bottomBar
        }
        .environment(\.locale, configStore.currentLocale)
        .onAppear { loadDrafts() }
        .alert("Unsaved Changes", isPresented: $showUnsavedAlert) {
            Button("Save", role: nil) { save(); closeSettingsWindow() }
            Button("Don't Save", role: .destructive) { closeSettingsWindow() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Do you want to save your changes before closing?")
        }
    }

    // MARK: - Panes

    private var mediaManagersPane: some View {
        Form {
            Section("Radarr") {
                ServiceFields(config: $draftRadarr, kind: .radarr)
            }
            Section("Sonarr") {
                ServiceFields(config: $draftSonarr, kind: .sonarr)
            }
            Section("Lidarr") {
                ServiceFields(config: $draftLidarr, kind: .lidarr)
            }
        }
        .formStyle(.grouped)
    }

    private var usenetPane: some View {
        Form {
            Section("SABnzbd") {
                ServiceFields(config: $draftSabnzbd, kind: .sabnzbd)
            }
            Section("NZBGet") {
                ServiceFields(config: $draftNzbget, kind: .nzbget)
            }
        }
        .formStyle(.grouped)
    }

    private var torrentsPane: some View {
        Form {
            Section("qBittorrent") {
                ServiceFields(config: $draftQbittorrent, kind: .qbittorrent)
            }
            Section("Transmission") {
                ServiceFields(config: $draftTransmission, kind: .transmission)
            }
            Section("rTorrent") {
                ServiceFields(config: $draftRtorrent, kind: .rtorrent)
            }
            Section("Deluge") {
                ServiceFields(config: $draftDeluge, kind: .deluge)
            }
        }
        .formStyle(.grouped)
    }

    private var generalPane: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $draftLaunchAtLogin)
            }
            Section("Language") {
                Picker("Language", selection: $draftAppLanguage) {
                    ForEach(ConfigStore.appLanguageOptions, id: \.code) { opt in
                        Text(LocalizedStringKey(opt.label)).tag(opt.code)
                    }
                }
            }
            Section("Refresh Interval") {
                Picker("Popover open", selection: $draftForegroundInterval) {
                    ForEach(ConfigStore.foregroundIntervalOptions, id: \.self) { interval in
                        Text(Self.formatInterval(interval)).tag(interval)
                    }
                }
                Picker("Background", selection: $draftBackgroundInterval) {
                    ForEach(ConfigStore.backgroundIntervalOptions, id: \.self) { interval in
                        Text(Self.formatInterval(interval)).tag(interval)
                    }
                }
            }
            Section("Section order") {
                ForEach(draftArrOrder, id: \.self) { key in
                    arrOrderRow(key: key)
                }
            }
            Section("Notifications") {
                Toggle("Radarr", isOn: $draftNotifyRadarr)
                Toggle("Sonarr", isOn: $draftNotifySonarr)
                Toggle("Lidarr", isOn: $draftNotifyLidarr)
            }
        }
        .formStyle(.grouped)
    }

    private static let arrRowHeight: CGFloat = 24

    @ViewBuilder
    private func arrOrderRow(key: String) -> some View {
        if let source = QueueItem.Source(rawValue: key) {
            let isDragging = draggingKey == key
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 11))
                Image(systemName: source.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(source.displayName)
                Spacer()
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
            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.85), value: draftArrOrder)
            .gesture(arrDragGesture(key: key))
        }
    }

    private func arrDragGesture(key: String) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if draggingKey != key { draggingKey = key }
                dragOffset = value.translation.height

                guard let from = draftArrOrder.firstIndex(of: key) else { return }
                let steps = Int((dragOffset / Self.arrRowHeight).rounded())
                let target = max(0, min(draftArrOrder.count - 1, from + steps))
                if target != from {
                    var newOrder = draftArrOrder
                    let item = newOrder.remove(at: from)
                    newOrder.insert(item, at: target)
                    draftArrOrder = newOrder
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
            Divider()
            HStack {
                Text(Self.versionString)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .help("ArrBarr \(Self.versionString)")
                Spacer()
                let showSave = hasChanges || draggingKey != nil
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .modifier(GlassProminentButtonStyle())
                    .controlSize(.large)
                    .disabled(!showSave)
                    .opacity(showSave ? 1 : 0)
                    .allowsHitTesting(showSave)
                Button("Close") {
                    if hasChanges {
                        showUnsavedAlert = true
                    } else {
                        NSApp.keyWindow?.close()
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                .modifier(GlassButtonStyle())
                .controlSize(.large)
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

    // MARK: - Helpers

    private func save() {
        configStore.radarr = draftRadarr
        configStore.sonarr = draftSonarr
        configStore.lidarr = draftLidarr
        configStore.sabnzbd = draftSabnzbd
        configStore.qbittorrent = draftQbittorrent
        configStore.nzbget = draftNzbget
        configStore.transmission = draftTransmission
        configStore.rtorrent = draftRtorrent
        configStore.deluge = draftDeluge
        configStore.foregroundInterval = draftForegroundInterval
        configStore.backgroundInterval = draftBackgroundInterval
        configStore.notifyRadarr = draftNotifyRadarr
        configStore.notifySonarr = draftNotifySonarr
        configStore.notifyLidarr = draftNotifyLidarr
        configStore.launchAtLogin = draftLaunchAtLogin
        configStore.appLanguage = draftAppLanguage
        configStore.arrOrder = draftArrOrder
    }

    private func closeSettingsWindow() {
        let title = String(localized: "ArrBarr Settings")
        DispatchQueue.main.async {
            if let win = NSApp.windows.first(where: { $0.title == title }) {
                win.close()
            } else {
                NSApp.keyWindow?.close()
            }
        }
    }

    private func loadDrafts() {
        draftRadarr = configStore.radarr
        draftSonarr = configStore.sonarr
        draftLidarr = configStore.lidarr
        draftSabnzbd = configStore.sabnzbd
        draftQbittorrent = configStore.qbittorrent
        draftNzbget = configStore.nzbget
        draftTransmission = configStore.transmission
        draftRtorrent = configStore.rtorrent
        draftDeluge = configStore.deluge
        draftForegroundInterval = configStore.foregroundInterval
        draftBackgroundInterval = configStore.backgroundInterval
        draftNotifyRadarr = configStore.notifyRadarr
        draftNotifySonarr = configStore.notifySonarr
        draftNotifyLidarr = configStore.notifyLidarr
        draftLaunchAtLogin = configStore.launchAtLogin
        draftAppLanguage = configStore.appLanguage
        draftArrOrder = configStore.arrOrder
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
}

private struct ServiceFields: View {
    @Binding var config: ServiceConfig
    let kind: ServiceKind

    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    var body: some View {
        Toggle("Enabled", isOn: $config.enabled.animation())

        if config.enabled {
            TextField("URL", text: $config.baseURL, prompt: Text(kind.urlPlaceholder))
                .autocorrectionDisabled(true)

            if kind.requiresApiKey {
                SecureField("API Key", text: $config.apiKey, prompt: Text("Paste your API key"))
            }

            if kind.requiresLogin {
                TextField("Username", text: $config.username, prompt: Text("admin"))
                    .autocorrectionDisabled(true)
                SecureField("Password", text: $config.password, prompt: Text("Password"))
            }

            HStack(spacing: 8) {
                Button("Test Connection") { runTest() }
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
        case .sabnzbd:      return try await SabnzbdClient(config: config).testConnection()
        case .nzbget:       return try await NzbgetClient(config: config).testConnection()
        case .qbittorrent:  return try await QbittorrentClient(config: config).testConnection()
        case .transmission: return try await TransmissionClient(config: config).testConnection()
        case .rtorrent:     return try await RtorrentClient(config: config).testConnection()
        case .deluge:       return try await DelugeClient(config: config).testConnection()
        }
    }
}
