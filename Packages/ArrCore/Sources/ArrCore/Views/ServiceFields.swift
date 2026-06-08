import SwiftUI

/// One configurable service's fields (URL / key / login / test / calendar),
/// plus the Whisparr-only age gate and NSFW filter. Extracted from
/// `SettingsView` so both platforms share one definition.
struct ServiceFields: View {
    @Binding var config: ServiceConfig
    let kind: ServiceKind
    var notifyBinding: Binding<Bool>? = nil
    /// Whisparr-only extras, owned here so both the macOS panes and the iOS
    /// forms render one uniform `ServiceFields` with no per-platform `#if`:
    ///   - `ageConfirmedBinding`: 18+ confirmation state. Only gates enabling
    ///     in App Store builds (`#if APPSTORE`); ignored otherwise.
    ///   - `nsfwFilterBinding`: the "NSFW filter" (poster blur) toggle, shown
    ///     once Whisparr is enabled.
    var ageConfirmedBinding: Binding<Bool>? = nil
    var nsfwFilterBinding: Binding<Bool>? = nil

    @Environment(\.openURL) private var openURL
    @State private var testState: TestState = .idle
    @State private var showAgeGate = false

    private var enableBinding: Binding<Bool> {
        Binding(
            get: { config.enabled },
            set: { newValue in
                #if APPSTORE
                // App Store: enabling Whisparr requires a one-time 18+ confirm.
                if newValue, kind == .whisparr,
                   let ageConfirmed = ageConfirmedBinding, !ageConfirmed.wrappedValue {
                    showAgeGate = true
                    return
                }
                #endif
                withAnimation { config.enabled = newValue }
            }
        )
    }

    private enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    public var body: some View {
        Toggle(isOn: enableBinding) { Text("Enabled", bundle: .module) }
            .alert(Text("Adult content", bundle: .module), isPresented: $showAgeGate) {
                Button(role: .cancel) { } label: { Text("Cancel", bundle: .module) }
                Button {
                    ageConfirmedBinding?.wrappedValue = true
                    withAnimation { config.enabled = true }
                } label: { Text("Confirm (18+)", bundle: .module) }
            } message: {
                Text("Whisparr may provide 18+ content. Confirm that you are 18 or older.", bundle: .module)
            }

        if config.enabled, let notifyBinding {
            Toggle(isOn: notifyBinding) { Text("Notify on new grabs", bundle: .module) }
        }

        if config.enabled {
            TextField(text: $config.baseURL, prompt: Text(verbatim: kind.urlPlaceholder)) {
                Text("URL", bundle: .module)
            }
            .urlField()

            if kind.requiresApiKey {
                SecureField(text: $config.apiKey, prompt: Text("Paste your API key", bundle: .module)) {
                    Text("API Key", bundle: .module)
                }
                .apiKeyField()
            }

            if kind.requiresLogin {
                // qBittorrent 5.x accepts either a username/password login or
                // an API key. We surface that on one field pair: leaving the
                // login blank switches the client into API-key mode, where the
                // "password" field carries the key (see QbittorrentClient).
                let isQbit = kind == .qbittorrent
                TextField(text: $config.username, prompt: Text("admin", bundle: .module)) {
                    if isQbit {
                        Text("Login (leave empty for API key)", bundle: .module)
                    } else {
                        Text("Username", bundle: .module)
                    }
                }
                .usernameField()
                SecureField(text: $config.password, prompt: Text("Password", bundle: .module)) {
                    if isQbit {
                        Text("Password or API key", bundle: .module)
                    } else {
                        Text("Password", bundle: .module)
                    }
                }
                .passwordField()
            }

            // Passive "this won't work yet" hint — enabled but missing URL or
            // (for arrs/SABnzbd) the API key. Shown until the user completes
            // it, independent of whether they've pressed Test Connection.
            if let reason = incompleteReason, testState == .idle {
                Label {
                    Text(verbatim: reason)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
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

            // Calendar subscription (arrs only). Opens the arr's iCal feed as
            // `webcal://` → Apple Calendar's "Subscribe to calendar" flow.
            if let calURL = CalendarFeed.subscriptionURL(kind: kind, config: config) {
                // Plain Form-row action (no GlassButtonStyle — that nested a
                // pill inside the already-tappable row).
                Button {
                    openURL(calURL)
                } label: {
                    Label { Text("Add to Calendar", bundle: .module) } icon: { Image(systemName: "calendar.badge.plus") }
                }
                Text("Subscribes this calendar in Apple Calendar. The server must be reachable when Calendar refreshes (home network or VPN).", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Whisparr-only: NSFW filter (poster blur), defaulting on.
            if kind == .whisparr, let nsfw = nsfwFilterBinding {
                Toggle(isOn: nsfw) { Text("NSFW filter", bundle: .module) }
            }
        }
    }

    /// Non-nil when the service is enabled but can't work yet — drives the
    /// inline warning. URL must be valid; arrs / SABnzbd additionally need a key.
    private var incompleteReason: String? {
        guard config.enabled else { return nil }
        if !config.isConfigured {
            return String(localized: "Enter a valid URL (http:// or https://).", bundle: .module)
        }
        if kind.requiresApiKey && config.apiKey.isEmpty {
            return String(localized: "API key is required.", bundle: .module)
        }
        return nil
    }

    private func runTest() {
        testState = .testing
        let snapshot = config
        let kind = self.kind
        Task {
            do {
                let result = try await ConnectionTester.test(kind: kind, config: snapshot)
                await MainActor.run {
                    testState = .success(result)
                    // Kick a queue refresh so a just-entered key clears the
                    // stale "missing API key" banner right away.
                    NotificationCenter.default.post(name: .arrBarrConfigValidated, object: nil)
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { testState = .failure(message) }
            }
        }
    }
}

enum ConnectionTester {
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
