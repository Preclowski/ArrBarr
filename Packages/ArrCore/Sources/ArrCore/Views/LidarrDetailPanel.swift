import SwiftUI
import MediaKit

struct LidarrDetailPanel: View {
    let item: QueueItem
    @Environment(ConfigStore.self) var configStore
    let lidarrAlbum: ArrAlbum?
    let lidarrTracks: [ArrTrack]
    /// Joined per-track by `trackFileId` in the pushed track detail.
    var lidarrTrackFiles: [ArrFile] = []
    let siblings: [QueueItem]
    let hasActiveDownloads: Bool
    let loadError: String?
    var isLoading: Bool = false
    @Binding var enlargedPoster: URL?
    @Binding var selectedDiscNumber: Int?
    let arrWebURLForItem: (QueueItem) -> URL?
    /// The header CTA only drives the focused download, so two grabs of one album need per-row controls.
    var onPauseItem: ((QueueItem) -> Void)? = nil
    var onResumeItem: ((QueueItem) -> Void)? = nil
    var onDeleteItem: ((QueueItem) -> Void)? = nil
    /// This surface draws its own hero instead of `MediaHeaderCard`, so the host hands the toggle in.
    var posterCornerAction: AnyView? = nil
    /// nil leaves the artist line as plain text.
    var onOpenArtist: ((ArrArtist) -> Void)? = nil

    @State private var selectedTrack: ArrTrack?

    var body: some View {
        content
            .navigationDestination(item: $selectedTrack) { track in
                TrackDetailOverlay(
                    track: track,
                    file: track.trackFileId.flatMap { fid in lidarrTrackFiles.first { $0.id == fid } },
                    albumTitle: lidarrAlbum?.title ?? item.title,
                    artist: lidarrAlbum?.artist,
                    posterURL: lidarrAlbum?.coverURL(baseURL: configStore.lidarr.baseURL).0
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
                // Row spacing 0: rows already pad 4pt each, giving 8pt between track lines.
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

    private func albumFileState(_ stats: ArrStatistics) -> LibraryEntry.FileState {
        let have = stats.trackFileCount ?? 0
        let total = stats.totalTrackCount ?? 0
        if total > 0, have >= total { return .complete }
        return have > 0 ? .partial : .missing
    }

    private var lidarrHeaderCard: some View {
        let album = lidarrAlbum
        let posterUrl = arrPosterURL(images: album?.images, for: item, in: configStore)
            ?? arrPosterURL(images: album?.artist?.images, for: item, in: configStore)
        let resolvedURL = posterUrl ?? item.posterURL
        return HStack(alignment: .top, spacing: 12) {
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
                // No album title: the surface's header already carries it (`DetailView.navTitleString`).
                if let stats = album?.statistics {
                    MediaStateChip(
                        state: albumFileState(stats),
                        have: stats.trackFileCount,
                        total: stats.totalTrackCount,
                        locale: configStore.currentLocale
                    )
                }
                if let artist = album?.artist, let artistName = artist.artistName {
                    if let onOpenArtist {
                        Button { onOpenArtist(artist) } label: {
                            HStack(spacing: 3) {
                                Text(artistName)
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
                        Text(artistName)
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

    /// Same chrome as Sonarr's `seasonPillBar`; multi-disc albums only.
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
        // Green when every track is on disk, else no dot: Lidarr has no per-track queue
        // mapping here, so the header's download chip carries queue state.
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

    /// Explicit pick wins, else the first disc with missing tracks, else the lowest.
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
        return CachedDateFormatters.format("yyyy").string(from: date)
    }

    private var lidarrGenres: [String] { lidarrAlbum?.genres ?? [] }
}
