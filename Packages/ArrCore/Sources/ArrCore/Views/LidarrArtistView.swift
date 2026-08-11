import SwiftUI

/// Artist-level surface for Lidarr. Search results, the post-add navigation
/// and the chat library cards all carry an ARTIST id (Lidarr's addable entity
/// is the artist), so they land here: artist header + the album list, each
/// album drilling into the existing album `DetailView`. Queue rows keep going
/// straight to the album detail — their `entityId` is an album id.
struct LidarrArtistView: View {
    /// Synthetic artist item (`DetailRequest.syntheticArtistItem`) —
    /// `entityId` is the Lidarr artist id.
    let item: QueueItem
    let onBack: () -> Void
    var originLabel: LocalizedStringKey = "Details"
    var viewModel: QueueViewModel

    @EnvironmentObject private var configStore: ConfigStore

    @State private var artist: LidarrArtistDetail?
    @State private var albums: [LidarrAlbumListRecord] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var enlargedPoster: URL?
    /// Album drill-down, owned locally (like PersonView's `titleDetail`) so
    /// back from the album returns HERE, not to the queue.
    @State private var albumDetail: QueueItem?

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Popover hides the native chevron and the detached window never
            // draws one — self-drawn back header, same as DetailView/PersonView.
            HStack(spacing: 6) {
                FloatingBackButton(action: onBack)
                    .keyboardShortcut(.cancelAction)
                Text(artist?.artistName ?? item.title)
                    .scaledFont(size: 15, weight: .semibold)
                    .lineLimit(1)
                Spacer(minLength: 0)
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
                VStack(alignment: .leading, spacing: 12) {
                    headerCard
                    if let overview = artist?.overview, !overview.isEmpty {
                        ExpandableOverview(text: overview)
                    } else if loading {
                        SkeletonLines(count: 3)
                    }
                    albumSection
                    if let err = loadError {
                        LoadErrorLine(message: err)
                    }
                }
                .padding(.horizontal, 14)
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
            if let url = artistWebURL {
                ToolbarItem(placement: .primaryAction) {
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
                originLabel: originLabel,
                viewModel: viewModel
            )
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        let posterUrl = arrPosterURL(images: artist?.images, for: item, in: configStore)
        let resolvedURL = posterUrl ?? item.posterURL
        return HStack(alignment: .top, spacing: 12) {
            Button {
                withAnimation(.smooth(duration: 0.22)) {
                    enlargedPoster = resolvedURL
                }
            } label: {
                RemotePoster(
                    url: resolvedURL,
                    apiKey: item.posterRequiresAuth ? configStore.lidarr.apiKey : nil,
                    size: CGSize(width: 110, height: 110),
                    cornerRadius: Tokens.Radius.card,
                    fallbackSymbol: "music.mic"
                )
            }
            .buttonStyle(.plain)
            .help(Text("detail.showPoster.button", bundle: .module))

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
                if let r = artist?.ratings, let v = r.value, v > 0 {
                    HStack(spacing: 6) {
                        RatingPill(chip: RatingChip(label: "Rating", value: String(format: "%.1f", v), color: .yellow))
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Album list

    @ViewBuilder
    private var albumSection: some View {
        Text("Albums", bundle: .module)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
        if albums.isEmpty {
            if loading {
                SkeletonRows(count: 6)
                    .padding(.top, 6)
            } else if loadError == nil {
                Text("person.noTitles.label", bundle: .module)
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(albums) { album in
                    albumRow(album)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
    }

    private func albumRow(_ album: LidarrAlbumListRecord) -> some View {
        let (cover, coverAuth) = album.images?.posterURL(
            baseURL: configStore.lidarr.baseURL, coverTypes: ["cover", "poster"]) ?? (nil, false)
        let trackCount = album.statistics?.totalTrackCount ?? album.statistics?.trackCount ?? 0
        let fileCount = album.statistics?.trackFileCount ?? 0
        let complete = trackCount > 0 && fileCount >= trackCount
        return Button {
            albumDetail = DetailRequest.syntheticItem(
                source: .lidarr,
                entityId: album.id,
                title: album.title,
                posterURL: cover,
                posterRequiresAuth: coverAuth
            )
        } label: {
            HStack(spacing: 10) {
                RemotePoster(
                    url: cover,
                    apiKey: coverAuth ? configStore.lidarr.apiKey : nil,
                    size: CGSize(width: 44, height: 44),
                    cornerRadius: Tokens.Radius.chip,
                    fallbackSymbol: "music.note"
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let year = albumYear(album) {
                            Text(year)
                        }
                        if let type = album.albumType, !type.isEmpty {
                            SeparatorDot()
                            Text(type)
                        }
                        if trackCount > 0 {
                            SeparatorDot()
                            // "8/12" file coverage; complete albums show a
                            // green dot after it instead of restating N/N.
                            Text(verbatim: complete ? "\(trackCount)" : "\(fileCount)/\(trackCount)")
                            if complete {
                                Circle().fill(Color.green).frame(width: 4, height: 4)
                            }
                        }
                    }
                    .scaledFont(size: 10.5)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if album.monitored == false {
                    Image(systemName: "bookmark.slash")
                        .scaledFont(size: 10)
                        .foregroundStyle(.tertiary)
                        .help(Text("Unmonitored", bundle: .module))
                }
                LinkChevron()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func albumYear(_ album: LidarrAlbumListRecord) -> String? {
        guard let dateStr = album.releaseDate, let date = parseArrDate(dateStr) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy"
        return f.string(from: date)
    }

    /// Lidarr's web UI keys artists by `foreignArtistId` — only known after
    /// the fetch, so the link appears once the record lands.
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
        let client = LidarrClient(config: configStore.lidarr)
        async let a = client.fetchArtistDetails(id: artistId)
        async let al = client.fetchArtistAlbums(artistId: artistId)
        do {
            artist = try await a
            // Newest first — same order Lidarr's own artist page defaults to.
            albums = try await al.sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
        } catch {
            loadError = String(
                format: String(localized: "Couldn't load details: %@", bundle: .module),
                error.localizedDescription
            )
        }
    }
}
