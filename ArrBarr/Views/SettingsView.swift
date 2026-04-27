import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var configStore: ConfigStore
    @State private var draftRadarr: ServiceConfig = .empty
    @State private var draftSonarr: ServiceConfig = .empty
    @State private var draftSabnzbd: ServiceConfig = .empty
    @State private var draftQbittorrent: ServiceConfig = .empty
    @State private var draftNzbget: ServiceConfig = .empty
    @State private var draftTransmission: ServiceConfig = .empty
    @State private var draftRtorrent: ServiceConfig = .empty
    @State private var draftDeluge: ServiceConfig = .empty
    @State private var draftForegroundInterval: TimeInterval = 5
    @State private var draftBackgroundInterval: TimeInterval = 30
    @State private var showUnsavedAlert = false
    @State private var selectedTab: SettingsTab = .mediaServers

    enum SettingsTab: String, CaseIterable, Identifiable {
        case mediaServers = "Media Servers"
        case usenet = "Usenet"
        case torrents = "Torrents"
        case general = "General"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .mediaServers: return "server.rack"
            case .usenet: return "doc.zipper"
            case .torrents: return "arrow.triangle.2.circlepath"
            case .general: return "gearshape"
            }
        }
    }

    private var hasChanges: Bool {
        draftRadarr != configStore.radarr
        || draftSonarr != configStore.sonarr
        || draftSabnzbd != configStore.sabnzbd
        || draftQbittorrent != configStore.qbittorrent
        || draftNzbget != configStore.nzbget
        || draftTransmission != configStore.transmission
        || draftRtorrent != configStore.rtorrent
        || draftDeluge != configStore.deluge
        || draftForegroundInterval != configStore.foregroundInterval
        || draftBackgroundInterval != configStore.backgroundInterval
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            Form {
                switch selectedTab {
                case .mediaServers: mediaServersPane
                case .usenet: usenetPane
                case .torrents: torrentsPane
                case .general: generalPane
                }
            }
            .formStyle(.grouped)
            .navigationTitle(selectedTab.rawValue)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onAppear { loadDrafts() }
        .alert("Unsaved Changes", isPresented: $showUnsavedAlert) {
            Button("Save", role: nil) { saveAndClose() }
            Button("Don't Save", role: .destructive) { NSApp.keyWindow?.close() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Do you want to save your changes before closing?")
        }
    }

    // MARK: - Panes

    private var mediaServersPane: some View {
        Group {
            Section("Radarr") {
                ServiceFields(config: $draftRadarr, kind: .radarr)
            }
            Section("Sonarr") {
                ServiceFields(config: $draftSonarr, kind: .sonarr)
            }
        }
    }

    private var usenetPane: some View {
        Group {
            Section("SABnzbd") {
                ServiceFields(config: $draftSabnzbd, kind: .sabnzbd)
            }
            Section("NZBGet") {
                ServiceFields(config: $draftNzbget, kind: .nzbget)
            }
        }
    }

    private var torrentsPane: some View {
        Group {
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
    }

    private var generalPane: some View {
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
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Spacer()
                if hasChanges {
                    Button("Save") { saveAndClose() }
                        .keyboardShortcut("s", modifiers: .command)
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
                .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    // MARK: - Helpers

    private func saveAndClose() {
        configStore.radarr = draftRadarr
        configStore.sonarr = draftSonarr
        configStore.sabnzbd = draftSabnzbd
        configStore.qbittorrent = draftQbittorrent
        configStore.nzbget = draftNzbget
        configStore.transmission = draftTransmission
        configStore.rtorrent = draftRtorrent
        configStore.deluge = draftDeluge
        configStore.foregroundInterval = draftForegroundInterval
        configStore.backgroundInterval = draftBackgroundInterval
        NSApp.keyWindow?.close()
    }

    private func loadDrafts() {
        draftRadarr = configStore.radarr
        draftSonarr = configStore.sonarr
        draftSabnzbd = configStore.sabnzbd
        draftQbittorrent = configStore.qbittorrent
        draftNzbget = configStore.nzbget
        draftTransmission = configStore.transmission
        draftRtorrent = configStore.rtorrent
        draftDeluge = configStore.deluge
        draftForegroundInterval = configStore.foregroundInterval
        draftBackgroundInterval = configStore.backgroundInterval
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
