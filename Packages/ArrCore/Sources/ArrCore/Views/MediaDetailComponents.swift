import SwiftUI

// View components extracted from DetailView.swift. These are self-contained
// SwiftUI structs that take their dependencies via init — no enclosing-view
// state required. A couple (MediaHeaderCard, ExpandableOverview, RatingChip)
// are reused by SearchAddPanel.

// MARK: - Pieces

public struct RatingChip {
    let label: String
    let value: String
    let color: Color
}

/// Shared header card used by the queue detail view and the search add
/// panel. Right column scales by what's provided — every field is optional
/// so each caller passes only the data its source can supply.
public struct MediaHeaderCard: View {
    let title: String
    var subtitle: String? = nil
    var year: Int? = nil
    var runtime: Int? = nil
    var network: String? = nil
    var certification: String? = nil
    var genres: [String] = []
    var ratings: [RatingChip] = []
    let posterURL: URL?
    var posterRequiresAuth: Bool = false
    var apiKey: String? = nil
    var fallbackSymbol: String = "film"
    var posterAspect: CGFloat = 2.0/3.0
    var blurred: Bool = false
    var trailing: AnyView? = nil

    public var body: some View {
        let posterWidth: CGFloat = 110
        let posterHeight = posterWidth / posterAspect
        HStack(alignment: .top, spacing: 12) {
            PosterBlurContainer(blurred: blurred, cornerRadius: 6) {
                RemotePoster(
                    url: posterURL,
                    apiKey: posterRequiresAuth ? apiKey : nil,
                    size: CGSize(width: posterWidth, height: posterHeight),
                    cornerRadius: 6,
                    fallbackSymbol: fallbackSymbol
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(3)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if let year { Text(verbatim: String(year)).foregroundStyle(.secondary) }
                    if let runtime, runtime > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(runtime) min").foregroundStyle(.secondary)
                    }
                    if let network, !network.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(network).foregroundStyle(.secondary)
                    }
                    if let cert = certification, !cert.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(cert).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
                if !genres.isEmpty {
                    GenreChips(genres: genres)
                }
                if !ratings.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(ratings, id: \.label) { RatingPill(chip: $0) }
                    }
                    .padding(.top, 2)
                }
                if let trailing {
                    trailing
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct RatingPill: View {
    let chip: RatingChip
    public var body: some View {
        HStack(spacing: 3) {
            Text(chip.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(chip.color)
            Text(chip.value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(chip.color.opacity(0.15), in: Capsule())
    }
}

struct GenreChips: View {
    let genres: [String]
    public var body: some View {
        TooltipFlowLayout(spacing: 4) {
            ForEach(genres, id: \.self) { g in
                Text(g)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
        }
        .padding(.top, 2)
    }
}

/// Custom-format tag chips with optional score, wrapping to multiple lines
/// when needed. Used in the detail download section to mirror the chip strip
/// shown on listing rows.
struct CustomFormatChips: View {
    let formats: [String]
    let score: Int
    public var body: some View {
        TooltipFlowLayout(spacing: 4) {
            ForEach(formats, id: \.self) { TagChip(text: $0) }
            if score != 0 {
                let sign = score > 0 ? "+" : ""
                TagChip(text: "\(sign)\(score)", color: score > 0 ? .green : .red)
            }
        }
    }
}

public struct ExpandableOverview: View {
    let text: String
    @State private var expanded = false
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
            if !expanded && text.count > 220 {
                Button {
                    withAnimation(.smooth(duration: 0.18)) { expanded = true }
                } label: {
                    Text("Show more")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SeasonRow: View {
    let season: SonarrSeasonInfo
    let episodes: [SonarrEpisodeDetail]
    @State private var expanded = false

    private var stats: SonarrSeasonStats? { season.statistics }
    private var have: Int { stats?.episodeFileCount ?? 0 }
    private var total: Int { stats?.totalEpisodeCount ?? stats?.episodeCount ?? 0 }
    private var pct: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(have) / Double(total))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.smooth(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(String(format: "Season %02d", season.seasonNumber))
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.primary.opacity(0.10))
                            RoundedRectangle(cornerRadius: 1)
                                .fill(have == total && total > 0 ? Color.green : Color.accentColor)
                                .frame(width: geo.size.width * pct)
                        }
                    }
                    .frame(width: 60, height: 3)
                    Text("\(have)/\(total)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(episodes.sorted(by: { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) })) { ep in
                        EpisodeRow(episode: ep)
                    }
                }
                .padding(.leading, 0)
                .padding(.trailing, 4)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 3)
    }
}

struct EpisodeRow: View {
    let episode: SonarrEpisodeDetail
    public var body: some View {
        HStack(spacing: 6) {
            Text(String(format: "%02d", episode.episodeNumber ?? 0))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .leading)
            Text(episode.title ?? "—")
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
            if let air = episode.airDateUtc.flatMap(parseArrDate) {
                Text(Self.formatter.string(from: air))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: episode.hasFile == true ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundStyle(episode.hasFile == true ? Color.green : Color.secondary.opacity(0.5))
        }
    }
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none
        return f
    }()
}

struct TrackRow: View {
    let track: LidarrTrackDetail
    public var body: some View {
        HStack(spacing: 6) {
            Text(track.trackNumber ?? String(track.absoluteTrackNumber ?? 0))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .leading)
            Text(track.title ?? "—")
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
            if let dur = track.duration, dur > 0 {
                Text(formatDuration(ms: dur))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: track.hasFile == true ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundStyle(track.hasFile == true ? Color.green : Color.secondary.opacity(0.5))
        }
    }
}

/// "Option B" download section: minimalist, no card chrome.
///
/// - Single item: one progress line + thin bar; if upgrade, a NEW/OLD
///   two-line diff and a monospaced release-name footer.
/// - Multiple items (ungrouped episodes for the same series): a header line
///   summarising the queue, then a stacked list of compact rows. The
///   originally-clicked row gets an accent left border so the user keeps
///   their bearings.
struct DownloadSection: View {
    let items: [QueueItem]
    let focused: QueueItem
    var showInlineUpgrade: Bool = true
    var showCustomFormats: Bool = false
    var showListingBadges: Bool = false
    var rowHoverDetail: Bool = false
    var listCollapsible: Bool = false
    var listExpandedDefault: Bool = true

    @State private var listExpanded: Bool

    init(
        items: [QueueItem],
        focused: QueueItem,
        showInlineUpgrade: Bool = true,
        showCustomFormats: Bool = false,
        showListingBadges: Bool = false,
        rowHoverDetail: Bool = false,
        listCollapsible: Bool = false,
        listExpandedDefault: Bool = true
    ) {
        self.items = items
        self.focused = focused
        self.showInlineUpgrade = showInlineUpgrade
        self.showCustomFormats = showCustomFormats
        self.showListingBadges = showListingBadges
        self.rowHoverDetail = rowHoverDetail
        self.listCollapsible = listCollapsible
        self.listExpandedDefault = listExpandedDefault
        self._listExpanded = State(initialValue: listExpandedDefault)
    }

    private var sortedItems: [QueueItem] {
        items.sorted { ($0.subtitle ?? "") < ($1.subtitle ?? "") }
    }

    public var body: some View {
        if items.count <= 1 {
            singleItemBlock(focused)
        } else {
            multiItemBlock
        }
    }

    // MARK: Single item

    @ViewBuilder
    private func singleItemBlock(_ item: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showListingBadges {
                listingBadges(item)
            }
            ProgressLine(item: item, hideDownloadClient: showListingBadges)
            ThinProgressBar(progress: item.progress, tint: item.status.tint)

            if showInlineUpgrade && item.isUpgrade {
                upgradeDiff(item)
                    .padding(.top, 4)
            }

            if showCustomFormats, !item.customFormats.isEmpty || item.customFormatScore != 0 {
                CustomFormatChips(formats: item.customFormats, score: item.customFormatScore)
            }

            if let release = item.releaseName, !release.isEmpty {
                Text(release)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    /// "Listing" badges that mirror the row-level title chips in QueueRowView:
    /// Upgrade/New capsule + download-client capsule. Used for Radarr's
    /// single-item card so the detail view echoes the listing's badges.
    @ViewBuilder
    private func listingBadges(_ item: QueueItem) -> some View {
        HStack(spacing: 4) {
            Text(item.isUpgrade ? "Upgrade" : "New")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(item.isUpgrade ? Color.indigo : Color.accentColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    (item.isUpgrade ? Color.indigo : Color.accentColor).opacity(0.15),
                    in: Capsule()
                )

            if let client = item.downloadClient {
                let color = downloadClientColor(client)
                Text(client)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(color.opacity(0.15), in: Capsule())
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func upgradeDiff(_ item: QueueItem) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
            GridRow {
                DiffTag(text: "NEW", style: .new)
                qualityCells(
                    quality: item.quality,
                    size: item.sizeTotal,
                    score: item.customFormatScore,
                    tags: item.customFormats
                )
            }
            GridRow {
                DiffTag(text: "OLD", style: .old)
                qualityCells(
                    quality: item.existingQuality,
                    size: item.existingSize ?? 0,
                    score: item.existingCustomFormatScore ?? 0,
                    tags: item.existingCustomFormats
                )
            }
        }
    }

    @ViewBuilder
    private func qualityCells(quality: String?, size: Int64, score: Int, tags: [String]) -> some View {
        HStack(spacing: 4) {
            if let q = quality, !q.isEmpty {
                Text(q)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
            if size > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            if score != 0 {
                Text("·").foregroundStyle(.tertiary)
                let sign = score > 0 ? "+" : ""
                Text("\(sign)\(score)")
                    .foregroundStyle(score > 0 ? Color.green : Color.red)
                    .font(.system(size: 11, weight: .semibold))
            }
            ForEach(tags, id: \.self) { TagChip(text: $0) }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    // MARK: Multi-item

    @ViewBuilder
    private var multiItemBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard listCollapsible else { return }
                withAnimation(.smooth(duration: 0.18)) { listExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if listCollapsible {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(listExpanded ? 90 : 0))
                    }
                    Text("In queue")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(items.count) downloads")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: aggregateSizeText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!listCollapsible)

            if !listCollapsible || listExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sortedItems) { it in
                        MultiRow(
                            item: it,
                            isFocused: it.id == focused.id,
                            showInlineUpgrade: showInlineUpgrade,
                            showCustomFormats: showCustomFormats,
                            hoverDetail: rowHoverDetail
                        )
                    }
                }
            }
        }
    }

    private var aggregateSizeText: String {
        let total = items.reduce(Int64(0)) { $0 + $1.sizeTotal }
        let left = items.reduce(Int64(0)) { $0 + $1.sizeLeft }
        let done = max(0, total - left)
        let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        let doneStr = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
        return "\(doneStr) / \(totalStr)"
    }
}

struct ProgressLine: View {
    let item: QueueItem
    var hideDownloadClient: Bool = false

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: item.status.symbol)
                .font(.system(size: 10))
                .foregroundStyle(item.status.tint)
            Text(LocalizedStringKey(item.status.displayName))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.status.tint)
            Text("·").foregroundStyle(.tertiary)
            Text(verbatim: "\(Int((item.progress * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            if let q = item.quality, !q.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(q)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let t = formattedTimeLeft {
                Text("·").foregroundStyle(.tertiary)
                Text(verbatim: t)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if item.sizeTotal > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text(verbatim: sizeText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !hideDownloadClient, let client = item.downloadClient {
                Spacer(minLength: 6)
                Text(client)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(downloadClientColor(client))
            }
        }
    }

    private var sizeText: String {
        let done = max(0, item.sizeTotal - item.sizeLeft)
        return "\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.sizeTotal, countStyle: .file))"
    }

    private var formattedTimeLeft: String? {
        guard let raw = item.timeLeft, !raw.isEmpty else { return nil }
        let trimmed = String(raw.prefix { $0 != "." })
        return trimmed == "00:00:00" ? nil : trimmed
    }
}


struct DiffTag: View {
    enum Style { case new, old }
    let text: String
    let style: Style

    public var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .tracking(0.5)
            .foregroundStyle(style == .new ? Color.accentColor : Color.secondary)
            .frame(width: 30, height: 14)
            .background(
                style == .new
                    ? Color.accentColor.opacity(0.18)
                    : Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 3)
            )
    }
}

/// One row inside the multi-item list: status dot, episode/quality text,
/// and a thin progress bar. When `hoverDetail` is true and the item is an
/// upgrade, the row reveals existing-file detail on demand:
///   - macOS: hovering for ~350 ms opens a popover anchored to the row.
///   - iOS:   tapping the row toggles the same content inline below it.
struct MultiRow: View {
    let item: QueueItem
    let isFocused: Bool
    var showInlineUpgrade: Bool = true
    var showCustomFormats: Bool = false
    var hoverDetail: Bool = false

    @State private var isHovering = false
    @State private var showHoverPopover = false
    @State private var hoverTask: Task<Void, Never>?
    /// iOS-only: tap-to-expand state for the inline existing-file block.
    @State private var showInlineExistingFile = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.status.symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(item.status.tint)
                if let code = episodeCode {
                    Text(code)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                Text(headlineText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if item.isUpgrade {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.indigo)
                }
                Spacer(minLength: 4)
                Text(trailingText)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            ThinProgressBar(progress: item.progress, tint: item.status.tint)
            if showCustomFormats, !item.customFormats.isEmpty || item.customFormatScore != 0 {
                CustomFormatChips(formats: item.customFormats, score: item.customFormatScore)
                    .padding(.top, 1)
            }
            if !hoverDetail, showInlineUpgrade, isFocused, item.isUpgrade {
                Text(verbatim: upgradeHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.indigo)
            }
            #if !os(macOS)
            // iOS: tap-to-expand existing-file block sits inline below
            // the row so we don't need a popover anchor.
            if hoverDetail, item.isUpgrade, showInlineExistingFile {
                ExistingFilePopover(item: item)
                    .padding(.top, 4)
            }
            #endif
        }
        .padding(.vertical, 3)
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(rowBackground)
        )
        .overlay(alignment: .leading) {
            if isFocused {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { hovering in
            guard hoverDetail, item.isUpgrade else { return }
            isHovering = hovering
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if !Task.isCancelled, isHovering { showHoverPopover = true }
                }
            } else {
                showHoverPopover = false
            }
        }
        .popover(isPresented: $showHoverPopover, arrowEdge: .trailing) {
            ExistingFilePopover(item: item)
        }
        #else
        .onTapGesture {
            guard hoverDetail, item.isUpgrade else { return }
            withAnimation(.smooth(duration: 0.18)) { showInlineExistingFile.toggle() }
        }
        #endif
    }

    private var rowBackground: Color {
        if isFocused { return Color.accentColor.opacity(0.06) }
        if hoverDetail, isHovering, item.isUpgrade { return Color.primary.opacity(0.04) }
        return .clear
    }

    private var episodeCode: String? {
        guard let s = item.seasonNumber, let e = item.episodeNumber else { return nil }
        return String(format: "S%02dE%02d", s, e)
    }

    /// Episode title + quality, joined by a dot.
    private var headlineText: String {
        var bits: [String] = []
        if let t = item.episodeTitle, !t.isEmpty { bits.append(t) }
        if let q = item.quality, !q.isEmpty { bits.append(q) }
        if bits.isEmpty, let release = item.releaseName, !release.isEmpty { bits.append(release) }
        return bits.joined(separator: " · ")
    }

    private var trailingText: String {
        if item.status == .queued { return "Queued" }
        return "\(Int((item.progress * 100).rounded()))%"
    }

    private var upgradeHint: String {
        var bits: [String] = ["↑ replacing"]
        if let q = item.existingQuality, !q.isEmpty { bits.append(q) }
        if let s = item.existingCustomFormatScore, s != 0 {
            let sign = s > 0 ? "+" : ""
            bits.append("(\(sign)\(s))")
        }
        return bits.joined(separator: " ")
    }
}

/// Full-width existing-file banner for Radarr details. Sits between the
/// header card and the overview so the chips have room to breathe.
struct ExistingFileBanner: View {
    let item: QueueItem
    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.doc.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.indigo)
                Text("Existing file")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                if let q = item.existingQuality, !q.isEmpty {
                    Text(q)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }
                if let size = item.existingSize, size > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let s = item.existingCustomFormatScore, s != 0 {
                    Text("·").foregroundStyle(.tertiary)
                    let sign = s > 0 ? "+" : ""
                    Text("\(sign)\(s)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(s > 0 ? Color.green : Color.red)
                }
            }
            if !item.existingCustomFormats.isEmpty {
                TooltipFlowLayout(spacing: 4) {
                    ForEach(item.existingCustomFormats, id: \.self) { TagChip(text: $0) }
                }
            }
            if let name = item.existingFileName, !name.isEmpty {
                Text(name)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.indigo.opacity(0.06))
        )
    }
}

/// Compact one-line summary of the existing file an item would replace.
/// Used in Radarr's header card under the rating chips.
struct ExistingFileLine: View {
    let item: QueueItem

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(.indigo)
                Text("Existing")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.indigo)
                if let q = item.existingQuality, !q.isEmpty {
                    Text(q)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let size = item.existingSize, size > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let s = item.existingCustomFormatScore, s != 0 {
                    Text("·").foregroundStyle(.tertiary)
                    let sign = s > 0 ? "+" : ""
                    Text("\(sign)\(s)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(s > 0 ? Color.green : Color.red)
                }
            }
            if !item.existingCustomFormats.isEmpty {
                TooltipFlowLayout(spacing: 3) {
                    ForEach(item.existingCustomFormats, id: \.self) { TagChip(text: $0) }
                }
            }
        }
    }
}

/// Hover popover for ungrouped Sonarr rows that reveals the existing-file
/// details an upgrade would replace. Mirrors the chrome of `QueueItemTooltip`.
struct ExistingFilePopover: View {
    let item: QueueItem

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.doc.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.indigo)
                Text("Will replace existing file")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.indigo)
            }

            if let sub = item.subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                if let q = item.existingQuality, !q.isEmpty {
                    Text(q).foregroundStyle(.primary)
                }
                if let size = item.existingSize, size > 0 {
                    if item.existingQuality?.isEmpty == false {
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .foregroundStyle(.primary)
                }
                if let s = item.existingCustomFormatScore, s != 0 {
                    Text("·").foregroundStyle(.tertiary)
                    let sign = s > 0 ? "+" : ""
                    Text("\(sign)\(s)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(s > 0 ? Color.green : Color.red)
                }
            }
            .font(.system(size: 11))

            if !item.existingCustomFormats.isEmpty {
                TooltipFlowLayout(spacing: 3) {
                    ForEach(item.existingCustomFormats, id: \.self) { TagChip(text: $0) }
                }
            }

            if let name = item.existingFileName, !name.isEmpty {
                Text(name)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .frame(width: 320)
        .background(.regularMaterial)
    }
}

func formatDuration(ms: Int) -> String {
    let total = ms / 1000
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
