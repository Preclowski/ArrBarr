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
                // App Store: enabling Whisparr requires a one-time 18+ confirm.
                if AppCapabilities.isAppStore,
                   newValue, kind == .whisparr,
                   let ageConfirmed = ageConfirmedBinding, !ageConfirmed.wrappedValue {
                    showAgeGate = true
                    return
                }
                withAnimation { config.enabled = newValue }
            }
        )
    }

    /// URLs almost never arrive clean. A copy out of a terminal or a
    /// docker-compose line drags whitespace or a newline along; a copy out of
    /// the arr's own address bar drags its `#/…` hash route along. Both make
    /// `URL(string:)` return nil, which flips `ServiceConfig.isConfigured` to
    /// false — and `QueueAggregator` deliberately swallows `.notConfigured`,
    /// so the arr then contributes nothing with no error surfaced anywhere.
    /// Sanitising on assignment (rather than validating on submit) keeps that
    /// failure mode from ever existing.
    private var baseURLBinding: Binding<String> {
        Binding(
            get: { config.baseURL },
            set: { config.baseURL = Self.sanitizedBaseURL($0) }
        )
    }

    private static func sanitizedBaseURL(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // "http://host:8989/#/activity/queue" → "http://host:8989". The arrs
        // are hash-routed SPAs, so every URL the user can see in their browser
        // carries a fragment we have to drop — along with the "/" in front of
        // it, which would otherwise leave a stray trailing slash.
        if let hash = url.firstIndex(of: "#") {
            url = String(url[..<hash])
            if url.hasSuffix("/") { url = String(url.dropLast()) }
        }
        return url
    }

    private enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    public var body: some View {
        Toggle(isOn: enableBinding) { Text("settings.enabled.button", bundle: .module) }
            .alert(Text("settings.adultContent.button", bundle: .module), isPresented: $showAgeGate) {
                Button(role: .cancel) { } label: { Text("common.cancel.button", bundle: .module) }
                Button {
                    ageConfirmedBinding?.wrappedValue = true
                    withAnimation { config.enabled = true }
                } label: { Text("settings.confirm18.button", bundle: .module) }
            } message: {
                Text("settings.whisparrMayProvide18.tooltip", bundle: .module)
            }

        if config.enabled, let notifyBinding {
            Toggle(isOn: notifyBinding) { Text("settings.notifyOnNewGrabs.button", bundle: .module) }
        }

        if config.enabled {
            TextField(text: baseURLBinding, prompt: Text(verbatim: kind.urlPlaceholder)) {
                Text("settings.url.label", bundle: .module)
            }
            .urlField()

            if kind.requiresApiKey {
                SecureField(text: $config.apiKey, prompt: Text("settings.pasteYourApiKey.button", bundle: .module)) {
                    Text("settings.apiKey.button", bundle: .module)
                }
                .apiKeyField()
            }

            if kind.requiresLogin {
                // qBittorrent 5.x accepts either a username/password login or
                // an API key. We surface that on one field pair: leaving the
                // login blank switches the client into API-key mode, where the
                // "password" field carries the key (see QbittorrentClient).
                let isQbit = kind == .qbittorrent
                TextField(text: $config.username, prompt: Text("settings.admin.label", bundle: .module)) {
                    if isQbit {
                        Text("settings.loginLeaveEmptyFor.label", bundle: .module)
                    } else {
                        Text("settings.username.button", bundle: .module)
                    }
                }
                .usernameField()
                SecureField(text: $config.password, prompt: Text("settings.password.button", bundle: .module)) {
                    if isQbit {
                        Text("settings.passwordOrApiKey.button", bundle: .module)
                    } else {
                        Text("settings.password.button", bundle: .module)
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
                ConnectionStatusDot(service: .arr(kind))
                Button { runTest() } label: { Text("queue.testConnection.button", bundle: .module) }
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
                    Label { Text("settings.addToCalendar.button", bundle: .module) } icon: { Image(systemName: "calendar.badge.plus") }
                }
                Text("settings.subscribesThisCalendarIn.tooltip", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Whisparr-only: NSFW filter (poster blur), defaulting on.
            if kind == .whisparr, let nsfw = nsfwFilterBinding {
                Toggle(isOn: nsfw) { Text("settings.nsfwFilter.button", bundle: .module) }
            }
        }
    }

    /// Non-nil when the service is enabled but can't work yet — drives the
    /// inline warning. URL must be valid; arrs / SABnzbd additionally need a key.
    private var incompleteReason: String? {
        guard config.enabled else { return nil }
        if !config.isConfigured {
            return String(localized: "settings.enterAValidUrl.tooltip", bundle: .module)
        }
        if kind.requiresApiKey && config.apiKey.isEmpty {
            return String(localized: "settings.apiKeyIsRequired.tooltip", bundle: .module)
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
                    ConnectionHealth.shared.forceOK(.arr(kind), detail: result)
                    // Kick a queue refresh so a just-entered key clears the
                    // stale "missing API key" banner right away.
                    NotificationCenter.default.post(name: .arrBarrConfigValidated, object: nil)
                }
            } catch {
                let message = error.userFacingMessage
                await MainActor.run {
                    testState = .failure(message)
                    ConnectionHealth.shared.forceDown(.arr(kind), message: message)
                }
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
