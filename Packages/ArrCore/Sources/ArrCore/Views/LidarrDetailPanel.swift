import SwiftUI

struct LidarrDetailPanel: View {
    let item: QueueItem
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    let lidarrAlbum: LidarrAlbumDetail?
    let lidarrTracks: [LidarrTrackDetail]
    let siblings: [QueueItem]
    let hasActiveDownloads: Bool
    let loadError: String?
    @Binding var enlargedPoster: URL?
    @Binding var selectedDiscNumber: Int?
    let arrWebURLForItem: (QueueItem) -> URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            lidarrHeaderCard
            if let overview = lidarrAlbum?.overview, !overview.isEmpty {
                ExpandableOverview(text: overview)
            }

            if hasActiveDownloads {
                DownloadSection(
                    items: siblings,
                    focused: item,
                    arrWebURLForItem: arrWebURLForItem
                )
            }

            if !lidarrTracks.isEmpty {
                Divider().padding(.vertical, 2)
                Text("detail.tracks.button", bundle: .module)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                let mediums = Dictionary(grouping: lidarrTracks, by: { $0.mediumNumber ?? 1 })
                    .sorted { $0.key < $1.key }
                // Track list owns its own tight spacing (4pt) — the
                // outer `VStack(spacing: 12)` was making every track
                // sit 12pt from the next, which read as "list of
                // sections" not "list of tracks". Mirrors the
                // episode-list spacing inside `SeasonRow`.
                if mediums.count > 1 {
                    discPillBar(mediums.map { $0.key })
                    let active = effectiveDiscNumber(in: mediums.map { $0.key }) ?? mediums.first!.key
                    let tracks = mediums.first(where: { $0.key == active })?.value ?? []
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(tracks.sorted(by: { ($0.absoluteTrackNumber ?? 0) < ($1.absoluteTrackNumber ?? 0) })) { track in
                            TrackRow(track: track)
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                } else {
                    let tracks = mediums.first?.value ?? []
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(tracks.sorted(by: { ($0.absoluteTrackNumber ?? 0) < ($1.absoluteTrackNumber ?? 0) })) { track in
                            TrackRow(track: track)
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 4)
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
        let poster = RemotePoster(
            url: resolvedURL,
            apiKey: item.posterRequiresAuth ? configStore.lidarr.apiKey : nil,
            size: CGSize(width: 110, height: 110),
            cornerRadius: Tokens.Radius.card,
            fallbackSymbol: "music.note"
        )
        return HStack(alignment: .top, spacing: 12) {
            // Tap the poster to raise the lightbox — same affordance
            // movie / series detail views ship. `lidarrHeaderCard`
            // used to render a bare `RemotePoster`, so clicking it
            // did nothing on this surface alone.
            Button {
                withAnimation(.smooth(duration: 0.22)) {
                    enlargedPoster = resolvedURL ?? item.posterURL
                }
            } label: { poster }
                .buttonStyle(.plain)
                .help(Text("detail.showPoster.button", bundle: .module))
            VStack(alignment: .leading, spacing: 4) {
                Text(album?.title ?? item.title)
                    .scaledFont(size: 15, weight: .semibold)
                    .lineLimit(2)
                if let artist = album?.artist?.artistName {
                    // Artist as subtitle — 12pt medium .secondary.
                    // Subordinate to the 15pt album title above but
                    // bumped from regular weight so it stays
                    // legible. Matches `EpisodeDetailOverlay`'s
                    // series-title treatment so the two detail
                    // surfaces share the same hierarchy language.
                    Text(artist)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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
                if let r = album?.ratings, let v = r.value, v > 0 {
                    HStack(spacing: 6) {
                        RatingPill(chip: RatingChip(label: "Rating", value: String(format: "%.1f", v), color: .yellow))
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
