import SwiftUI

struct EpisodeRow: View {
    let episode: SonarrEpisodeDetail
    /// ALL active queue items matched to this episode (usually 0 or 1;
    /// 2+ when the same episode was grabbed twice). Drives the
    /// "downloading" indicator. The row renders off the first item and
    /// flags extras with a count badge — the episode detail lists each
    /// download separately. Controlling them is the queue's job.
    var queueItems: [QueueItem] = []
    /// Episode-file payload when this episode is on disk. Used to render
    /// the file's custom-format score in the right gutter — same
    /// `ScoreLabel` treatment as an in-progress download — so the
    /// "available" rows surface their points instead of the air date the
    /// user already knows.
    var episodeFile: SonarrEpisodeFile? = nil
    /// Tap the row body (not the state indicator) to drill into the
    /// episode detail surface. `nil` keeps the row passive (the
    /// legacy behaviour) for callers that don't want this drill-down.
    var onTap: ((SonarrEpisodeDetail) -> Void)? = nil
    /// The series' artwork, for the hover tooltip's poster slot. Episodes
    /// have no art of their own; the season surface already holds the
    /// series', so it passes it down rather than refetching.
    var posterURL: URL? = nil
    var posterRequiresAuth: Bool = false
    var posterAPIKey: String? = nil

    /// The row's representative download — first of `queueItems`. All the
    /// single-item visuals (tint, progress fill) render off this one; the
    /// count badge signals when there are more.
    private var queueItem: QueueItem? { queueItems.first }

    @EnvironmentObject private var configStore: ConfigStore
    /// Long-hover tooltip (same 600 ms gate as the queue rows). Two subjects,
    /// picked by what the row is doing: a downloading row shows
    /// `QueueItemTooltip` — the grab, with its upgrade diff — and every other
    /// row shows the EPISODE (synopsis, air date, and the on-disk file's
    /// quality / size / formats).
    ///
    /// The second one used to not exist, on the grounds that a row without a
    /// download says everything already. It doesn't: the row has exactly one
    /// trailing slot, so a file's score evicts its air date, and the synopsis
    /// has never been anywhere on it.
    @Environment(\.suppressRowTooltip) private var suppressRowTooltip
    @State private var isHovering = false
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    /// `S02E04`-style episode identifier rendered on the trailing
    /// edge. Same format the tooltip header uses.
    private var episodeCode: String {
        String(format: "S%02dE%02d",
               episode.seasonNumber ?? 0,
               episode.episodeNumber ?? 0)
    }
    /// Parsed once per row rather than per read: `hasAired` is consulted from
    /// both `episodeTitleStyle` and `stateIndicator`, and the trailing gutter
    /// wants the same date again — three parses per row, on every layout pass
    /// of a list that re-renders on every queue tick.
    private var airDate: Date? { episode.airDateUtc.flatMap(parseArrDate) }
    /// Air date treated as past → episode has actually aired. nil airDate
    /// (extremely rare — usually a Sonarr metadata gap) is treated as
    /// "aired" so we don't accidentally hide search affordances for shows
    /// that didn't publish a date.
    private func hasAired(_ air: Date?) -> Bool {
        guard let air else { return true }
        return air <= Date()
    }
    /// `nil` reads as monitored — an older Sonarr that doesn't report the
    /// flag shouldn't make every episode look switched off.
    private var isMonitored: Bool { episode.monitored ?? true }

    /// Title colour. Inverted from the previous "missing pops"
    /// scheme — on-disk episodes (the user's library, ready to
    /// watch) get the brightest treatment now, and every other
    /// state derives from there:
    ///   - on-disk           → `.primary`              (full white, "available")
    ///   - missing-aired     → `.primary.opacity(0.75)` (subtle dim, "not here yet")
    ///   - not-aired         → `.tertiary`             (most dim, scheduled future)
    ///   - active download   → `status.tint`           (status colour for live state)
    private func episodeTitleStyle(aired: Bool) -> AnyShapeStyle {
        if !aired { return AnyShapeStyle(HierarchicalShapeStyle.tertiary) }
        if let q = queueItem { return AnyShapeStyle(q.status.tint) }
        if episode.hasFile == true { return AnyShapeStyle(Color.primary) }
        return AnyShapeStyle(Color.primary.opacity(0.75))
    }

    public var body: some View {
        // The row's one date parse — every branch below reads these two.
        let air = airDate
        let aired = hasAired(air)
        Button {
            onTap?(episode)
        } label: {
            HStack(spacing: 6) {
                // Everything except the state glyph dims together when the
                // episode is unmonitored — same wash the season row uses.
                // Dimming only the title left the `S02E04` code reading
                // BRIGHTER than the name it prefixes, which inverted the
                // row's hierarchy. The bookmark stays outside the group so
                // the one thing explaining the wash isn't washed out too.
                HStack(spacing: 6) {
                // `S02E04` identifier leads the title (Music/TV idiom:
                // the episode number prefixes the name). Monospaced +
                // fixed 6-char width so titles align down the column;
                // kept subordinate to the title via size/secondary
                // colour so it reads as a prefix, not a competing label.
                Text(episodeCode)
                    .scaledFont(size: 10, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                Text(episode.title ?? "—")
                    .scaledFont(size: 11)
                    .foregroundStyle(episodeTitleStyle(aired: aired))
                    .lineLimit(1)
                // Drill-in affordance — same `LinkChevron` every other tappable
                // row uses (static dark, brightens on row hover via `.linkRowHover`).
                if onTap != nil {
                    LinkChevron(size: 8)
                }
                // Duplicate-grab flag: the same episode has 2+ active
                // downloads. The row shows the first one's progress; the
                // badge says there's more — the episode detail lists each.
                if queueItems.count > 1 {
                    OutlineLabel(
                        text: String.localizedStringWithFormat(
                            NSLocalizedString("unit.downloads", bundle: .module, comment: ""),
                            queueItems.count
                        ),
                        tint: .secondary
                    )
                }
                Spacer()
                // Right-hand stat: airdate is the default, but for any
                // non-downloaded state where we actually have an
                // upgrade context (a queue item) we show the
                // custom-format score delta instead — much more useful
                // information when the row is "doing something" than
                // the air date the user already knows. Plain missing /
                // not-aired rows keep the date since there's no diff
                // to compute.
                if let q = queueItem {
                    // Per-row Upgrade / New tag — same component the queue
                    // rows use. Lives on the trailing edge, immediately ahead
                    // of the score, instead of interrupting the title.
                    MediaBadgeCluster(isUpgrade: q.isUpgrade, size: .subtle)
                    // The incoming file's own score. It used to be a delta
                    // against the file on disk, which made this gutter mean
                    // something different from the identical-looking gutter
                    // two screens away. The comparison lives in the tooltip.
                    ScoreLabel(score: q.customFormatScore,
                               baseline: q.existingCustomFormatScore, size: 10)
                } else if let file = episodeFile, let score = file.customFormatScore {
                    // On-disk episode — show its custom-format score
                    // (more useful than the air date the user already
                    // knows). Falls back to the date below when the file
                    // didn't carry a score.
                    ScoreLabel(score: score, size: 10)
                } else if let air {
                    Text(Self.formatter.string(from: air))
                        .scaledFont(size: 10)
                        .foregroundStyle(.tertiary)
                }
                }
                // Applied ON TOP of the existing style resolution rather than
                // as another branch inside `episodeTitleStyle` — a monitored
                // episode renders byte-for-byte as before.
                .opacity(isMonitored ? 1 : 0.55)
                stateIndicator(aired: aired)
                    .frame(width: 14, height: 14, alignment: .center)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The dim + glyph are visual-only; VoiceOver gets the state as the
        // row's value so it reads "S02E04, Title, Not monitored, button".
        .accessibilityValue(
            isMonitored ? Text(verbatim: "")
                        : Text("common.notMonitored.label", bundle: .module)
        )
        // Row background doubles as a progress visualiser for
        // active downloads: a status-tinted bar that fills `progress`
        // % of the row's width, clipped to the same 4pt corner as
        // the row itself. The bar widens as the download advances —
        // no separate progress widget needed. Falls back to the
        // hover-tint for non-queue rows.
        .background(
            // Only the active-download progress fill — no hover tint (a hover
            // chevron next to the title signals "tap to open" instead).
            ZStack(alignment: .leading) {
                if let q = queueItem {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(q.status.tint.opacity(0.16))
                            .frame(width: geo.size.width * max(0.02, min(1, q.progress)))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.chip))
        )
        // No hover ACTIONS: the row is a link into the episode detail.
        // Pausing / resuming / cancelling a download happens in the queue,
        // which owns those controls. It does keep the long-hover tooltip —
        // the same `QueueItemTooltip` the queue rows show, so a downloading
        // episode's upgrade diff reads identically wherever you meet it.
        #if os(macOS)
        .onHover { hovering in
            isHovering = hovering
            hoverTask?.cancel()
            if hovering && !suppressRowTooltip && hasTooltip {
                hoverTask = Task { @MainActor [self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if !Task.isCancelled && self.isHovering { showTooltip = true }
                }
            } else {
                showTooltip = false
            }
        }
        .tooltipPopover(isPresented: $showTooltip, arrowEdge: .trailing) {
            if let q = queueItem {
                QueueItemTooltip(
                    item: q,
                    apiKey: q.posterRequiresAuth ? configStore.sonarr.apiKey : nil,
                    locale: configStore.currentLocale
                )
            } else {
                episodeTooltip
            }
        }
        #endif
        // Publishes row-hover to the `LinkChevron` above so it brightens whenever
        // the cursor is anywhere over the row, not just on the 8pt glyph.
        .linkRowHover()
    }

    // MARK: - Episode tooltip (rows with no active download)

    /// Suppressed only when there would be nothing but the title in it — an
    /// unaired episode Sonarr hasn't written a synopsis for yet.
    private var hasTooltip: Bool {
        queueItem != nil
            || episodeFile != nil
            || airDate != nil
            || !(episode.overview ?? "").isEmpty
    }

    /// What the row's single trailing slot can't fit. Same chrome as every
    /// other media tooltip, and the same state chip the detail heroes and the
    /// Library tab use, so "Downloaded" means one thing app-wide.
    private var episodeTooltip: some View {
        MediaTooltipChrome(
            title: episode.title ?? episodeCode,
            subtitle: tooltipSubtitle,
            posterURL: posterURL,
            posterRequiresAuth: posterRequiresAuth,
            apiKey: posterAPIKey,
            fallbackSymbol: "tv",
            statusChip: AnyView(
                MediaStateChip(state: episodeFileState, locale: configStore.currentLocale)
            )
        ) {
            let lines = tooltipInfoLines
            if !lines.isEmpty { TooltipInfoGrid(lines: lines) }
            TooltipOverview(text: episode.overview)
            if let formats = episodeFile?.customFormats?.map(\.name), !formats.isEmpty {
                CustomFormatChips(formats: formats, score: episodeFile?.customFormatScore ?? 0)
            }
            TooltipFileName(name: episodeFile?.relativePath)
        }
    }

    /// `S02E04 · 12 March 2024` — the code the row already shows, plus the air
    /// date, which the row drops whenever a score takes the trailing slot.
    private var tooltipSubtitle: String {
        [episodeCode, airDate.map { Self.formatter.string(from: $0) }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var episodeFileState: LibraryEntry.FileState {
        if episode.hasFile == true { return .complete }
        if !isMonitored { return .unmonitored }
        // Nothing to grab yet is not the same as nothing grabbed.
        return hasAired(airDate) ? .missing : .notAvailable
    }

    private var tooltipInfoLines: [TooltipInfoLine] {
        var lines: [TooltipInfoLine] = []
        if let quality = episodeFile?.quality?.name, !quality.isEmpty {
            lines.append(TooltipInfoLine(labelKey: "Quality", value: quality))
        }
        if let size = episodeFile?.size, size > 0 {
            lines.append(TooltipInfoLine(
                labelKey: "Size",
                value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            ))
        }
        if let runtime = episode.runtime, runtime > 0 {
            lines.append(TooltipInfoLine(labelKey: "Runtime", value: "\(runtime) min"))
        }
        return lines
    }

    @ViewBuilder
    private func stateIndicator(aired: Bool) -> some View {
        // One 14pt slot, and unmonitored WINS it over not-aired: "hasn't
        // aired" is already said twice on the row (tertiary title + the
        // future date in the trailing gutter), while "unmonitored" is said
        // nowhere else. The tooltip carries both states when they coincide.
        //
        // A monitored, aired episode still renders nothing — the default
        // state costs no pixels, which is the whole point of showing only
        // the exception. ("Missing" gets no bare circle either: the dimmed
        // title already says "not in your library", and the season row
        // carries the per-season "X/Y" count.)
        if !isMonitored {
            MonitorBookmark(isMonitored: false, size: 10)
                .help(Text(LocalizedStringKey(unmonitoredHelpKey(aired: aired)), bundle: .module))
        } else if !aired {
            Image(systemName: "calendar")
                .scaledFont(size: 10)
                .foregroundStyle(.tertiary)
                .help(Text("detail.notAiredYet.button", bundle: .module))
        }
    }

    private func unmonitoredHelpKey(aired: Bool) -> String {
        aired ? "common.notMonitored.label" : "detail.notMonitoredNotAired.label"
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none
        return f
    }()
}
