import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        Form {
            ServiceForm(
                title: "Radarr",
                config: Binding(get: { configStore.radarr }, set: { configStore.radarr = $0 }),
                requiresApiKey: true,
                requiresLogin: false
            )
            ServiceForm(
                title: "Sonarr",
                config: Binding(get: { configStore.sonarr }, set: { configStore.sonarr = $0 }),
                requiresApiKey: true,
                requiresLogin: false
            )
            ServiceForm(
                title: "SABnzbd (usenet actions)",
                config: Binding(get: { configStore.sabnzbd }, set: { configStore.sabnzbd = $0 }),
                requiresApiKey: true,
                requiresLogin: false
            )
            ServiceForm(
                title: "qBittorrent (torrent actions)",
                config: Binding(get: { configStore.qbittorrent }, set: { configStore.qbittorrent = $0 }),
                requiresApiKey: false,
                requiresLogin: true
            )
        }
        .formStyle(.grouped)
        .padding(12)
    }
}

private struct ServiceForm: View {
    let title: String
    @Binding var config: ServiceConfig
    let requiresApiKey: Bool
    let requiresLogin: Bool

    var body: some View {
        Section(title) {
            TextField("Base URL", text: $config.baseURL, prompt: Text("http://192.168.1.10:7878"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)

            if requiresApiKey {
                SecureField("API key", text: $config.apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            if requiresLogin {
                TextField("Username", text: $config.username)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                SecureField("Password", text: $config.password)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}
