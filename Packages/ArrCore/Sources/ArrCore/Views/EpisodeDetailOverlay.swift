import SwiftUI
import MediaKit

/// Episode detail pushed on top of `DetailView` from an `EpisodeRow`.
struct EpisodeDetailOverlay: View {
    let episode: ArrEpisode
    let seriesTitle: String
    let posterURL: URL?
    let posterRequiresAuth: Bool
    let apiKey: String?
    /// Taken from the parent's already-loaded episode files, which also works in demo.
    let episodeFile: ArrFile?
    /// All active downloads for this episode; 2+ when it was grabbed twice, each then gets its own controls.
    let queueItems: [QueueItem]
    private var queueItem: QueueItem? { queueItems.first }
    let onClose: () -> Void
    let onSearch: ((Int) async throws -> Void)?
    /// Async so the Pause/Resume CTA can show a spinner until the action and its queue refresh complete.
    let onPauseEpisode: ((QueueItem) async -> Void)?
    let onResumeEpisode: ((QueueItem) async -> Void)?
    let onDeleteEpisode: ((QueueItem) -> Void)?
    /// Set when opened from the queue: tapping the series title pushes the series. `nil` = inert text.
    let onTapSeries: (() -> Void)?
    /// `nil` leaves "Season N" as inert text.
    let onTapSeason: (() -> Void)?
    let seriesYear: Int?
    /// Borrowed from the series — an episode has no genres or age rating of its own.
    var genres: [String] = []
    var certification: String? = nil
    var seriesTmdbId: Int? = nil
    var seriesTvdbId: Int? = nil
    var profileName: String? = nil
    /// Provider ids of the SERIES, for the media server's watch state.
    var mediaServerKeys: [MediaServerExternalKey] = []
    /// The SERIES cast (TMDB has no per-episode credits worth the extra call).
    var cast: [CastMember] = []
    /// The series in the arr's web UI: "Open in browser", and the warning banners, whose
    /// `statusMessages` are mostly only actionable there.
    let seriesWebURL: URL?
    var isLoadingDetails: Bool = false
    /// Passed explicitly: `episode` is the snapshot captured by `.navigationDestination(item:)`,
    /// so reading the flag from it would never change after a toggle.
    var monitored: Bool? = nil
    var onToggleMonitored: ((Bool) async -> Void)? = nil
    /// The parent reloads its files; nil offers no file delete.
    var onFileDeleted: (() -> Void)? = nil
    /// The queue row this opened from, whose context menu may have staged an intent for it.
    var intentItemID: String? = nil

    @ViewBuilder
    private var monitorPosterToggle: some View {
        if let monitored {
            MonitorPosterToggle(isMonitored: monitored, entity: .episode, onToggle: onToggleMonitored)
        }
    }

    @State private var searchFeedback: SearchFeedback = .idle
    @State private var actionState = DetailActionState()
    @State private var ctaPendingDelete = false
    @State private var enlargedPoster: URL?
    /// Own wrapper type: SwiftUI ignores all but the root-most `.navigationDestination` for a type,
    /// so reusing the parent's `ManualSearchTarget` would collide.
    @State private var manualSearchTarget: EpisodeReleaseSearch?
    /// Owned here: this overlay is its own stack entry, so the host's person destination would sit below it.
    @State private var personRef: PersonRef?
    @State private var episodeRating: EpisodeRatingProvider.Rating?
    @EnvironmentObject private var configStore: ConfigStore

    private var hasAired: Bool {
        guard let air = episode.airDateUtc.flatMap(parseArrDate) else { return true }
        return air <= Date()
    }

    private var navTitleString: String {
        String(format: String(localized: "detail.episodeLld.label", bundle: .module),
               episode.episodeNumber ?? 0)
    }

    private var seasonLabel: String {
        String(format: String(localized: "detail.seasonLld.label", bundle: .module),
               episode.seasonNumber ?? 0)
    }

    private var seriesTitleWithYear: String {
        if let year = seriesYear { return "\(seriesTitle) (\(year))" }
        return seriesTitle
    }

    init(
        episode: ArrEpisode,
        seriesTitle: String,
        posterURL: URL?,
        posterRequiresAuth: Bool,
        apiKey: String?,
        episodeFile: ArrFile? = nil,
        queueItems: [QueueItem] = [],
        onClose: @escaping () -> Void,
        onSearch: ((Int) async throws -> Void)?,
        seriesWebURL: URL? = nil,
        onPauseEpisode: ((QueueItem) async -> Void)? = nil,
        onResumeEpisode: ((QueueItem) async -> Void)? = nil,
        onDeleteEpisode: ((QueueItem) -> Void)? = nil,
        onTapSeries: (() -> Void)? = nil,
        onTapSeason: (() -> Void)? = nil,
        seriesYear: Int? = nil,
        cast: [CastMember] = [],
        genres: [String] = [],
        certification: String? = nil,
        seriesTmdbId: Int? = nil,
        seriesTvdbId: Int? = nil,
        profileName: String? = nil,
        mediaServerKeys: [MediaServerExternalKey] = [],
        isLoadingDetails: Bool = false,
        monitored: Bool? = nil,
        onToggleMonitored: ((Bool) async -> Void)? = nil,
        onFileDeleted: (() -> Void)? = nil,
        intentItemID: String? = nil
    ) {
        self.episode = episode
        self.seriesTitle = seriesTitle
        self.posterURL = posterURL
        self.posterRequiresAuth = posterRequiresAuth
        self.apiKey = apiKey
        self.episodeFile = episodeFile
        self.queueItems = queueItems
        self.onClose = onClose
        self.onSearch = onSearch
        self.seriesWebURL = seriesWebURL
        self.onPauseEpisode = onPauseEpisode
        self.onResumeEpisode = onResumeEpisode
        self.onDeleteEpisode = onDeleteEpisode
        self.onTapSeries = onTapSeries
        self.onTapSeason = onTapSeason
        self.seriesYear = seriesYear
        self.cast = cast
        self.genres = genres
        self.certification = certification
        self.seriesTmdbId = seriesTmdbId
        self.seriesTvdbId = seriesTvdbId
        self.profileName = profileName
        self.mediaServerKeys = mediaServerKeys
        self.isLoadingDetails = isLoadingDetails
        self.monitored = monitored
        self.onToggleMonitored = onToggleMonitored
        self.onFileDeleted = onFileDeleted
        self.intentItemID = intentItemID
    }

    var body: some View {
        // No solid scrim — it would kill the popover's translucent chrome; DetailView hides itself underneath.
        VStack(spacing: 0) {
            // macOS self-draws the header on both surfaces: the detached window has no chevron and the parent
            // DetailView hides the popover's toolbar, so without it there is no way back.
            #if os(macOS)
            HStack(spacing: 6) {
                FloatingBackButton(action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(Text("settings.back.button", bundle: .module))
                Text(navTitleString)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                headerMenu
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            // 4pt, matching DetailView / SeasonDetailView, so the hero doesn't shift when pushing season → episode.
            .padding(.bottom, 4)
            #endif
            ScrollView {
                content
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if shouldShowCTAStrip {
                    episodeCTAStrip
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .posterLightbox(
            url: $enlargedPoster,
            apiKey: posterRequiresAuth ? apiKey : nil,
            aspectRatio: 2.0 / 3.0
        )
        .task(id: episode.id) {
            episodeRating = await EpisodeRatingProvider.rating(
                tmdbId: seriesTmdbId, tvdbId: seriesTvdbId,
                season: episode.seasonNumber, episode: episode.episodeNumber,
                configStore: configStore)
        }
        .personDestination($personRef)
        .navigationDestination(item: $manualSearchTarget) { wrapper in
            ReleaseListView(target: wrapper.target,
                            existing: episodeFile.map(UpgradeDiffView.side(file:)),
                            waitContext: WaitCardContext(seriesYear: seriesYear, cast: cast, posterURL: posterURL),
                            onBack: { manualSearchTarget = nil })
        }
        .detailActionsHost($actionState) { _ in onFileDeleted?() }
        .onDetailIntent(for: intentItemID, ready: !isLoadingDetails) { detailActions.carryOut($0, state: $actionState) }
        #if os(iOS)
        .navigationTitle(navTitleString)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                headerMenu
                // With duplicate downloads each block has its own trash, so a toolbar one would be ambiguous.
                if queueItems.count == 1, onDeleteEpisode != nil {
                    Button { PanelActivation.bringForward(); ctaPendingDelete = true } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(.red)
                    .help(Text("queue.cancelDownload.button", bundle: .module))
                    .accessibilityLabel(Text("queue.cancelDownload.button", bundle: .module))
                    .accessibilityHint(Text("This will remove the download from the client.", bundle: .module))
                }
            }
        }
        #else
        .toolbar(.hidden, for: .windowToolbar)
        #endif
        // `.confirmationDialog` doesn't work inside MenuBarExtra panels (see InlineConfirm.swift).
        .inlineConfirm(
            isPresented: $ctaPendingDelete,
            title: "Remove this download?",
            message: LocalizedStringKey("This will remove the download from the client."),
            confirmLabel: "Remove",
            isDestructive: true,
            onConfirm: {
                if let q = queueItem { onDeleteEpisode?(q); onClose() }
            }
        )
        // Per-download cancel on the duplicate path deliberately does not close the overlay: the other download is still live.
    }

    private var shouldShowCTAStrip: Bool {
        queueItems.count == 1
            && (queueItem?.status == .downloading || queueItem?.status == .paused)
            && ((queueItem?.isPaused == true && onResumeEpisode != nil)
                || (queueItem?.isPaused == false && onPauseEpisode != nil))
    }

    /// Only for a single active download; with duplicates each block controls its own.
    @ViewBuilder
    private var episodeCTAStrip: some View {
        let canPauseResume = queueItems.count == 1
            && (queueItem?.status == .downloading || queueItem?.status == .paused)
            && ((queueItem?.isPaused == true && onResumeEpisode != nil)
                || (queueItem?.isPaused == false && onPauseEpisode != nil))
        HStack(spacing: 8) {
            if canPauseResume, let q = queueItem {
                ctaPauseResume(q: q)
                #if os(macOS)
                if onDeleteEpisode != nil {
                    ctaCancelProminent
                }
                #endif
            }
        }
    }

    private var headerMenu: some View {
        DetailActionsMenu(actions: detailActions, state: $actionState, feedback: searchFeedback)
    }

    /// Search once aired; an episode has no record to edit, and delete takes only its file.
    private var detailActions: DetailActions {
        var actions = DetailActions(webURL: seriesWebURL)
        if hasAired {
            actions.search = DetailActions.Search(
                isSending: searchFeedback.isSending,
                onAutomatic: onSearch.map { _ in { performSearch() } },
                onManual: { manualSearchTarget = EpisodeReleaseSearch(target: .episode(episodeId: episode.id, title: navTitleString)) })
        }
        // id 0 is the queue's pre-fetch stub.
        guard let seriesId = episode.seriesId, episode.id != 0 else { return actions }
        let title = "\(seriesTitle) · \(EpisodeCode.string(season: episode.seasonNumber ?? 0, episode: episode.episodeNumber ?? 0))"
        actions.history = HistoryTarget(source: .sonarr, scope: .episode(seriesId: seriesId, episodeId: episode.id), title: title)
        if let fileId = episodeFile?.id, onFileDeleted != nil {
            actions.delete = MediaDeleteRequest(source: .sonarr, target: .episodeFile(id: fileId, seriesId: seriesId), title: title)
            actions.deleteLabel = "detail.deleteFile.button"
        }
        return actions
    }

    @ViewBuilder
    private func ctaPauseResume(q: QueueItem) -> some View {
        // Action tint, not status tint — see DetailView.pauseResumeProminent.
        PauseResumeButton(isPaused: q.isPaused, progress: q.progress, tint: q.isPaused ? .blue : .orange) {
            if q.isPaused { await onResumeEpisode?(q) } else { await onPauseEpisode?(q) }
        }
        // The ring is the only place this completion shows, so VoiceOver gets it as the value.
        .accessibilityValue(Text(max(0.0, min(1.0, q.progress)), format: .percent.precision(.fractionLength(0))))
    }

    @ViewBuilder
    private var ctaCancelProminent: some View {
        Button { PanelActivation.bringForward(); ctaPendingDelete = true } label: {
            Image(systemName: "xmark")
                .scaledFont(size: 13, weight: .bold)
                .frame(width: 26)
                .padding(.vertical, 7)
        }
        .modifier(GlassProminentButtonStyle())
        .tint(.red)
        .help(Text("queue.cancelDownload.button", bundle: .module))
        .accessibilityLabel(Text("queue.cancelDownload.button", bundle: .module))
        // "Cancel download" alone doesn't say the client loses the transfer.
        .accessibilityHint(Text("This will remove the download from the client.", bundle: .module))
    }

    private var episodeHeroTitle: String {
        if let title = episode.title, !title.isEmpty { return title }
        return isLoadingDetails ? "" : "—"
    }

    /// Empty without a TMDB key; the card then has no rating row.
    private var ratingChips: [RatingChip] {
        guard let episodeRating else { return [] }
        return [RatingChip.tmdb(episodeRating.value, votes: episodeRating.votes)].compactMap { $0 }
    }

    private var airDateText: String? {
        episode.airDateUtc.flatMap(parseArrDate).map { Self.airFormatter.string(from: $0) }
    }

    @ViewBuilder
    private var heroBadges: some View {
        HStack(spacing: 4) {
            if let profileName { ProfileChip(name: profileName) }
            if episode.hasFile == true {
                LibraryStateBadge(isDownloaded: true)
            }
            if !hasAired {
                Text("detail.unaired.button", bundle: .module)
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .chipOutline(.orange)
            }
        }
    }

    /// Series-level watch state says nothing about one episode.
    private var isWatched: Bool {
        MediaServerIndex.shared.isWatched(mediaServerKeys,
                                          season: episode.seasonNumber,
                                          episode: episode.episodeNumber)
    }

    /// Not `titleBadge`: that slot renders on the title's own line.
    @ViewBuilder
    private var seriesContextLinks: some View {
        VStack(alignment: .leading, spacing: 4) {
            heroBadges
            if let onTapSeries {
                Button(action: onTapSeries) {
                    HStack(spacing: 4) {
                        Text(seriesTitleWithYear)
                            .scaledFont(size: 12, weight: .medium)
                            .lineLimit(2)
                            // `.secondary` reads as half-faded over the popover's vibrant backdrop.
                            .foregroundStyle(.primary)
                        LinkChevron(size: 9)
                            .accessibilityHidden(true)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .linkRowHover()
            }
            if let onTapSeason {
                Button(action: onTapSeason) {
                    HStack(spacing: 4) {
                        Text(verbatim: seasonLabel)
                            .scaledFont(size: 12, weight: .medium)
                            .lineLimit(1)
                        LinkChevron(size: 9)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .linkRowHover()
            } else if onTapSeries == nil {
                Text(verbatim: seasonLabel)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The shared hero every detail surface draws, so poster tier, crop and title size can't drift.
            MediaHeaderCard(
                title: episodeHeroTitle,
                runtime: episode.runtime,
                certification: certification,
                extraMetadata: airDateText.map { [$0] } ?? [],
                genres: genres,
                ratings: ratingChips,
                overview: episode.overview,
                posterURL: posterURL,
                posterRequiresAuth: posterRequiresAuth,
                apiKey: apiKey,
                fallbackSymbol: "tv",
                // Spelled out, not defaulted: the series, season and episode heroes must draw artwork identically.
                posterAspect: 2.0 / 3.0,
                blurred: false,
                onPosterTap: { url in
                    withAnimation(.smooth(duration: 0.22)) { enlargedPoster = url }
                },
                posterCornerAction: AnyView(monitorPosterToggle),
                aboveTitle: AnyView(seriesContextLinks),
                watched: isWatched,
                metadataLoading: isLoadingDetails
            )

            if !cast.isEmpty {
                CastRow(cast: cast, onTapPerson: { member in
                    if let ref = PersonRef(castMember: member) { personRef = ref }
                })
            }

            if queueItem != nil || (episode.hasFile == true && episodeFile != nil) {
                fileSection
            }

        }
    }

    @ViewBuilder
    private var fileSection: some View {
        if queueItems.count > 1 {
            duplicateDownloadsSection
        } else if let q = queueItem, let existing = episodeFile, episode.hasFile == true {
            queueFileWithDiff(new: q, existing: existing)
        } else if let q = queueItem {
            queueFileSection(q)
        } else if let existing = episodeFile {
            VStack(alignment: .leading, spacing: 6) {
                DetailSectionHeader("Existing file")
                ExistingFileBanner(file: existing)
            }
        }
    }

    /// The bottom CTA strip is suppressed here (one pause would be ambiguous); the shared on-disk file renders once below.
    @ViewBuilder
    private var duplicateDownloadsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("queue.inQueue.button", bundle: .module)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                SeparatorDot()
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("unit.downloads", bundle: .module, comment: ""),
                    queueItems.count
                ))
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
            }
            ForEach(queueItems) { q in
                duplicateDownloadBlock(q)
            }
            if let existing = episodeFile, episode.hasFile == true {
                VStack(alignment: .leading, spacing: 6) {
                    DetailSectionHeader("Existing file")
                    ExistingFileBanner(file: existing)
                }
            }
        }
    }

    /// The release name is what tells two grabs of the same episode apart.
    @ViewBuilder
    private func duplicateDownloadBlock(_ q: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MultiRow(
                item: q,
                onPause: { Task { await onPauseEpisode?(q) } },
                onResume: { Task { await onResumeEpisode?(q) } },
                onDelete: onDeleteEpisode.map { del in { del(q) } }
            )
            if !q.statusMessages.isEmpty {
                QueueStatusMessagesBanner(
                    messages: q.statusMessages,
                    tint: q.status.tint,
                    actionURL: seriesWebURL
                )
            }
            ReleaseNameBlock(release: q.releaseName)
        }
    }

    @ViewBuilder
    private func queueFileWithDiff(new q: QueueItem, existing: ArrFile) -> some View {
        // Sonarr ships existing-file metadata in a separate `/episodefile/{id}` payload, not on the QueueItem.
        let existingTags = (existing.customFormats ?? []).map(\.name)
        VStack(alignment: .leading, spacing: 6) {
            DownloadingSectionHeader(item: q)
            DownloadProgressCard(
                item: q,
                showHeader: true,
                showStatusRow: false,
                existingOverride: DownloadProgressCard.ExistingFileSnapshot(
                    quality: existing.quality?.name,
                    size: existing.size,
                    score: existing.customFormatScore,
                    formats: existingTags,
                    // Last path component only, matching the queue's `existingFileName`.
                    filename: existing.relativePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                )
            )
            if !q.statusMessages.isEmpty {
                QueueStatusMessagesBanner(
                    messages: q.statusMessages,
                    tint: q.status.tint,
                    actionURL: seriesWebURL
                )
            }
        }
    }

    @ViewBuilder
    private func queueFileSection(_ q: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DownloadingSectionHeader(item: q)
            DownloadProgressCard(item: q, showUpgradeDiff: false, showHeader: true, showStatusRow: false)
            if !q.statusMessages.isEmpty {
                QueueStatusMessagesBanner(
                    messages: q.statusMessages,
                    tint: q.status.tint,
                    actionURL: seriesWebURL
                )
            }
            if !q.customFormats.isEmpty {
                CustomFormatChips(formats: q.customFormats, score: 0)
            }
            ReleaseNameBlock(release: q.releaseName)
        }
    }

    private func performSearch() {
        guard let onSearch else { return }
        let id = episode.id
        SearchFeedback.run($searchFeedback) { try await onSearch(id) }
    }

    static let airFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

/// SwiftUI can't disambiguate two `.navigationDestination`s for the same type in one stack.
private struct EpisodeReleaseSearch: Identifiable, Hashable {
    let target: ManualSearchTarget
    var id: String { target.id }
}
