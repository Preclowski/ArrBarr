import SwiftUI

struct LidarrDetailPanel: View {
    let item: QueueItem
    @EnvironmentObject var configStore: ConfigStore
    let lidarrAlbum: LidarrAlbumDetail?
    let lidarrTracks: [LidarrTrackDetail]
    /// `/trackfile` records for this album — joined per-track by
    /// `trackFileId` in the pushed track detail.
    var lidarrTrackFiles: [LidarrTrackFile] = []
    let siblings: [QueueItem]
    let hasActiveDownloads: Bool
    let loadError: String?
    /// Album fetch still in flight — overview + track list show a skeleton
    /// instead of nothing, so the view fills in element-by-element.
    var isLoading: Bool = false
    @Binding var enlargedPoster: URL?
    @Binding var selectedDiscNumber: Int?
    let arrWebURLForItem: (QueueItem) -> URL?
    /// Per-item queue actions for the multi-download list — see
    /// RadarrDetailPanel; two active grabs of the same album need per-row
    /// controls because the header CTA only drives the focused one.
    var onPauseItem: ((QueueItem) -> Void)? = nil
    var onResumeItem: ((QueueItem) -> Void)? = nil
    var onDeleteItem: ((QueueItem) -> Void)? = nil
    /// The album's monitor bookmark, pinned to the poster's top-right corner.
    /// This surface draws its OWN hero (square art, artist subtitle) instead
    /// of `MediaHeaderCard`, so the host hands the toggle in rather than
    /// setting `posterCornerAction` on the shared card.
    var posterCornerAction: AnyView? = nil
    /// Tap on the artist line under the album title — pushes the artist
    /// view (album list). nil leaves the line as plain text.
    var onOpenArtist: ((LidarrArtist) -> Void)? = nil

    /// Tapped track — pushes the per-track detail (file quality / size),
    /// the audio counterpart of the episode detail.
    @State private var selectedTrack: LidarrTrackDetail?

    var body: some View {
        content
            .navigationDestination(item: $selectedTrack) { track in
                TrackDetailOverlay(
                    track: track,
                    file: track.trackFileId.flatMap { fid in lidarrTrackFiles.first { $0.id == fid } },
                    albumTitle: lidarrAlbum?.title ?? item.title,
                    artist: lidarrAlbum?.artist,
                    posterURL: arrPosterURL(images: lidarrAlbum?.images, for: item, in: configStore)
                        ?? arrPosterURL(images: lidarrAlbum?.artist?.images, for: item, in: configStore)
                        ?? item.posterURL,
                    posterAPIKey: item.posterRequiresAuth ? configStore.lidarr.apiKey : nil,
                    onOpenArtist: onOpenArtist,
                    onClose: { selectedTrack = nil }
                )
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            lidarrHeaderCard
            if let overview = lidarrAlbum?.overview, !overview.isEmpty {
                ExpandableOverview(text: overview)
            } else if isLoading {
                SkeletonLines(count: 3)
            }

            if hasActiveDownloads {
                DownloadSection(
                    items: siblings,
                    focused: item,
                    onPauseItem: onPauseItem,
                    onResumeItem: onResumeItem,
                    onDeleteItem: onDeleteItem,
                    arrWebURLForItem: arrWebURLForItem
                )
            }

            if !lidarrTracks.isEmpty {
                // Header + list share a 6pt stack (the CastRow rhythm) —
                // as siblings of the outer `VStack(spacing: 12)` the label
                // floated 12pt above its own list. Row spacing is 0: rows
                // already pad 4pt each, so that yields 8pt between track
                // lines — a dense tracklist; any stack spacing on top read
                // as unnatural daylight between bare single-line rows.
                VStack(alignment: .leading, spacing: 6) {
                    DetailSectionHeader(
                        "detail.tracks.button",
                        have: lidarrTracks.count { $0.hasFile == true },
                        total: lidarrTracks.count
                    )
                    let mediums = Dictionary(grouping: lidarrTracks, by: { $0.mediumNumber ?? 1 })
                        .sorted { $0.key < $1.key }
                    if mediums.count > 1 {
                        discPillBar(mediums.map { $0.key })
                        let active = effectiveDiscNumber(in: mediums.map { $0.key }) ?? mediums.first!.key
                        let tracks = mediums.first(where: { $0.key == active })?.value ?? []
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(tracks.sorted(by: { ($0.absoluteTrackNumber ?? 0) < ($1.absoluteTrackNumber ?? 0) })) { track in
                                TrackRow(track: track) { selectedTrack = track }
                            }
                        }
                    } else {
                        let tracks = mediums.first?.value ?? []
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(tracks.sorted(by: { ($0.absoluteTrackNumber ?? 0) < ($1.absoluteTrackNumber ?? 0) })) { track in
                                TrackRow(track: track) { selectedTrack = track }
                            }
                        }
                    }
                }
            } else if isLoading {
                VStack(alignment: .leading, spacing: 6) {
                    DetailSectionHeader("detail.tracks.button")
                    SkeletonRows(count: 8)
                }
            }
            if let err = loadError {
                LoadErrorLine(message: err)
            }
        }
    }

    private var lidarrHeaderCard: some View {
        let album = lidarrAlbum
        let posterUrl = arrPosterURL(images: album?.images, for: item, in: configStore)
            ?? arrPosterURL(images: album?.artist?.images, for: item, in: configStore)
        let resolvedURL = posterUrl ?? item.posterURL
        return HStack(alignment: .top, spacing: 12) {
            // Same hero component the movie / series / episode surfaces use —
            // square art here (album covers are 1:1), but the tap affordance
            // and the bookmark corner come from one place.
            DetailHeroPoster(
                url: resolvedURL,
                apiKey: item.posterRequiresAuth ? configStore.lidarr.apiKey : nil,
                size: CGSize(width: 110, height: 110),
                fallbackSymbol: "music.note",
                cornerAction: posterCornerAction,
                onTap: { url in
                    withAnimation(.smooth(duration: 0.22)) { enlargedPoster = url }
                }
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(album?.title ?? item.title)
                        .scaledFont(size: 15, weight: .semibold)
                        .lineLimit(2)
                    // Library chip — any track file on disk makes the album
                    // library-owned. Title-level fact, so it rides the title
                    // (same slot the movie / series heroes use).
                    if (album?.statistics?.trackFileCount ?? 0) > 0 {
                        InLibraryBadge()
                    }
                }
                if let artist = album?.artist {
                    // Artist as subtitle — 12pt medium .secondary.
                    // Subordinate to the 15pt album title above but
                    // bumped from regular weight so it stays
                    // legible. Matches `EpisodeDetailOverlay`'s
                    // series-title treatment so the two detail
                    // surfaces share the same hierarchy language.
                    // Tappable (chevron) when the host wires
                    // `onOpenArtist` — pushes the artist's album list,
                    // mirroring the episode hero's "series name >" tap.
                    if let onOpenArtist {
                        Button { onOpenArtist(artist) } label: {
                            HStack(spacing: 3) {
                                Text(artist.artistName)
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                LinkChevron()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(Text("detail.showArtist.button", bundle: .module))
                    } else {
                        Text(artist.artistName)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                HStack(spacing: 6) {
                    if let year = lidarrYear {
                        Text(year).foregroundStyle(.secondary)
                    }
                    if let type = album?.albumType, !type.isEmpty {
                        SeparatorDot()
                        Text(type).foregroundStyle(.secondary)
                    }
                    if let stats = album?.statistics, let count = stats.totalTrackCount, count > 0 {
                        SeparatorDot()
                        Text("\(count) tracks", bundle: .module).foregroundStyle(.secondary)
                    }
                    if let dur = album?.duration, dur > 0 {
                        SeparatorDot()
                        Text(formatDuration(ms: dur)).foregroundStyle(.secondary)
                    }
                }
                .scaledFont(size: 11)
                if !lidarrGenres.isEmpty {
                    GenreChips(genres: lidarrGenres)
                }
                if let v = album?.ratings?.value,
                   let chip = RatingChip.plain(v, votes: album?.ratings?.votes) {
                    HStack(spacing: 6) {
                        RatingPill(chip: chip)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Wrapping pill-row of disc selectors. Same chrome as Sonarr's
    /// `seasonPillBar` — capsule, mono weight active state, optional
    /// status dot. Used only for multi-disc albums.
    @ViewBuilder
    private func discPillBar(_ discs: [Int]) -> some View {
        let active = effectiveDiscNumber(in: discs)
        TooltipFlowLayout(spacing: 6) {
            ForEach(discs, id: \.self) { d in
                discPill(d, isActive: d == active)
            }
        }
    }

    @ViewBuilder
    private func discPill(_ disc: Int, isActive: Bool) -> some View {
        // Dot states (mirroring seasonPill): green when every track
        // on this disc is on-disk, no dot otherwise. There's no
        // per-track queue mapping for Lidarr in the current detail
        // view, so we skip the blue/orange queue tints — the album-
        // level download chip in the header carries that signal.
        let discTracks = lidarrTracks.filter { ($0.mediumNumber ?? 1) == disc }
        let complete = !discTracks.isEmpty && discTracks.allSatisfy { $0.hasFile == true }
        Button {
            withAnimation(.smooth(duration: 0.2)) {
                selectedDiscNumber = disc
            }
        } label: {
            HStack(spacing: 4) {
                Text(String(format: String(localized: "detail.discLld.label", bundle: .module), disc))
                    .scaledFont(size: 10, weight: isActive ? .semibold : .medium)
                    .foregroundStyle(isActive ? .primary : .secondary)
                if complete {
                    Circle()
                        .fill(isActive ? Color.green : Color.green.opacity(0.7))
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isActive ? Color.primary.opacity(0.12) : Color.clear)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        Color.primary.opacity(isActive ? 0 : 0.18),
                        lineWidth: 0.6
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Resolves which disc's content to show. User explicit pick
    /// wins; otherwise default to the first disc with missing
    /// tracks (most likely where the user wants to look), else
    /// fall back to the lowest disc number.
    private func effectiveDiscNumber(in discs: [Int]) -> Int? {
        if let picked = selectedDiscNumber, discs.contains(picked) {
            return picked
        }
        if let firstMissing = discs.first(where: { d in
            lidarrTracks.contains { ($0.mediumNumber ?? 1) == d && $0.hasFile != true }
        }) {
            return firstMissing
        }
        return discs.min()
    }

    private var lidarrYear: String? {
        guard let dateStr = lidarrAlbum?.releaseDate, let date = parseArrDate(dateStr) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy"
        return f.string(from: date)
    }

    private var lidarrGenres: [String] { lidarrAlbum?.genres ?? [] }
}
