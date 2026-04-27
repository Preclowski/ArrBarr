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
        }
    }
}
