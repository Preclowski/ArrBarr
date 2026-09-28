import SwiftUI
import MediaKit

struct EpisodeRow: View {
    let episode: ArrEpisode
    /// Active queue items for this episode; 2+ when it was grabbed twice. The
    /// row renders off the first and badges the extras.
    var queueItems: [QueueItem] = []
    var episodeFile: ArrFile? = nil
    /// Tap on the row body (not the state indicator); `nil` keeps the row passive.
    var onTap: ((ArrEpisode) -> Void)? = nil
    /// The series' artwork for the tooltip; episodes have none of their own.
    var posterURL: URL? = nil
    var posterRequiresAuth: Bool = false
    var posterAPIKey: String? = nil
    var onToggleMonitored: ((Bool) async -> Void)? = nil
    /// Row context-menu search. Both nil → no menu.
    var onAutomaticSearch: (() async throws -> Void)? = nil
    var onManualSearch: (() -> Void)? = nil

    private var queueItem: QueueItem? { queueItems.first }

    @EnvironmentObject private var configStore: ConfigStore
    /// Long-hover tooltip: a downloading row shows `QueueItemTooltip`, any other
    /// row the episode (synopsis, air date, file) its one trailing slot can't fit.
    /// Search fired from the context menu, shown in the trailing state slot
    /// because the menu is gone by the time it runs.
    @State private var searchFeedback: SearchFeedback = .idle

    private var episodeCode: String {
        EpisodeCode.string(season: episode.seasonNumber ?? 0, episode: episode.episodeNumber ?? 0)
    }
    /// Read once per body pass — the list re-renders on every queue tick.
    private var airDate: Date? { episode.airDateUtc.flatMap(parseArrDate) }
    /// nil airDate (a Sonarr metadata gap) counts as aired, so search
    /// affordances stay visible.
    private func hasAired(_ air: Date?) -> Bool {
        guard let air else { return true }
        return air <= Date()
    }
    /// `nil` reads as monitored: an older Sonarr doesn't report the flag.
    private var isMonitored: Bool { episode.monitored ?? true }

    /// No fade by file/air state: those arrive at different times, so the list
    /// read dimmed one launch and bright the next.
    private var episodeTitleStyle: AnyShapeStyle {
        if let q = queueItem { return AnyShapeStyle(q.status.tint) }
        return AnyShapeStyle(Color.primary)
    }

    var body: some View {
        let air = airDate
        Button {
            onTap?(episode)
        } label: {
            HStack(spacing: 6) {
                // Dim everything but the bookmark together; dimming only the title
                // left the code brighter than the name.
                HStack(spacing: 6) {
                Text(episodeCode)
                    .scaledFont(size: 10, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                Text(episode.title ?? "—")
                    .scaledFont(size: 11)
                    .foregroundStyle(episodeTitleStyle)
                    .lineLimit(1)
                if onTap != nil {
                    LinkChevron(size: 8)
                }
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
                if let q = queueItem {
                    MediaBadgeCluster(isUpgrade: q.isUpgrade)
                    // The incoming file's own score, matching the gutter elsewhere;
                    // the diff lives in the tooltip.
                    ScoreLabel(score: q.customFormatScore,
                               baseline: q.existingCustomFormatScore, size: 10)
                } else if let file = episodeFile, let score = file.customFormatScore {
                    ScoreLabel(score: score, size: 10)
                } else if let air {
                    Text(Self.formatter.string(from: air))
                        .scaledFont(size: 10)
                        .foregroundStyle(.tertiary)
                }
                }
                // Spacing 0: with the row's spacing the bookmark read as a right margin.
                HStack(spacing: 0) {
                    stateIndicator
                        .frame(width: 14, height: 14, alignment: .center)
                    // Reserves the glyph's width; the overlay below draws it.
                    Color.clear
                        .frame(width: 11, height: 12)
                }
            }
            // No horizontal inset, so the row lines up with the section header.
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(OptionalRowSearchMenu(
            feedback: $searchFeedback,
            onAutomatic: onAutomaticSearch, onManual: onManualSearch))
        // Outside the row Button: a Button nested in a Button's label doesn't
        // reliably win the tap.
        .overlay(alignment: .trailing) {
            MonitorRowToggle(isMonitored: isMonitored, entity: .episode,
                             alignment: .trailing, onToggle: onToggleMonitored)
        }
        .accessibilityValue(
            isMonitored ? Text(verbatim: "")
                        : Text("common.notMonitored.label", bundle: .module)
        )
        .background(
            // Progress fill for an active download only.
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
        // No hover actions: download controls belong to the queue.
        #if os(macOS)
        .hoverTooltip(enabled: hasTooltip) {
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
        .linkRowHover()
    }

    // MARK: - Episode tooltip (rows with no active download)

    /// Suppressed only for an unaired episode with no synopsis yet.
    private var hasTooltip: Bool {
        queueItem != nil
            || episodeFile != nil
            || airDate != nil
            || !(episode.overview ?? "").isEmpty
    }

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

    private var tooltipSubtitle: String {
        [episodeCode, airDate.map { Self.formatter.string(from: $0) }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var episodeFileState: LibraryEntry.FileState {
        if episode.hasFile == true { return .complete }
        if !isMonitored { return .unmonitored }
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
        // A row-fired search owns the slot while it runs; a future episode
        // shows only its air date.
        SearchFeedbackIcon(feedback: searchFeedback)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none
        return f
    }()
}
