import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var configStore: ConfigStore
    @State private var draftRadarr: ServiceConfig = .empty
    @State private var draftSonarr: ServiceConfig = .empty
    @State private var draftSabnzbd: ServiceConfig = .empty
    @State private var draftQbittorrent: ServiceConfig = .empty
    @State private var draftForegroundInterval: TimeInterval = 5
    @State private var draftBackgroundInterval: TimeInterval = 30

    private var hasChanges: Bool {
        draftRadarr != configStore.radarr
        || draftSonarr != configStore.sonarr
        || draftSabnzbd != configStore.sabnzbd
        || draftQbittorrent != configStore.qbittorrent
        || draftForegroundInterval != configStore.foregroundInterval
        || draftBackgroundInterval != configStore.backgroundInterval
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Radarr") {
                    ServiceFields(config: $draftRadarr, requiresApiKey: true, requiresLogin: false)
                }
                Section("Sonarr") {
                    ServiceFields(config: $draftSonarr, requiresApiKey: true, requiresLogin: false)
                }
                Section("SABnzbd") {
                    ServiceFields(config: $draftSabnzbd, requiresApiKey: true, requiresLogin: false)
                }
                Section("qBittorrent") {
                    ServiceFields(config: $draftQbittorrent, requiresApiKey: false, requiresLogin: true)
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
                Button(hasChanges ? "Save & Close" : "Close") {
                    if hasChanges {
                        configStore.radarr = draftRadarr
                        configStore.sonarr = draftSonarr
                        configStore.sabnzbd = draftSabnzbd
                        configStore.qbittorrent = draftQbittorrent
                        configStore.foregroundInterval = draftForegroundInterval
                        configStore.backgroundInterval = draftBackgroundInterval
                    }
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(hasChanges ? "s" : "w", modifiers: .command)
                .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onAppear { loadDrafts() }
    }

    // MARK: - Helpers

    private func loadDrafts() {
        draftRadarr = configStore.radarr
        draftSonarr = configStore.sonarr
        draftSabnzbd = configStore.sabnzbd
        draftQbittorrent = configStore.qbittorrent
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
    let requiresApiKey: Bool
    let requiresLogin: Bool

    var body: some View {
        Toggle("Enabled", isOn: $config.enabled.animation())

        if config.enabled {
            TextField("URL", text: $config.baseURL, prompt: Text("http://192.168.1.10:7878"))
                .autocorrectionDisabled(true)

            if requiresApiKey {
                SecureField("API Key", text: $config.apiKey)
            }

            if requiresLogin {
                TextField("Username", text: $config.username)
                    .autocorrectionDisabled(true)
                SecureField("Password", text: $config.password)
            }
        }
    }
}
