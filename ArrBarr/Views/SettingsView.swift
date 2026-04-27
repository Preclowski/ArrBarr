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
    @State private var showUnsavedAlert = false

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
        .onAppear { loadDrafts() }
        .alert("Unsaved Changes", isPresented: $showUnsavedAlert) {
            Button("Save", role: nil) { save(); NSApp.keyWindow?.close() }
            Button("Don't Save", role: .destructive) { NSApp.keyWindow?.close() }
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
            Section("Notifications") {
                Toggle("Radarr — notify on new grabs", isOn: $draftNotifyRadarr)
                Toggle("Sonarr — notify on new grabs", isOn: $draftNotifySonarr)
                Toggle("Lidarr — notify on new grabs", isOn: $draftNotifyLidarr)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Spacer()
                if hasChanges {
                    Button("Save") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .modifier(GlassProminentButtonStyle())
                        .controlSize(.large)
                }
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
    }

    private static func formatInterval(_ seconds: TimeInterval) -> String {
        if seconds == 0 {
            return "Never"
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
