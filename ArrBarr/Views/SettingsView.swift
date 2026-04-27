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
        VStack(spacing: 0) {
            Form {
                Section("Radarr / Sonarr") {
                    ServiceFields(config: $draftRadarr, kind: .radarr)
                    Divider()
                    ServiceFields(config: $draftSonarr, kind: .sonarr)
                }
                Section("Usenet Clients") {
                    ServiceFields(config: $draftSabnzbd, kind: .sabnzbd)
                    Divider()
                    ServiceFields(config: $draftNzbget, kind: .nzbget)
                }
                Section("Torrent Clients") {
                    ServiceFields(config: $draftQbittorrent, kind: .qbittorrent)
                    Divider()
                    ServiceFields(config: $draftTransmission, kind: .transmission)
                    Divider()
                    ServiceFields(config: $draftRtorrent, kind: .rtorrent)
                    Divider()
                    ServiceFields(config: $draftDeluge, kind: .deluge)
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
            }
            .formStyle(.grouped)

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
        .onAppear { loadDrafts() }
        .alert("Unsaved Changes", isPresented: $showUnsavedAlert) {
            Button("Save", role: nil) { saveAndClose() }
            Button("Don't Save", role: .destructive) { NSApp.keyWindow?.close() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Do you want to save your changes before closing?")
        }
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
        Toggle(kind.displayName, isOn: $config.enabled.animation())

        if config.enabled {
            TextField("URL", text: $config.baseURL, prompt: Text("http://192.168.1.10:7878"))
                .autocorrectionDisabled(true)

            if kind.requiresApiKey {
                SecureField("API Key", text: $config.apiKey)
            }

            if kind.requiresLogin {
                TextField("Username", text: $config.username)
                    .autocorrectionDisabled(true)
                SecureField("Password", text: $config.password)
            }
        }
    }
}
