import SwiftUI

/// Compact full-popover episode detail. Pushed on top of `DetailView`
/// when the user taps an `EpisodeRow`. Shows episode metadata + a
/// destructive Search action when the episode is missing. Closes via
/// the leading back chevron, the trailing xmark, or Esc.
public struct EpisodeDetailOverlay: View {
    let episode: SonarrEpisodeDetail
    let seriesTitle: String
    /// Page title shown in the header — typically the tab the user
    /// came from ("Kolejka", "Nadchodzące", "Czat", …). Matches
    /// `DetailView`'s breadcrumb pattern so the user always knows
    /// where back will take them.
    let originLabel: LocalizedStringKey
    let posterURL: URL?
    let posterRequiresAuth: Bool
    let apiKey: String?
    /// Lazy-loaded file payload — `nil` until the parent fetches
    /// `/episodefile/{id}` for an on-disk episode. Drives the
    /// quality / size / customFormats chip strip.
    /// Existing-file payload for upgrade-context rendering. Same shape
    /// the season list already passes to `EpisodeRow` — taken straight
    /// from `DetailView.sonarrEpisodeFiles` (works in demo too) instead
    /// of the per-episode async `/episodefile/{id}` fetch we used to
    /// fire, which returned nil in demo and broke the diff view.
    let episodeFile: SonarrEpisodeFile?
    /// Active queue item for this episode (when one's downloading).
    /// Powers the "new file" section that sits alongside the existing
    /// file — both can be present (upgrade in progress).
    let queueItem: QueueItem?
    /// Lightbox handler — fires when the user taps the poster.
    /// Parent (`DetailView`) raises its own poster lightbox in
    /// response.
    let onPosterTap: ((URL?) -> Void)?
    let onClose: () -> Void
    let onSearch: ((Int) async -> Void)?
    /// Pause/Resume/Cancel closures for the active queueItem — wired
    /// by DetailView from the same `viewModel.pause/resume/delete`
    /// pipeline the season list uses. Drives the sticky bottom CTA
    /// strip on download/paused episodes.
    let onPauseEpisode: ((QueueItem) -> Void)?
    let onResumeEpisode: ((QueueItem) -> Void)?
    let onDeleteEpisode: ((QueueItem) -> Void)?
    /// URL of the arr's web UI for the active queue item — surfaced
    /// as a CTA on the warning banner. Most `statusMessages` are only
    /// actionable inside the arr's own UI (manual import, blocklist,
    /// edit grab), so a one-click jump there is the actionable bit.
    let warningActionURL: URL?

    @State private var isSearching = false
    @State private var ctaPendingDelete = false
    @State private var didSearch = false
    @State private var showSearchConfirm = false

    private var hasAired: Bool {
        guard let air = episode.airDateUtc.flatMap(parseArrDate) else { return true }
        return air <= Date()
    }

    private var episodeCode: String {
        String(format: "S%02dE%02d",
               episode.seasonNumber ?? 0,
               episode.episodeNumber ?? 0)
    }

    public init(
        episode: SonarrEpisodeDetail,
        seriesTitle: String,
        originLabel: LocalizedStringKey = "Details",
        posterURL: URL?,
        posterRequiresAuth: Bool,
        apiKey: String?,
        episodeFile: SonarrEpisodeFile? = nil,
        queueItem: QueueItem? = nil,
        onPosterTap: ((URL?) -> Void)? = nil,
        onClose: @escaping () -> Void,
        onSearch: ((Int) async -> Void)?,
        warningActionURL: URL? = nil,
        onPauseEpisode: ((QueueItem) -> Void)? = nil,
        onResumeEpisode: ((QueueItem) -> Void)? = nil,
        onDeleteEpisode: ((QueueItem) -> Void)? = nil
    ) {
        self.episode = episode
        self.seriesTitle = seriesTitle
        self.originLabel = originLabel
        self.posterURL = posterURL
        self.posterRequiresAuth = posterRequiresAuth
        self.apiKey = apiKey
        self.episodeFile = episodeFile
        self.queueItem = queueItem
        self.onPosterTap = onPosterTap
        self.onClose = onClose
        self.onSearch = onSearch
        self.warningActionURL = warningActionURL
        self.onPauseEpisode = onPauseEpisode
        self.onResumeEpisode = onResumeEpisode
        self.onDeleteEpisode = onDeleteEpisode
    }

    public var body: some View {
        // No solid scrim — would kill the popover's native
        // translucent chrome. Underlying series detail is opacity-
        // hidden in DetailView while this overlay is up, so we don't
        // need to mask it ourselves. The view fills the popover, lets
        // glass shine through.
        VStack(spacing: 0) {
            header
            ScrollView {
                content
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
            // Sticky bottom CTA — same shape as `DetailView`'s
            // `downloadCTAStrip`. Pause/Resume when downloading,
            // Search when missing+aired, Safari as fallback / secondary.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if shouldShowCTAStrip {
                    episodeCTAStrip
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(
                            Rectangle()
                                .fill(.thinMaterial)
                                .overlay(alignment: .top) {
                                    Divider().opacity(0.4)
                                }
                                .ignoresSafeArea(edges: .bottom)
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            Text("Search this episode?", bundle: .module),
            isPresented: $showSearchConfirm,
            titleVisibility: .visible
        ) {
            Button { performSearch() } label: { Text("Search", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("Will query your indexers and start a download if a release matches.", bundle: .module)
        }
        .confirmationDialog(
            Text("Cancel this download?", bundle: .module),
            isPresented: $ctaPendingDelete,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                if let q = queueItem { onDeleteEpisode?(q); onClose() }
            } label: { Text("Cancel download", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Keep download", bundle: .module) }
        } message: {
            Text(String(format: String(localized: "This will remove \"%@\" from the download client.", bundle: .module), queueItem?.title ?? episode.title ?? ""))
        }
    }

    private var shouldShowCTAStrip: Bool {
        let canPauseResume = (queueItem?.status == .downloading || queueItem?.status == .paused)
            && ((queueItem?.isPaused == true && onResumeEpisode != nil)
                || (queueItem?.isPaused == false && onPauseEpisode != nil))
        let canDelete = queueItem != nil && onDeleteEpisode != nil
        let canSearch = onSearch != nil && episode.hasFile != true && hasAired
        return canPauseResume || canDelete || canSearch || warningActionURL != nil
    }

    @ViewBuilder
    private var episodeCTAStrip: some View {
        let canPauseResume = (queueItem?.status == .downloading || queueItem?.status == .paused)
            && ((queueItem?.isPaused == true && onResumeEpisode != nil)
                || (queueItem?.isPaused == false && onPauseEpisode != nil))
        let canDelete = queueItem != nil && onDeleteEpisode != nil
        let canSearch = onSearch != nil && episode.hasFile != true && hasAired
        HStack(spacing: 8) {
            if canPauseResume, let q = queueItem {
                ctaPauseResume(q: q)
                if canDelete { ctaTrash }
                if let url = warningActionURL { ctaSafariSecondary(url: url) }
            } else if canSearch {
                ctaSearch
                if let url = warningActionURL { ctaSafariSecondary(url: url) }
            } else if canDelete {
                ctaCancelProminent
                if let url = warningActionURL { ctaSafariSecondary(url: url) }
            } else if let url = warningActionURL {
                ctaSafariProminent(url: url)
            }
        }
    }

    @ViewBuilder
    private func ctaPauseResume(q: QueueItem) -> some View {
        Button {
            if q.isPaused { onResumeEpisode?(q) } else { onPauseEpisode?(q) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: q.isPaused ? "play.fill" : "pause.fill")
                    .scaledFont(size: 11, weight: .semibold)
                Text(q.isPaused
                        ? String(localized: "Resume download", bundle: .module)
                        : String(localized: "Pause download", bundle: .module))
                    .scaledFont(size: 12, weight: .semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .tint(q.status.tint)
        .progressFillCTA(progress: q.progress, tint: q.status.tint)
        .modifier(GlassProminentButtonStyle())
    }

    @ViewBuilder
    private var ctaTrash: some View {
        Button {
            ctaPendingDelete = true
        } label: {
            Image(systemName: "trash")
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
                .padding(.vertical, 7)
        }
        .buttonStyle(.bordered)
        .help(Text("Cancel download", bundle: .module))
    }

    @ViewBuilder
    private var ctaCancelProminent: some View {
        Button { ctaPendingDelete = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .scaledFont(size: 11, weight: .semibold)
                Text("Cancel download", bundle: .module)
                    .scaledFont(size: 12, weight: .semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .modifier(GlassProminentButtonStyle())
        .tint(.red)
    }

    @ViewBuilder
    private var ctaSearch: some View {
        Button { showSearchConfirm = true } label: {
            HStack(spacing: 6) {
                if isSearching {
                    ProgressView().controlSize(.small)
                } else if didSearch {
                    Image(systemName: "checkmark")
                        .scaledFont(size: 11, weight: .semibold)
                    Text("Search queued", bundle: .module)
                        .scaledFont(size: 12, weight: .semibold)
                } else {
                    Image(systemName: "magnifyingglass")
                        .scaledFont(size: 11, weight: .semibold)
                    Text("Search this episode?", bundle: .module)
                        .scaledFont(size: 12, weight: .semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .modifier(GlassProminentButtonStyle())
        .disabled(isSearching)
    }

    @ViewBuilder
    private func ctaSafariProminent(url: URL) -> some View {
        Button { PlatformURLOpener.open(url) } label: {
            HStack(spacing: 6) {
                Image(systemName: "safari")
                    .scaledFont(size: 11, weight: .semibold)
                Text("Open in browser", bundle: .module)
                    .scaledFont(size: 12, weight: .semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .modifier(GlassProminentButtonStyle())
        .help(Text("Open in browser", bundle: .module))
    }

    @ViewBuilder
    private func ctaSafariSecondary(url: URL) -> some View {
        Button { PlatformURLOpener.open(url) } label: {
            Image(systemName: "safari")
                .scaledFont(size: 13, weight: .medium)
                .padding(.horizontal, 4)
                .padding(.vertical, 7)
        }
        .buttonStyle(.bordered)
        .help(Text("Open in browser", bundle: .module))
    }

    private var header: some View {
        // Variant A header — back chevron + origin breadcrumb. No
        // trailing xmark: a single dismiss affordance per view is the
        // Apple-HIG rule (back chevron + Esc keyboard shortcut cover
        // every dismiss path).
        HStack(spacing: 6) {
            FloatingBackButton(action: onClose)
                .keyboardShortcut(.cancelAction)
            Text(originLabel, bundle: .module)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Image(systemName: "tv")
                .scaledFont(size: 11)
                .foregroundStyle(.tertiary)
            Text(verbatim: "Sonarr")
                .scaledFont(size: 11)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                // Poster + blur container match MediaHeaderCard's
                // chrome (110×165, 6pt corner, blur wrap) so episode
                // detail looks like every other detail surface in the
                // app instead of a custom one-off card.
                let poster = PosterBlurContainer(blurred: false, cornerRadius: 6) {
                    RemotePoster(
                        url: posterURL,
                        apiKey: posterRequiresAuth ? apiKey : nil,
                        size: CGSize(width: 110, height: 165),
                        cornerRadius: 6,
                        fallbackSymbol: "tv"
                    )
                }
                if let onPosterTap {
                    Button { onPosterTap(posterURL) } label: { poster }
                        .buttonStyle(.plain)
                        .help(Text("Show poster", bundle: .module))
                } else {
                    poster
                }
                VStack(alignment: .leading, spacing: 6) {
                    // Series title is the *context* (which show this
                    // episode belongs to), subordinate to the episode
                    // title below. 12pt medium .secondary — readable
                    // but stays under the 17pt episode title in
                    // hierarchy.
                    Text(seriesTitle)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(episodeCode)
                            .scaledFont(size: 12, weight: .semibold, monospacedDigit: true)
                            .foregroundStyle(.secondary)
                        // "On disk" badge dropped — was a custom
                        // status invented only for this surface. The
                        // EXISTING FILE section below + the file's
                        // metadata convey the same thing with the
                        // canonical chrome used everywhere else.
                        // "Unaired" stays because it's a real
                        // schedule state not implied by other UI.
                        if !hasAired {
                            Text("Unaired", bundle: .module)
                                .scaledFont(size: 9, weight: .semibold)
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                        }
                    }
                    Text(episode.title ?? "—")
                        .scaledFont(size: 17, weight: .semibold)
                        .lineLimit(3)
                    if let air = episode.airDateUtc.flatMap(parseArrDate) {
                        Text(EpisodeDetailOverlay.airFormatter.string(from: air))
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                    if let runtime = episode.runtime, runtime > 0 {
                        Text(verbatim: "\(runtime) min")
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if let overview = episode.overview, !overview.isEmpty {
                ExpandableOverview(text: overview)
            }

            // Combined file view — three modes:
            //   1. New (downloading) + Existing (on disk) → diff
            //      style: new file prominent, existing as `└─` sub-
            //      line beneath, mirroring the movie-detail diff.
            //   2. Only downloading → new-file section (no diff).
            //   3. Only existing → ExistingFileBanner.
            // Replaces the two stacked sections that hid the user's
            // upgrade-vs-current comparison behind a `Divider`.
            if queueItem != nil || (episode.hasFile == true && episodeFile != nil) {
                // No explicit Divider — the progress bar at the top
                // of `DownloadProgressCard` reads as a natural
                // horizontal rule between description and file
                // section.
                fileSection
            }

            // Search / pause / cancel / safari all surfaced as the
            // sticky bottom CTA strip (`episodeCTAStrip`) — body stays
            // pure content (poster, metadata, file section).
        }
    }

    /// Combined diff/file section. Chooses presentation by what's
    /// available:
    ///   - Both downloading + existing: diff (new file + `└─` old
    ///     line + CF chip diff).
    ///   - Downloading only: queue file section.
    ///   - Existing only: ExistingFileBanner.
    @ViewBuilder
    private var fileSection: some View {
        if let q = queueItem, let existing = episodeFile, episode.hasFile == true {
            queueFileWithDiff(new: q, existing: existing)
        } else if let q = queueItem {
            queueFileSection(q)
        } else if let existing = episodeFile {
            ExistingFileBanner(episodeFile: existing)
        }
    }

    /// Diff variant — new file (downloading) up top with its full
    /// presentation, existing file rolled into a `└─` sub-line that
    /// carries quality/size/score + delta. CF chip diff (added /
    /// removed) follows the new chip strip if the sets differ.
    @ViewBuilder
    private func queueFileWithDiff(new q: QueueItem, existing: SonarrEpisodeFile) -> some View {
        // Sonarr ships existing-file metadata in a separate
        // `/episodefile/{id}` payload (not on the QueueItem), so we
        // tunnel it into the card via `existingOverride`. The card
        // then renders the same in-header diff line every other
        // surface uses — movie detail and episode detail wear
        // identical chrome.
        let existingTags = (existing.customFormats ?? []).map(\.name)
        VStack(alignment: .leading, spacing: 6) {
            DownloadProgressCard(
                item: q,
                showHeader: true,
                showProgressFill: false,
                existingOverride: DownloadProgressCard.ExistingFileSnapshot(
                    quality: existing.quality?.name,
                    size: existing.size,
                    score: existing.customFormatScore,
                    formats: existingTags
                )
            )
            if !q.statusMessages.isEmpty {
                QueueStatusMessagesBanner(
                    messages: q.statusMessages,
                    tint: q.status.tint,
                    actionURL: warningActionURL
                )
            }
            if !q.customFormats.isEmpty {
                CustomFormatChips(formats: q.customFormats, score: 0)
                CustomFormatDiff(
                    newFormats: q.customFormats,
                    existingFormats: existingTags
                )
            }
            releaseNameBlock(release: q.releaseName, existing: existing.relativePath)
        }
    }

    @ViewBuilder
    private func releaseNameBlock(release: String?, existing: String?) -> some View {
        if let release, !release.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(release)
                    .scaledFont(size: 11, design: .monospaced)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let existing, !existing.isEmpty, existing != release {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "arrow.up")
                            .scaledFont(size: 9, weight: .semibold)
                            .foregroundStyle(.tertiary)
                        Text(existing)
                            .scaledFont(size: 11, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    /// Section describing what's actively being downloaded for this
    /// episode. Same shape as the on-disk file section so the user
    /// reads both with a single mental model. Status pill + progress
    /// bar at the top give the "is this happening now" answer at a
    /// glance.
    @ViewBuilder
    private func queueFileSection(_ q: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DownloadProgressCard(item: q, showUpgradeDiff: false, showHeader: true, showProgressFill: false)
            if !q.statusMessages.isEmpty {
                QueueStatusMessagesBanner(
                    messages: q.statusMessages,
                    tint: q.status.tint,
                    actionURL: warningActionURL
                )
            }
            if !q.customFormats.isEmpty {
                CustomFormatChips(formats: q.customFormats, score: 0)
            }
            releaseNameBlock(release: q.releaseName, existing: nil)
        }
    }

    private func performSearch() {
        guard let onSearch, let id = Optional(episode.id), !isSearching else { return }
        isSearching = true
        Task {
            await onSearch(id)
            await MainActor.run {
                isSearching = false
                didSearch = true
            }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            await MainActor.run { didSearch = false }
        }
    }

    static let airFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
