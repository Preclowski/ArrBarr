import MediaKit
import SwiftUI

/// One server at a time: merging two servers' watch state raises "watched where?" questions.
struct MediaServerSettingsPane: View {
    @EnvironmentObject var configStore: ConfigStore
    @ObservedObject private var storeManager = StoreManager.shared

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
            // Both need a reachable connection; `isConfigured` already implies `enabled`.
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
        // A new server has different libraries, and a token fix is what makes the list load at all.
        .task(id: configStore.mediaServer) { await loadLibraries() }
        #if os(iOS)
        .navigationTitle(Text("settings.mediaServer.label", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
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

                testRow
                tokenHint
            }
        } header: {
            HStack(spacing: 6) {
                // Off has no brand; a generic glyph would read as a fourth server.
                if configStore.mediaServer.enabled {
                    ServiceIcon(mediaServer: configStore.mediaServer.kind, size: 12)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text("settings.mediaServer.label", bundle: .module)
            }
        }
    }

    @ViewBuilder
    private var tokenHint: some View {
        switch configStore.mediaServer.kind {
        case .plex:
            // Plex has no "API keys" screen; the token route is too long for a settings row.
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

                // Jellyfin and Emby have no trash — an item leaves with its file.
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
                    // Not `.relative`, which ticks seconds live and reads like a countdown.
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

    private static let agoFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    // MARK: - Bindings
    // Every field writes the whole `configStore.mediaServer` value, which is what the persistence sink observes.

    /// Switching servers clears the token and user id (they belong to one server); Off keeps them.
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

    /// Never interrupts a test that is still running.
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
                if let userId = handshake.userId, userId != configStore.mediaServer.userId {
                    var cfg = configStore.mediaServer
                    cfg.userId = userId
                    configStore.mediaServer = cfg
                }
                testState = .succeeded(handshake.versionLine)
                // Build the index and reload libraries now rather than waiting for the next poll.
                await MediaServerIndex.shared.refresh(config: configStore.mediaServer)
                refreshIndexSummary()
                await loadLibraries()
            } catch {
                testState = .failed(error.localizedDescription)
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
            libraries = .failed(error.localizedDescription)
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
                libraryStates[library.id] = .failed(error.localizedDescription)
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
