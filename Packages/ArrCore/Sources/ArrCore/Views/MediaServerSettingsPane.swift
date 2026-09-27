import MediaKit
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

    /// Every operation here has one shape: it runs, then either says a short
    /// thing or shows the error it came back with. The connection test and
    /// the index refresh each own one; library maintenance owns one per
    /// library, so a scan on Movies and a purge on TV report side by side.
    @State private var testState: OperationState = .idle
    @State private var reindexState: OperationState = .idle
    @State private var libraryStates: [String: OperationState] = [:]
    @State private var libraries: LibrariesState = .loading
    @State private var indexSummary: IndexSummary = .init(titles: 0, refreshedAt: nil)

    private enum OperationState: Equatable {
        case idle, running
        case succeeded(String)
        case failed(String)
    }

    private enum LibrariesState: Equatable {
        case loading
        case loaded([MediaServerLibrary])
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
            // Both need a reachable connection to say anything true, and
            // `isConfigured` already implies `enabled`.
            if configStore.mediaServer.isConfigured {
                librarySection
                indexSection
            }
        }
        .formStyle(.grouped)
        .disabled(isLocked)
        .overlay {
            if isLocked { ProLockOverlay(feature: .mediaServer) }
        }
        .task { refreshIndexSummary() }
        // Re-read the library list whenever the connection changes: a new
        // server has different libraries, and a token fix is what makes the
        // list load at all.
        .task(id: configStore.mediaServer) { await loadLibraries() }
        #if os(iOS)
        .navigationTitle(Text("settings.mediaServer.label", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            // One picker instead of a switch plus a picker: the integration
            // has exactly four states and naming all four — including Off —
            // says more than a toggle read together with a separate picker.
            // A menu, not segments: it matches the other selects in Settings.
            Picker(selection: selectionBinding) {
                ForEach(MediaServerKind.allCases) { kind in
                    Text(verbatim: kind.displayName).tag(Optional(kind))
                }
                Text("settings.mediaServer.off.option", bundle: .module)
                    .tag(MediaServerKind?.none)
            } label: {
                Text("settings.server.label", bundle: .module)
            }
            .pickerStyle(.menu)

            if configStore.mediaServer.enabled {
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

                // Test directly under the credentials it checks, then the
                // how-to for where the token comes from.
                testRow
                tokenHint
            }
        } header: {
            HStack(spacing: 6) {
                // Brand mark only once a server is actually chosen — Off has
                // no brand, and a generic glyph there would read as a fourth
                // server rather than the absence of one.
                if configStore.mediaServer.enabled {
                    ServiceIcon(mediaServer: configStore.mediaServer.kind, size: 12)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text("settings.mediaServer.label", bundle: .module)
            }
        }
    }

    /// Where the token comes from, per server.
    ///
    /// Jellyfin and Emby name a screen you can walk to, which is short enough
    /// to say inline. Plex gets a link in the same slot instead — see below.
    @ViewBuilder
    private var tokenHint: some View {
        switch configStore.mediaServer.kind {
        case .plex:
            // A link rather than a sentence: Plex has no "API keys" screen, and
            // the route (open an item's XML, read the token out of the address
            // bar) is longer than a settings row should carry.
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
                .disabled(testState == .running || !configStore.mediaServer.isConfigured)

            status(testState)
        }
    }

    /// The one rendering of an operation's outcome, shared by the test row and
    /// the maintenance buttons.
    @ViewBuilder
    private func status(_ state: OperationState) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .lineLimit(1)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(msg)
        }
    }

    // MARK: - Maintenance

    private var librarySection: some View {
        Section {
            switch libraries {
            case .loading:
                ProgressView().controlSize(.small)
            case .failed(let message):
                status(.failed(message))
            case .loaded(let list) where list.isEmpty:
                Text("settings.noLibraries.label", bundle: .module)
                    .foregroundStyle(.secondary)
            case .loaded(let list):
                ForEach(list) { library in
                    libraryRow(library)
                }
            }
        } header: {
            Text("settings.libraries.label", bundle: .module)
        }
    }

    /// One library: its name and kind on the left, the maintenance it
    /// accepts on the right, with that library's own last outcome beside
    /// the buttons.
    private func libraryRow(_ library: MediaServerLibrary) -> some View {
        let state = libraryStates[library.id] ?? .idle
        return LabeledContent {
            HStack(spacing: 8) {
                status(state)
                Button { run(.scan, on: library) } label: {
                    Label { Text("settings.scan.button", bundle: .module) } icon: { Image(systemName: "arrow.clockwise") }
                }
                .modifier(GlassButtonStyle())
                .controlSize(.small)
                .disabled(state == .running)

                // Plex only. Jellyfin and Emby have no trash — an item leaves
                // the library when its file does — so the button is absent
                // rather than present and permanently failing.
                if configStore.mediaServer.kind == .plex {
                    Button { run(.emptyTrash, on: library) } label: {
                        Label { Text("settings.emptyTrash.button", bundle: .module) } icon: { Image(systemName: "trash") }
                    }
                    .modifier(GlassButtonStyle())
                    .controlSize(.small)
                    .disabled(state == .running)
                }
            }
        } label: {
            Label {
                Text(verbatim: library.displayName)
            } icon: {
                Image(systemName: library.symbol)
                    .foregroundStyle(.secondary)
            }
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
                    // A coarse, still string rather than `.relative`, which
                    // ticks the seconds up live and reads like a countdown to
                    // something. Nothing is counting down; this is just when we
                    // last read the server.
                    Text(verbatim: Self.agoFormatter.localizedString(for: refreshedAt, relativeTo: Date()))
                        .foregroundStyle(.secondary)
                } label: {
                    Text("settings.lastUpdated.label", bundle: .module)
                }
            }
            Toggle(isOn: $configStore.showWatchedIndicator) {
                Text("settings.showWatchedIndicator.label", bundle: .module)
            }
            Button { runReindex() } label: {
                Label { Text("settings.refreshNow.button", bundle: .module) } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
            }
            .disabled(reindexState == .running)
            status(reindexState)
        } header: {
            Text("settings.artworkAndHistory.label", bundle: .module)
        }
    }

    /// Whole-unit relative dates ("2 minutes ago"), never seconds.
    private static let agoFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    // MARK: - Bindings
    //
    // Every field writes through to `configStore.mediaServer` as a whole value,
    // because that is what the persistence sink observes. Editing a copy and
    // assigning it back is the only shape that triggers exactly one save per
    // keystroke instead of none.

    /// The segmented control's value: a server, or `nil` for Off. Collapses
    /// `enabled` and `kind` into the one thing the user is actually choosing.
    ///
    /// Switching servers clears the token and the resolved user id — they
    /// belong to one server, and carrying them across would leave a config
    /// that looks complete and authenticates against nothing. Switching to Off
    /// keeps them, so turning the same server back on doesn't mean re-pasting
    /// a token.
    private var selectionBinding: Binding<MediaServerKind?> {
        Binding(
            get: { configStore.mediaServer.enabled ? configStore.mediaServer.kind : nil },
            set: { newValue in
                var cfg = configStore.mediaServer
                guard let newValue else {
                    cfg.enabled = false
                    withAnimation { configStore.mediaServer = cfg }
                    MediaServerIndex.shared.clear()
                    refreshIndexSummary()
                    return
                }
                let switchedServer = cfg.kind != newValue
                cfg.kind = newValue
                cfg.enabled = true
                if switchedServer {
                    cfg.token = ""
                    cfg.userId = ""
                }
                withAnimation { configStore.mediaServer = cfg }
                if switchedServer {
                    testState = .idle
                    MediaServerIndex.shared.clear()
                    refreshIndexSummary()
                }
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
                invalidateTestResult()
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
                invalidateTestResult()
            }
        )
    }

    // MARK: - Actions

    /// Drop a stale verdict once the fields it was about have changed — but
    /// never interrupt a test that is still running.
    private func invalidateTestResult() {
        if testState != .running { testState = .idle }
    }

    private func runTest() {
        testState = .running
        let client = configStore.mediaServerClient
        Task {
            guard let client else {
                testState = .failed(String(localized: "settings.enterAValidUrl.tooltip", bundle: .module))
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
                testState = .succeeded(handshake.versionLine)
                // A successful test is the moment the index can finally be
                // built — don't make the user wait for the next poll. Same
                // for the library list, whose earlier failure was the very
                // thing the user just fixed.
                await MediaServerIndex.shared.refresh(config: configStore.mediaServer)
                refreshIndexSummary()
                await loadLibraries()
            } catch {
                testState = .failed(error.userFacingMessage)
            }
        }
    }

    private func loadLibraries() async {
        guard let client = configStore.mediaServerClient else { return }
        libraries = .loading
        libraryStates = [:]
        do {
            libraries = .loaded(try await client.libraries())
        } catch {
            libraries = .failed(error.userFacingMessage)
        }
    }

    private enum LibraryAction { case scan, emptyTrash }

    private func run(_ action: LibraryAction, on library: MediaServerLibrary) {
        libraryStates[library.id] = .running
        let client = configStore.mediaServerClient
        Task {
            guard let client else {
                libraryStates[library.id] = .failed(String(localized: "settings.enterAValidUrl.tooltip", bundle: .module))
                return
            }
            do {
                switch action {
                case .scan:
                    try await client.scanLibrary(id: library.id)
                    libraryStates[library.id] = .succeeded(String(localized: "settings.scanRequested.label", bundle: .module))
                case .emptyTrash:
                    try await client.emptyTrash(libraryId: library.id)
                    libraryStates[library.id] = .succeeded(String(localized: "settings.trashEmptied.label", bundle: .module))
                }
            } catch {
                libraryStates[library.id] = .failed(error.userFacingMessage)
            }
        }
    }

    private func runReindex() {
        reindexState = .running
        let config = configStore.mediaServer
        Task {
            await MediaServerIndex.shared.refresh(config: config)
            refreshIndexSummary()
            reindexState = .succeeded(String(localized: "settings.upToDate.label", bundle: .module))
        }
    }

    private func refreshIndexSummary() {
        indexSummary = IndexSummary(
            titles: MediaServerIndex.shared.indexedTitleCount,
            refreshedAt: MediaServerIndex.shared.lastRefreshedAt
        )
    }
}
