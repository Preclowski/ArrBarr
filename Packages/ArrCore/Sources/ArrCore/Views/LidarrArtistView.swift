import SwiftUI
import MediaKit

/// Lidarr's addable entity is the artist, so search, post-add and chat cards
/// land here; queue rows go straight to album detail.
struct LidarrArtistView: View {
    /// Synthetic artist item: `entityId` is the Lidarr artist id.
    let item: QueueItem
    let onBack: () -> Void
    var viewModel: QueueViewModel

    @EnvironmentObject private var configStore: ConfigStore

    @State private var artist: ArrArtist?
    @State private var albums: [ArrAlbum] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var enlargedPoster: URL?
    /// Owned locally so back from the album returns here, not to the queue.
    @State private var albumDetail: QueueItem?
    /// Keyed by the server's type string; empty means all expanded.
    @State private var collapsedTypes: Set<String> = []
    @State private var editRequest: MediaEditRequest?
    @State private var deleteRequest: MediaDeleteRequest?

    private var editTarget: MediaEditRequest? {
        guard let artistId = item.entityId else { return nil }
        return MediaEditRequest(source: .lidarr, entityId: artistId)
    }

    private var deleteTarget: MediaDeleteRequest? {
        guard let artistId = item.entityId else { return nil }
        return MediaDeleteRequest(source: .lidarr, entityId: artistId,
                                  title: artist?.artistName ?? item.title)
    }

    private func handleDeleted() {
        deleteRequest = nil
        Task { await viewModel.refresh() }
        onBack()
    }

    /// Nil monitored (older Lidarr, or still fetching) renders nothing.
    @ViewBuilder
    private var monitorPosterToggle: some View {
        if let monitored = artist?.monitored {
            MonitorPosterToggle(isMonitored: monitored, entity: .artist) { m in
                await setArtistMonitored(m)
            }
        }
    }

    /// A failed PUT refetches so the bookmark snaps back.
    private func setArtistMonitored(_ monitored: Bool) async {
        guard let artistId = item.entityId else { return }
        artist?.monitored = monitored
        do {
            try await configStore.lidarrClient
                .setArtistMonitored(artistId: artistId, monitored: monitored)
        } catch {
            await load()
        }
    }

    var body: some View {
        ZStack {
            mainContent

            // iOS presents it as a sheet instead.
            #if os(macOS)
            if let req = editRequest {
                MediaEditModalOverlay(request: req, onDismiss: { editRequest = nil })
                    .zIndex(6)
            }
            if let req = deleteRequest {
                MediaDeleteModalOverlay(request: req,
                                        onDismiss: { deleteRequest = nil },
                                        onDeleted: handleDeleted)
                    .zIndex(7)
            }
            #endif
        }
        #if os(iOS)
        .sheet(item: $editRequest) { req in
            // Detents live inside the panel — see MediaEditPanel.
            MediaEditPanel(request: req, onBack: { editRequest = nil })
        }
        .sheet(item: $deleteRequest) { req in
            MediaDeletePanel(request: req,
                             onCancel: { deleteRequest = nil },
                             onDeleted: handleDeleted)
        }
        #endif
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Popover hides the native chevron and the detached window has none.
            HStack(spacing: 6) {
                FloatingBackButton(action: onBack)
                    .keyboardShortcut(.cancelAction)
                Text(artist?.artistName ?? item.title)
                    .scaledFont(size: 15, weight: .semibold)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let target = editTarget {
                    Menu {
                        Button { editRequest = target } label: {
                            Label { Text("detail.edit.button", bundle: .module) } icon: { Image(systemName: "pencil") }
                        }
                        Button(role: .destructive) { deleteRequest = deleteTarget } label: {
                            Label { Text("detail.delete.button", bundle: .module) } icon: { Image(systemName: "trash") }
                        }
                    } label: {
                        Image(systemName: "pencil")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .help(Text("detail.editOrDelete.tooltip", bundle: .module))
                }
                if let url = artistWebURL {
                    Button { PlatformURLOpener.open(url) } label: {
                        Image(systemName: "safari")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(Text("detail.openInBrowser.button", bundle: .module))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            #endif

            ScrollView {
                // Album rows (PosterMetadataRow) self-inset 12, so the list is full-bleed.
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        headerCard
                        if let overview = artist?.overview, !overview.isEmpty {
                            ExpandableOverview(text: overview)
                        } else if loading {
                            SkeletonLines(count: 3)
                        }
                    }
                    .padding(.horizontal, 14)
                    albumSection
                    if let err = loadError {
                        LoadErrorLine(message: err)
                            .padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .posterLightbox(
            url: $enlargedPoster,
            apiKey: item.posterRequiresAuth ? configStore.lidarr.apiKey : nil,
            aspectRatio: 1.0
        )
        .task(id: item.id) { await load() }
        #if os(iOS)
        .navigationTitle(artist?.artistName ?? item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let target = editTarget {
                    Menu {
                        Button { editRequest = target } label: {
                            Label { Text("detail.edit.button", bundle: .module) } icon: { Image(systemName: "pencil") }
                        }
                        Section {
                            Button(role: .destructive) { deleteRequest = deleteTarget } label: {
                                Label { Text("detail.delete.button", bundle: .module) } icon: { Image(systemName: "trash") }
                            }
                        }
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel(Text("detail.editOrDelete.tooltip", bundle: .module))
                }
                if let url = artistWebURL {
                    Button { PlatformURLOpener.open(url) } label: {
                        Image(systemName: "safari")
                    }
                    .help(Text("detail.openInBrowser.button", bundle: .module))
                }
            }
        }
        #else
        .toolbar(.hidden, for: .windowToolbar)
        #endif
        .navigationDestination(item: $albumDetail) { album in
            DetailView(
                item: album,
                onBack: { albumDetail = nil },
                viewModel: viewModel
            )
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        let posterUrl = arrPosterURL(images: artist?.images, for: item, in: configStore)
        let resolvedURL = posterUrl ?? item.posterURL
        return HStack(alignment: .top, spacing: 12) {
            DetailHeroPoster(
                url: resolvedURL,
                apiKey: item.posterRequiresAuth ? configStore.lidarr.apiKey : nil,
                size: CGSize(width: 110, height: 110),
                fallbackSymbol: "music.mic",
                cornerAction: AnyView(monitorPosterToggle),
                onTap: { url in
                    withAnimation(.smooth(duration: 0.22)) { enlargedPoster = url }
                }
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(artist?.artistName ?? item.title)
                    .scaledFont(size: 15, weight: .semibold)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let count = artist?.statistics?.albumCount, count > 0 {
                        Text("\(count) albums", bundle: .module).foregroundStyle(.secondary)
                    }
                    if let tracks = artist?.statistics?.trackCount, tracks > 0 {
                        SeparatorDot()
                        Text("\(tracks) tracks", bundle: .module).foregroundStyle(.secondary)
                    }
                    if let size = artist?.statistics?.sizeOnDisk, size > 0 {
                        SeparatorDot()
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                }
                .scaledFont(size: 11)
                if let genres = artist?.genres, !genres.isEmpty {
                    GenreChips(genres: genres)
                }
                if let v = artist?.ratings?.value,
                   let chip = RatingChip.plain(v, votes: artist?.ratings?.votes) {
                    HStack(spacing: 6) {
                        RatingPill(chip: chip)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Album list

    /// Types are Lidarr enum values ("Album", "EP", "Single"), shown verbatim.
    private var albumTypeGroups: [(type: String, albums: [ArrAlbum])] {
        let grouped = Dictionary(grouping: albums) { $0.albumType ?? "Other" }
        let preferred = ["Album", "EP", "Single"]
        let rest = grouped.keys
            .filter { !preferred.contains($0) }
            .sorted()
        return (preferred + rest).compactMap { type in
            guard let list = grouped[type] else { return nil }
            return (type, list)
        }
    }

    @ViewBuilder
    private var albumSection: some View {
        if albums.isEmpty {
            DetailSectionHeader("Albums")
                .padding(.horizontal, 14)
            if loading {
                SkeletonRows(count: 6)
                    .padding(.top, 6)
                    .padding(.horizontal, 14)
            } else if loadError == nil {
                Text("person.noTitles.label", bundle: .module)
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
        } else {
            // Spacing 0 so the headers' own paddings set the rhythm, not the outer 12pt.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(albumTypeGroups.enumerated()), id: \.element.type) { index, group in
                    sectionHeader(for: group, isFirst: index == 0)
                    if !collapsedTypes.contains(group.type) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(group.albums) { album in
                                albumRow(album)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(
        for group: (type: String, albums: [ArrAlbum]), isFirst: Bool
    ) -> some View {
        let collapsed = collapsedTypes.contains(group.type)
        return HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .scaledFont(size: 9, weight: .semibold)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: 10)
                .accessibilityHidden(true)
            // Other types are Lidarr enum values; pluralising them per language buys nothing.
            if group.type == "Album" {
                DetailSectionHeader("Albums", count: group.albums.count)
            } else {
                DetailSectionHeader(verbatim: group.type, count: group.albums.count)
            }
            Spacer(minLength: 0)
        }
        // Matches the rows' PosterMetadataRow inset.
        .padding(.horizontal, 12)
        .padding(.top, isFirst ? 0 : 14)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.smooth(duration: 0.2)) {
                if collapsed { collapsedTypes.remove(group.type) }
                else { collapsedTypes.insert(group.type) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(
            Text(collapsed ? "Expand section" : "Collapse section", bundle: .module)
        )
    }

    private func albumRow(_ album: ArrAlbum) -> some View {
        let (cover, coverAuth) = album.coverURL(baseURL: configStore.lidarr.baseURL)
        let trackCount = album.statistics?.totalTrackCount ?? album.statistics?.trackCount ?? 0
        let fileCount = album.statistics?.trackFileCount ?? 0
        let complete = trackCount > 0 && fileCount >= trackCount
        // No type segment: the section header already says it.
        var segments: [String] = []
        if let year = albumYear(album) { segments.append(year) }
        if trackCount > 0 {
            let word = String.localizedStringWithFormat(
                String(localized: "%lld tracks", bundle: .module), trackCount)
            segments.append(complete ? word : "\(fileCount)/" + word)
        }
        return PosterMetadataRow(
            posterURL: cover,
            posterAPIKey: coverAuth ? configStore.lidarr.apiKey : nil,
            posterSize: CGSize(width: 44, height: 44),
            posterCornerRadius: Tokens.Radius.chip,
            posterBlurred: false,
            posterFallbackSymbol: "music.note",
            title: album.title,
            metadataSegments: segments,
            onTap: {
                guard let id = album.id else { return }
                albumDetail = DetailRequest.syntheticItem(
                    source: .lidarr,
                    entityId: id,
                    title: album.title,
                    posterURL: cover,
                    posterRequiresAuth: coverAuth
                )
            }
        ) {
            if complete {
                Circle().fill(Color.green).frame(width: 4, height: 4)
                    .accessibilityLabel(Text("queue.completed.button", bundle: .module))
            }
            if album.monitored == false {
                Image(systemName: "bookmark.slash")
                    .scaledFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .help(Text("Unmonitored", bundle: .module))
            }
        }
    }

    private func albumYear(_ album: ArrAlbum) -> String? {
        guard let dateStr = album.releaseDate, let date = parseArrDate(dateStr) else { return nil }
        return CachedDateFormatters.format("yyyy").string(from: date)
    }

    /// Keyed by `foreignArtistId`, known only after the fetch.
    private var artistWebURL: URL? {
        guard let foreign = artist?.foreignArtistId, !foreign.isEmpty else { return nil }
        return URL(string: configStore.lidarr.baseURL)?
            .appendingPathComponent("/artist/\(foreign)")
    }

    // MARK: - Fetch

    private func load() async {
        guard let artistId = item.entityId else { return }
        loading = true
        loadError = nil
        defer { loading = false }
        let client = configStore.lidarrClient
        async let a = client.fetchArtistDetails(id: artistId)
        async let al = client.fetchArtistAlbums(artistId: artistId)
        do {
            artist = try await a
            // Newest first, like Lidarr's own artist page.
            albums = try await al.sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
        } catch {
            loadError = String(
                format: String(localized: "Couldn't load details: %@", bundle: .module),
                error.localizedDescription
            )
        }
    }
}
