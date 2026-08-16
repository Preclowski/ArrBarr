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
    /// Release-type sections the user folded shut (queue-view style). Keyed
    /// by the server's type string; empty = everything expanded.
    @State private var collapsedTypes: Set<String> = []
    /// Header pencil → edit panel push (profiles / root folder).
    @State private var editRequest: MediaEditRequest?

    /// What the header pencil edits — the artist record (Lidarr's profile-
    /// carrying entity).
    private var editTarget: MediaEditRequest? {
        guard let artistId = item.entityId else { return nil }
        return MediaEditRequest(source: .lidarr, entityId: artistId)
    }

    /// Artist bookmark, on the poster corner like every other detail surface.
    /// `nil` monitored (older Lidarr that doesn't report it, or the fetch
    /// still in flight) renders nothing rather than asserting a state.
    @ViewBuilder
    private var monitorPosterToggle: some View {
        if let monitored = artist?.monitored {
            MonitorPosterToggle(isMonitored: monitored, entity: .artist) { m in
                await setArtistMonitored(m)
            }
        }
    }

    /// Optimistic flip, then the PUT; a failure refetches so the bookmark
    /// snaps back to the server's truth. Mirrors `DetailView`.
    private func setArtistMonitored(_ monitored: Bool) async {
        guard let artistId = item.entityId else { return }
        artist?.monitored = monitored
        do {
            try await LidarrClient(config: configStore.lidarr)
                .setArtistMonitored(artistId: artistId, monitored: monitored)
        } catch {
            await load()
        }
    }

    var body: some View {
        ZStack {
            mainContent

            // Edit modal — scrim + bottom form card OVER the still-visible
            // artist surface (matches DetailView). iOS presents it as a
            // sheet instead.
            #if os(macOS)
            if let req = editRequest {
                MediaEditModalOverlay(request: req, onDismiss: { editRequest = nil })
                    .zIndex(6)
            }
            #endif
        }
        #if os(iOS)
        .sheet(item: $editRequest) { req in
            MediaEditPanel(request: req, onBack: { editRequest = nil })
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        #endif
    }

    private var mainContent: some View {
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
                if let target = editTarget {
                    Button { editRequest = target } label: {
                        Image(systemName: "pencil")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(Text("detail.edit.button", bundle: .module))
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
                // PersonView's inset scheme: header/overview padded to 14,
                // the album list full-bleed (its rows are PosterMetadataRow,
                // which self-insets 12) so rows don't sit doubly indented.
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
                    Button { editRequest = target } label: {
                        Image(systemName: "pencil")
                    }
                    .help(Text("detail.edit.button", bundle: .module))
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

    /// Lidarr's release taxonomy, in its own display order — albums first,
    /// then EPs / singles, everything else (Broadcast, Other, …) after.
    /// Types are server-side enum values ("Album", "EP", "Single"), shown
    /// verbatim as section headers.
    private var albumTypeGroups: [(type: String, albums: [LidarrAlbumListRecord])] {
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
            // One spacing-0 stack so the Upcoming-style header paddings
            // (14 above, 4 below) own ALL the vertical rhythm — nested in
            // the outer `VStack(spacing: 12)` directly, every header/rows
            // pair would pick up extra 12pt gaps.
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

    /// Section header for one release type — the Upcoming tab's Today /
    /// Tomorrow treatment (11pt semibold .secondary, 14pt above / 4pt
    /// below) plus the queue view's collapse affordance (rotating chevron,
    /// whole row tappable, count in the tertiary gutter).
    private func sectionHeader(
        for group: (type: String, albums: [LidarrAlbumListRecord]), isFirst: Bool
    ) -> some View {
        let collapsed = collapsedTypes.contains(group.type)
        return HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .scaledFont(size: 9, weight: .semibold)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: 10)
                .accessibilityHidden(true)
            // "Album" (the type) gets the plural header key; the other types
            // show the server's own name — they're Lidarr enum values, not
            // free text, and pluralising them per-language buys nothing
            // ("EP", "Single" read fine as-is).
            if group.type == "Album" {
                DetailSectionHeader("Albums", count: group.albums.count)
            } else {
                DetailSectionHeader(verbatim: group.type, count: group.albums.count)
            }
            Spacer(minLength: 0)
        }
        // 12pt inset mirrors the queue-view section header, so the chevron
        // column lines up with the rows' PosterMetadataRow inset below.
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

    /// One album row — the shared `PosterMetadataRow` chrome (same component
    /// as search results and Upcoming rows), so spacing, hover and the
    /// drill-in chevron can't drift from the rest of the app.
    private func albumRow(_ album: LidarrAlbumListRecord) -> some View {
        let (cover, coverAuth) = album.images?.posterURL(
            baseURL: configStore.lidarr.baseURL, coverTypes: ["cover", "poster"]) ?? (nil, false)
        let trackCount = album.statistics?.totalTrackCount ?? album.statistics?.trackCount ?? 0
        let fileCount = album.statistics?.trackFileCount ?? 0
        let complete = trackCount > 0 && fileCount >= trackCount
        // "12 utworów" / "8/12 utworów" — same plural the album detail uses;
        // incomplete albums prefix the on-disk count. (Type is NOT a segment —
        // the section header already says Album / EP / Single.)
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
                albumDetail = DetailRequest.syntheticItem(
                    source: .lidarr,
                    entityId: album.id,
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

    private func albumYear(_ album: LidarrAlbumListRecord) -> String? {
        guard let dateStr = album.releaseDate, let date = parseArrDate(dateStr) else { return nil }
        return CachedDateFormatters.format("yyyy").string(from: date)
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
