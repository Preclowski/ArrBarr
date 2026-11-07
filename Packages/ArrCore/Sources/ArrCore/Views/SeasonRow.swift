import SwiftUI
import MediaKit

/// The seasons block of a series detail, in the library or outside it.
struct SeasonSection<Rows: View>: View {
    let count: Int
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailSectionHeader("detail.seasons.button", count: count)
            VStack(spacing: 2, content: rows)
        }
    }
}

struct SeasonRow: View {
    let number: Int
    /// Sonarr's record; nil outside the library, where there are no files, queue or bookmark to show.
    var season: ArrSeason? = nil
    /// TMDB's record of the season: premiere, score and episode count.
    var tmdb: TMDBDetails.Airing? = nil
    var posterURL: URL? = nil
    var posterAPIKey: String? = nil
    var watched: Bool = false
    /// Taken by season number, not joined through episode ids: that join drops packs.
    var queueItems: [QueueItem] = []
    /// `nil` leaves the row without a chevron.
    var onTap: (() -> Void)? = nil
    /// `nil` keeps the bookmark an inert glyph.
    var onSetMonitored: ((Bool) async -> Void)? = nil
    /// Both nil leaves the row without a menu.
    var onAutomaticSearch: (() async throws -> Void)? = nil
    var onManualSearch: (() -> Void)? = nil
    /// The search toast's line, worded like the grab toast that follows it; the season alone without it.
    var searchTitle: String? = nil

    @State private var searchFeedback: SearchFeedback = .idle

    private var stats: ArrStatistics? { season?.statistics }
    private var have: Int { stats?.episodeFileCount ?? 0 }
    private var total: Int { stats?.totalEpisodeCount ?? stats?.episodeCount ?? 0 }
    private var anyDownloading: Bool { !queueItems.isEmpty }
    private var isUpgrade: Bool { queueItems.contains(where: \.isUpgrade) }
    private var isComplete: Bool { total > 0 && have >= total }
    /// Aired episodes, as the season detail's strip counts them.
    private var libraryMark: LibraryMark? {
        guard season != nil else { return nil }
        return LibraryMark(downloaded: EpisodeFileCounts(have: have, total: stats?.episodeCount ?? 0).isComplete)
    }
    /// Sonarr's own season flag. `nil` (older Sonarr / forks) reads as monitored.
    private var isMonitored: Bool { season?.monitored ?? true }
    private var premiere: Date? { tmdb?.airDate.flatMap(parseArrDate) }
    private var ratingChip: RatingChip? { tmdb?.voteAverage.flatMap { RatingChip.tmdb($0) } }
    private var episodeCount: String? {
        tmdb?.episodeCount.map {
            String.localizedStringWithFormat(NSLocalizedString("unit.episodes", bundle: .module, comment: ""), $0)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemotePoster(url: posterURL, apiKey: posterAPIKey, tier: .icon,
                         size: CGSize(width: 40, height: 60), cornerRadius: Tokens.Radius.chip,
                         fallbackSymbol: QueueItem.Source.sonarr.symbol)
                .posterMarks(watched: watched, library: libraryMark,
                             cornerRadius: Tokens.Radius.chip, ribbonWidth: 7)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    // Not inside a Button: the row is a tap gesture, so the bookmark's own Button wins.
                    if season != nil {
                        MonitorRowToggle(isMonitored: isMonitored, entity: .season, onToggle: onSetMonitored)
                    }
                    Text(EpisodeCode.paddedSeasonName(number))
                        .scaledFont(size: 12)
                        .lineLimit(1)
                        .opacity(isMonitored ? 1 : 0.55)
                    if onTap != nil {
                        LinkChevron(size: 9)
                    }
                    Spacer(minLength: 4)
                    // The context menu closes on click, so the row shows the sweep itself.
                    SearchFeedbackIcon(feedback: searchFeedback)
                    if anyDownloading {
                        MediaBadgeCluster(isUpgrade: isUpgrade)
                    }
                }
                Group {
                    HStack(spacing: 4) {
                        if season != nil {
                            Text(verbatim: "\(have)/\(total)")
                                .foregroundStyle(isComplete ? Color.green : Color.secondary)
                        } else if let episodeCount {
                            Text(verbatim: episodeCount)
                        }
                        if let premiere {
                            if season != nil || episodeCount != nil {
                                Text(verbatim: "·")
                            }
                            Text(premiere, format: .dateTime.day().month(.abbreviated).year())
                        }
                        if let size = stats?.sizeOnDisk, size > 0 {
                            Text(verbatim: "·")
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        }
                    }
                    .scaledFont(size: 10, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    if let ratingChip {
                        RatingPill(chip: ratingChip)
                    }
                }
                .opacity(isMonitored ? 1 : 0.55)
            }
        }
        // No horizontal inset, so the row lines up with the section header.
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .modifier(RowTapToOpen(action: onTap))
        // Before the combined element and the menu, as on the other rows whose chevron lights.
        .linkRowHover()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onTap != nil ? .isButton : [])
        .accessibilityValue(
            isMonitored ? Text(verbatim: "")
                        : Text("common.notMonitored.label", bundle: .module)
        )
        .modifier(OptionalRowSearchMenu(
            feedback: $searchFeedback, detail: searchTitle ?? EpisodeCode.seasonName(number),
            onAutomatic: onAutomaticSearch, onManual: onManualSearch))
    }
}
