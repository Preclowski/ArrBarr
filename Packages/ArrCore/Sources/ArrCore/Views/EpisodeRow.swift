import SwiftUI
import MediaKit

struct EpisodeRow: View {
    let episode: ArrEpisode
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
    var episodeFile: ArrFile? = nil
    /// Tap the row body (not the state indicator) to drill into the
    /// episode detail surface. `nil` keeps the row passive (the
    /// legacy behaviour) for callers that don't want this drill-down.
    var onTap: ((ArrEpisode) -> Void)? = nil
    /// The series' artwork, for the hover tooltip's poster slot. Episodes
    /// have no art of their own; the season surface already holds the
    /// series', so it passes it down rather than refetching.
    var posterURL: URL? = nil
    var posterRequiresAuth: Bool = false
    var posterAPIKey: String? = nil
    /// Flip this episode's monitored flag. `nil` keeps the leading bookmark an
    /// inert state glyph.
    var onToggleMonitored: ((Bool) async -> Void)? = nil
    /// Right-click / long-press search on the row itself — the same Automatic /
    /// Manual choice the episode's own header carries. Both nil → no menu.
    var onAutomaticSearch: (() async -> Void)? = nil
    var onManualSearch: (() -> Void)? = nil

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
    /// Sweep state for a search fired from the row's context menu, rendered in
    /// the trailing state slot (the menu is gone by the time it runs).
    @State private var autoSearching = false
    @State private var autoDidSearch = false

    /// `S02E04`-style episode identifier rendered on the trailing
    /// edge. Same format the tooltip header uses.
    private var episodeCode: String {
        EpisodeCode.string(season: episode.seasonNumber ?? 0, episode: episode.episodeNumber ?? 0)
    }
    /// Read once per body pass — the list re-renders on every queue tick.
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

    /// Title colour: the download's status colour while something is
    /// happening, full strength otherwise.
    ///
    /// The four-way fade this used to be (on-disk bright, missing dimmed,
    /// not-aired dimmer) keyed on values that arrive at different times —
    /// `hasFile`, the live queue item, the air date — so the same list read
    /// dimmed on one launch and bright on the next, for no reason the user
    /// could see. Air date, file state and download state are all spoken by
    /// the row's own glyphs and labels; the title stays legible.
    private var episodeTitleStyle: AnyShapeStyle {
        if let q = queueItem { return AnyShapeStyle(q.status.tint) }
        return AnyShapeStyle(Color.primary)
    }

    public var body: some View {
        // The row's one date parse.
        let air = airDate
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
                    .foregroundStyle(episodeTitleStyle)
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
                    MediaBadgeCluster(isUpgrade: q.isUpgrade)
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
                // State glyph and the monitored toggle's column, tight against
                // each other and against the row's trailing edge: with the
                // row's own spacing between them the bookmark sat ~20pt in and
                // read as a right margin on the whole list.
                HStack(spacing: 0) {
                    stateIndicator
                        .frame(width: 14, height: 14, alignment: .center)
                    // Reserves the glyph's width (the overlay below draws it);
                    // the hit area is wider and simply hangs over the state
                    // glyph, which is inert.
                    Color.clear
                        .frame(width: 11, height: 12)
                }
            }
            // No horizontal inset: the row lines up with the section header
            // above it and with every other list in the app (the season rows
            // one screen up carry their own padding because they paint a
            // progress fill behind it; these don't).
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(OptionalRowSearchMenu(
            inFlight: $autoSearching, didQueue: $autoDidSearch,
            onAutomatic: onAutomaticSearch, onManual: onManualSearch))
        // Outside the row Button, not inside its label — a Button nested in a
        // Button's label doesn't reliably win the tap, and the row itself opens
        // the episode.
        .overlay(alignment: .trailing) {
            MonitorRowToggle(isMonitored: isMonitored, entity: .episode,
                             alignment: .trailing, onToggle: onToggleMonitored)
        }
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
                    apiKey: q.posterRequiresAuth ? configStore.sonarr.apiKey : nil
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
    private var stateIndicator: some View {
        // A row-fired automatic search owns the slot while it runs — it is the
        // only transient thing on the row, and it outranks a date the user can
        // read again a second later.
        //
        // A future episode shows only its air date; no glyph of its own.
        if autoSearching {
            ProgressView().controlSize(.small)
        } else if autoDidSearch {
            Image(systemName: "checkmark")
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(.secondary)
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none
        return f
    }()
}
