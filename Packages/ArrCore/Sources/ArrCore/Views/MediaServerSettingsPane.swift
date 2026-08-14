import SwiftUI

/// Settings → Media server.
///
/// One connection, one server. The picker is the whole feature's shape: Plex,
/// Jellyfin or Emby, never two at once — the integration reads artwork and
/// watch state, and merging two servers' answers would raise questions
/// ("watched where?") that nothing in the UI could sensibly answer.
///
/// Shared by both platforms: macOS hosts it as a sidebar detail pane, iOS
/// pushes it from the Settings list.
struct MediaServerSettingsPane: View {
    @EnvironmentObject var configStore: ConfigStore
    @ObservedObject private var storeManager = StoreManager.shared

    @State private var testState: TestState = .idle
    @State private var actionState: ActionState = .idle
    @State private var indexSummary: IndexSummary = .init(titles: 0, refreshedAt: nil)

    private enum TestState: Equatable {
        case idle, testing
        case success(String)
        case failure(String)
    }

    /// Result of the last "Scan library" / "Empty trash" press. Both are
    /// fire-and-forget on the server side, so the only honest feedback is
    /// "the request went through" or the error it came back with.
    private enum ActionState: Equatable {
        case idle, running
        case done(String)
        case failed(String)
    }

    private struct IndexSummary: Equatable {
        var titles: Int
        var refreshedAt: Date?
    }

    private var isLocked: Bool { !storeManager.isPro }

    var body: some View {
        Form {
            connectionSection
            if configStore.mediaServer.enabled {
                if configStore.mediaServer.isConfigured {
                    librarySection
                    indexSection
                }
            }
        }
        .formStyle(.grouped)
        .disabled(isLocked)
        .overlay {
            if isLocked { ProLockOverlay(feature: .mediaServer) }
        }
        .task { refreshIndexSummary() }
        #if os(iOS)
        .navigationTitle(Text("settings.mediaServer.label", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            Toggle(isOn: enabledBinding) { Text("settings.enabled.button", bundle: .module) }

            if configStore.mediaServer.enabled {
                Picker(selection: kindBinding) {
                    ForEach(MediaServerKind.allCases) { kind in
                        Text(verbatim: kind.displayName).tag(kind)
                    }
                } label: {
                    Text("settings.server.label", bundle: .module)
                }

                TextField(text: baseURLBinding,
                          prompt: Text(verbatim: configStore.mediaServer.kind.urlPlaceholder)) {
                    Text("settings.url.label", bundle: .module)
                }
                .urlField()

                SecureField(text: tokenBinding,
                            prompt: Text("settings.pasteYourToken.button", bundle: .module)) {
                    Text("settings.token.label", bundle: .module)
                }
                .apiKeyField()

                tokenHint

                testRow
            }
        } header: {
            Text("settings.mediaServer.label", bundle: .module)
        } footer: {
            Text("settings.mediaServerUsedFor.tooltip", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// How to get the token, per server. Plex is the one that needs real
    /// instructions: it has no "API keys" screen, and the route everyone in
    /// the arr ecosystem uses is to open an item's XML and read the token out
    /// of the URL.
    @ViewBuilder
    private var tokenHint: some View {
        switch configStore.mediaServer.kind {
        case .plex:
            Text("settings.plexTokenHowTo.tooltip", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
            Link(destination: URL(string: "https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/")!) {
                Label { Text("settings.howToFindPlexToken.button", bundle: .module) } icon: { Image(systemName: "questionmark.circle") }
            }
        case .jellyfin:
            Text("settings.jellyfinTokenHowTo.tooltip", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .emby:
            Text("settings.embyTokenHowTo.tooltip", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var testRow: some View {
        HStack(spacing: 8) {
            Button { runTest() } label: { Text("queue.testConnection.button", bundle: .module) }
                .modifier(GlassButtonStyle())
                .controlSize(.small)
                .disabled(testState == .testing || !configStore.mediaServer.isConfigured)

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
    }

    // MARK: - Maintenance

    private var librarySection: some View {
        Section {
            Button { run(.scan) } label: {
                Label { Text("settings.scanLibrary.button", bundle: .module) } icon: { Image(systemName: "arrow.clockwise") }
            }
            .disabled(actionState == .running)

            // Plex only. Jellyfin and Emby have no trash — an item leaves the
            // library when its file does — so the button is absent rather than
            // present and permanently failing.
            if configStore.mediaServer.kind == .plex {
                Button { run(.emptyTrash) } label: {
                    Label { Text("settings.emptyTrash.button", bundle: .module) } icon: { Image(systemName: "trash") }
                }
                .disabled(actionState == .running)
            }

            switch actionState {
            case .idle:
                EmptyView()
            case .running:
                ProgressView().controlSize(.small)
            case .done(let msg):
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let msg):
                Label(msg, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(msg)
            }
        } header: {
            Text("settings.library.label", bundle: .module)
        } footer: {
            Text("settings.scanAsksTheServer.tooltip", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var indexSection: some View {
        Section {
            LabeledContent {
                Text(verbatim: "\(indexSummary.titles)")
                    .foregroundStyle(.secondary)
            } label: {
                Text("settings.matchedTitles.label", bundle: .module)
            }
            if let refreshedAt = indexSummary.refreshedAt {
                LabeledContent {
                    Text(refreshedAt, style: .relative)
                        .foregroundStyle(.secondary)
                } label: {
                    Text("settings.lastUpdated.label", bundle: .module)
                }
            }
            Button { run(.reindex) } label: {
                Label { Text("settings.refreshNow.button", bundle: .module) } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
            }
            .disabled(actionState == .running)
        } header: {
            Text("settings.artworkAndHistory.label", bundle: .module)
        }
    }

    // MARK: - Bindings
    //
    // Every field writes through to `configStore.mediaServer` as a whole value,
    // because that is what the persistence sink observes. Editing a copy and
    // assigning it back is the only shape that triggers exactly one save per
    // keystroke instead of none.

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { configStore.mediaServer.enabled },
            set: { newValue in
                var cfg = configStore.mediaServer
                cfg.enabled = newValue
                withAnimation { configStore.mediaServer = cfg }
                if !newValue { MediaServerIndex.shared.clear(); refreshIndexSummary() }
            }
        )
    }

    private var kindBinding: Binding<MediaServerKind> {
        Binding(
            get: { configStore.mediaServer.kind },
            set: { newValue in
                var cfg = configStore.mediaServer
                guard cfg.kind != newValue else { return }
                cfg.kind = newValue
                // A token and a resolved user belong to one server. Carrying
                // them across a switch would produce a config that looks
                // complete and authenticates against nothing.
                cfg.token = ""
                cfg.userId = ""
                configStore.mediaServer = cfg
                testState = .idle
                MediaServerIndex.shared.clear()
                refreshIndexSummary()
            }
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { configStore.mediaServer.baseURL },
            set: { newValue in
                var cfg = configStore.mediaServer
                cfg.baseURL = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                configStore.mediaServer = cfg
                if testState != .idle && testState != .testing { testState = .idle }
            }
        )
    }

    private var tokenBinding: Binding<String> {
        Binding(
            get: { configStore.mediaServer.token },
            set: { newValue in
                var cfg = configStore.mediaServer
                cfg.token = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                configStore.mediaServer = cfg
                if testState != .idle && testState != .testing { testState = .idle }
            }
        )
    }

    // MARK: - Actions

    private func runTest() {
        testState = .testing
        let config = configStore.mediaServer
        Task {
            guard let client = MediaServerClientFactory.make(config: config) else {
                testState = .failure(String(localized: "settings.enterAValidUrl.tooltip", bundle: .module))
                return
            }
            do {
                let handshake = try await client.testConnection()
                // Persist the user id the server resolved for us, so every
                // later play-state query uses the same account without asking.
                if let userId = handshake.userId, userId != configStore.mediaServer.userId {
                    var cfg = configStore.mediaServer
                    cfg.userId = userId
                    configStore.mediaServer = cfg
                }
                testState = .success(handshake.versionLine)
                // A successful test is the moment the index can finally be
                // built — don't make the user wait for the next poll.
                await MediaServerIndex.shared.refresh(config: configStore.mediaServer)
                refreshIndexSummary()
            } catch {
                testState = .failure(message(for: error))
            }
        }
    }

    private enum Action { case scan, emptyTrash, reindex }

    private func run(_ action: Action) {
        actionState = .running
        let config = configStore.mediaServer
        Task {
            guard let client = MediaServerClientFactory.make(config: config) else {
                actionState = .failed(String(localized: "settings.enterAValidUrl.tooltip", bundle: .module))
                return
            }
            do {
                switch action {
                case .scan:
                    try await client.scanLibraries()
                    actionState = .done(String(localized: "settings.scanRequested.label", bundle: .module))
                case .emptyTrash:
                    try await client.emptyTrash()
                    actionState = .done(String(localized: "settings.trashEmptied.label", bundle: .module))
                case .reindex:
                    await MediaServerIndex.shared.refresh(config: config)
                    refreshIndexSummary()
                    actionState = .done(String(localized: "settings.upToDate.label", bundle: .module))
                }
            } catch {
                actionState = .failed(message(for: error))
            }
        }
    }

    private func refreshIndexSummary() {
        indexSummary = IndexSummary(
            titles: MediaServerIndex.shared.indexedTitleCount,
            refreshedAt: MediaServerIndex.shared.lastRefreshedAt
        )
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
