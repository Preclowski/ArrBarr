import SwiftUI

struct ServiceFields: View {
    @Binding var config: ServiceConfig
    let kind: ServiceKind
    var notifyBinding: Binding<Bool>? = nil
    /// `ageConfirmedBinding` only gates enabling in App Store builds.
    var ageConfirmedBinding: Binding<Bool>? = nil
    var nsfwFilterBinding: Binding<Bool>? = nil

    @Environment(\.openURL) private var openURL
    @State private var testState: TestState = .idle
    @State private var showAgeGate = false

    private var enableBinding: Binding<Bool> {
        Binding(
            get: { config.enabled },
            set: { newValue in
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

    /// Sanitised on assignment: whitespace or an arr `#/…` route makes `URL(string:)`
    /// nil, and `QueueAggregator` silently swallows the resulting `.notConfigured`.
    private var baseURLBinding: Binding<String> {
        Binding(
            get: { config.baseURL },
            set: { config.baseURL = Self.sanitizedBaseURL($0) }
        )
    }

    /// Internal, not private: Settings' Prowlarr page has no `ServiceKind`
    /// and so builds its own URL binding, but must sanitise identically.
    static func sanitizedBaseURL(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The arrs are hash-routed SPAs; drop the fragment and the "/" before it.
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

    var body: some View {
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
                // qBittorrent 5.x: a blank login switches to API-key mode, where the
                // "password" field carries the key.
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
                    .buttonStyle(.bordered)
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

            // Opens the arr's iCal feed as `webcal://` → Apple Calendar's subscribe flow.
            if let calURL = CalendarFeed.subscriptionURL(kind: kind, config: config) {
                // No GlassButtonStyle: that nested a pill inside the tappable row.
                Button {
                    openURL(calURL)
                } label: {
                    Label { Text("settings.addToCalendar.button", bundle: .module) } icon: { Image(systemName: "calendar.badge.plus") }
                }
                Text("settings.subscribesThisCalendarIn.tooltip", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if kind == .whisparr, let nsfw = nsfwFilterBinding {
                Toggle(isOn: nsfw) { Text("settings.nsfwFilter.button", bundle: .module) }
            }
        }
    }

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
                let result = try await ServiceHandles.testConnection(kind, config: snapshot)
                await MainActor.run {
                    testState = .success(result)
                    ConnectionHealth.shared.forceOK(.arr(kind), detail: result)
                    AppMessages.post(AppMessages.ConfigValidated())
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    testState = .failure(message)
                    ConnectionHealth.shared.forceDown(.arr(kind), message: message)
                }
            }
        }
    }
}
