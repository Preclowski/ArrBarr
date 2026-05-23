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
                // Title + year on one line ("Movie Title (1994)"). The
                // metadata strip below loses its leading "1994 · " segment;
                // saves a whole text row of vertical space and reads more
                // like the way people refer to films in conversation.
                titleWithYear
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(3)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if hasMetadataStrip {
                    metadataStrip
                        .font(.system(size: 11))
                }
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

    private var titleWithYear: Text {
        if let year {
            return Text(verbatim: "\(title) (\(year))")
        }
        return Text(verbatim: title)
    }

    private var hasMetadataStrip: Bool {
        (runtime ?? 0) > 0
            || (network.map { !$0.isEmpty } ?? false)
            || (certification.map { !$0.isEmpty } ?? false)
    }

    /// Metadata dots row — runtime · network · certification. Year used to
    /// lead this row but moved into the title above, which also means we
    /// only render the row when at least one of the remaining bits exists.
    @ViewBuilder
    private var metadataStrip: some View {
        HStack(spacing: 6) {
            let segments: [String] = [
                (runtime ?? 0) > 0 ? "\(runtime!) min" : nil,
                network.flatMap { $0.isEmpty ? nil : $0 },
                certification.flatMap { $0.isEmpty ? nil : $0 },
            ].compactMap { $0 }
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                if idx > 0 { Text("·").foregroundStyle(.tertiary) }
                Text(segment).foregroundStyle(.secondary)
            }
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
                    Text("Show more", bundle: .module)
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
    /// Per-season search trigger. DetailView passes the closure (which
    /// wraps `SonarrClient.searchSeason`); nil disables the affordance.
    var onSearchSeason: (() async -> Void)? = nil
    /// Per-episode search forwarded to `EpisodeRow`.
    var onSearchEpisode: ((Int) async -> Void)? = nil

    @State private var expanded = false
    @State private var isHoveringHeader = false
    @State private var isSearchingSeason = false
    @State private var didSearchSeason = false

    private var stats: SonarrSeasonStats? { season.statistics }
    private var have: Int { stats?.episodeFileCount ?? 0 }
    private var total: Int { stats?.totalEpisodeCount ?? stats?.episodeCount ?? 0 }
    private var missing: Int { max(0, total - have) }
    private var pct: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(have) / Double(total))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ZStack-level onHover, not Button-level. The pill is its own
            // Button — if hover-tracking lived on the header Button below,
            // the pill's hit area would steal it the moment the cursor
            // crossed the pill, dropping isHoveringHeader to false, fading
            // the pill back out, ping-ponging into the visible "blink" the
            // user reported. Tracking on the ZStack keeps both children
            // inside one hover region.
            ZStack(alignment: .trailing) {
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

                if missing > 0, onSearchSeason != nil {
                    searchSeasonButton
                        .opacity(isHoveringHeader || isSearchingSeason || didSearchSeason ? 1 : 0)
                        .allowsHitTesting(isHoveringHeader || isSearchingSeason || didSearchSeason)
                        .animation(.easeOut(duration: 0.12), value: isHoveringHeader)
                        .animation(.easeOut(duration: 0.12), value: didSearchSeason)
                        .offset(x: -2)
                }
            }
            #if os(macOS)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) { isHoveringHeader = hovering }
            }
            #endif

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(episodes.sorted(by: { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) })) { ep in
                        EpisodeRow(episode: ep, onSearch: onSearchEpisode)
                    }
                }
                .padding(.leading, 0)
                .padding(.trailing, 4)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 3)
    }

    private var searchSeasonButton: some View {
        Button(action: fireSeasonSearch) {
            HStack(spacing: 3) {
                if isSearchingSeason {
                    ProgressView().controlSize(.mini)
                } else if didSearchSeason {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .medium))
                    Text("Search \(missing)", bundle: .module)
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassPill()
        .disabled(isSearchingSeason)
        .help(Text("Search for missing episodes in this season", bundle: .module))
    }

    private func fireSeasonSearch() {
        guard let onSearchSeason, !isSearchingSeason else { return }
        isSearchingSeason = true
        Task {
            await onSearchSeason()
            await MainActor.run {
                isSearchingSeason = false
                didSearchSeason = true
            }
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run { didSearchSeason = false }
        }
    }
}

struct EpisodeRow: View {
    let episode: SonarrEpisodeDetail
    /// Optional search trigger. Provided by DetailView (Sonarr), wired
    /// to `SonarrClient.searchEpisodes`. Only meaningful when the episode
    /// is missing — otherwise the indicator falls through to the file
    /// state (green check) and no action surface appears.
    var onSearch: ((Int) async -> Void)? = nil

    @State private var isHovering = false
    @State private var isSearching = false
    /// Brief feedback after the command was accepted by Sonarr. The
    /// indexer search happens in the background; user just gets a quick
    /// "got it" pulse, then back to normal.
    @State private var didSearch = false

    private var isMissing: Bool { episode.hasFile != true }

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
            // Single indicator slot — the empty circle (when missing) is
            // swapped *in place* for a magnifyingglass on hover, so the
            // row doesn't shift horizontally and the affordance lands
            // where the user is already looking. State machine:
            //   has file → green check, no action
            //   missing + idle → empty circle
            //   missing + hover → magnifyingglass (tappable)
            //   searching → spinner
            //   just searched → brief green check
            stateIndicator
                .frame(width: 14, height: 14, alignment: .center)
        }
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
        #endif
    }

    @ViewBuilder
    private var stateIndicator: some View {
        if isSearching {
            ProgressView().controlSize(.mini)
        } else if didSearch {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
        } else if isMissing, isHovering, onSearch != nil {
            Button(action: fireSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Search for this episode", bundle: .module))
        } else {
            Image(systemName: episode.hasFile == true ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundStyle(episode.hasFile == true ? Color.green : Color.secondary.opacity(0.5))
        }
    }

    private func fireSearch() {
        guard let onSearch, !isSearching else { return }
        isSearching = true
        Task {
            await onSearch(episode.id)
            await MainActor.run {
                isSearching = false
                didSearch = true
            }
            // Quick confirmation pulse — keep it short so the row doesn't
            // sit in "done" state forever.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { didSearch = false }
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

    /// Wrapper that defers to the public `ListingBadgesView`. Kept so the
    /// DownloadSection's existing `if showListingBadges` block doesn't need
    /// to reach into the public namespace.
    @ViewBuilder
    private func listingBadges(_ item: QueueItem) -> some View {
        ListingBadgesView(item: item)
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
        // One row was cramming status + percentage + quality + time left +
        // size + client all on a single line, which wrapped "Downloading" to
        // two lines on narrow popovers. Split: status / progress / client on
        // top (the "what's happening" line), technical details (quality ·
        // time · size) below.
        VStack(alignment: .leading, spacing: 2) {
            statusRow
            if hasDetails { detailsRow }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 4) {
            Image(systemName: item.status.symbol)
                .font(.system(size: 10))
                .foregroundStyle(item.status.tint)
            Text(LocalizedStringKey(item.status.displayName))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.status.tint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text("·").foregroundStyle(.tertiary)
            Text(verbatim: "\(Int((item.progress * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            if !hideDownloadClient, let client = item.downloadClient {
                Spacer(minLength: 6)
                Text(client)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(downloadClientColor(client))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var detailsRow: some View {
        HStack(spacing: 4) {
            let segments: [String] = [
                item.quality.flatMap { $0.isEmpty ? nil : $0 },
                formattedTimeLeft,
                item.sizeTotal > 0 ? sizeText : nil,
            ].compactMap { $0 }
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                if idx > 0 { Text("·").foregroundStyle(.tertiary) }
                Text(verbatim: segment)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hasDetails: Bool {
        (item.quality?.isEmpty == false) || formattedTimeLeft != nil || item.sizeTotal > 0
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
/// "Listing" badges mirroring the queue row's title chips: Upgrade/New
/// capsule + download-client capsule. Shown in the movie detail header
/// (under the ratings) so the user knows which client is grinding away
/// without having to scroll to the download section.
public struct ListingBadgesView: View {
    let item: QueueItem

    /// Only the Upgrade pill, and only when the row is actually an upgrade.
    /// "New" is implicit (no existing-file banner = brand new download), and
    /// the download client already shows up in `ProgressLine` below — both
    /// previously duplicated here.
    public var body: some View {
        if item.isUpgrade {
            HStack(spacing: 4) {
                Text("Upgrade")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.indigo)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.indigo.opacity(0.15), in: Capsule())
                Spacer()
            }
        }
    }
}

/// Banner describing the file an arr already has on disk for this item.
/// Two callers:
///   - upgrade-in-progress (queue item) — fields come from the queue
///     row's `existing*` metadata
///   - already-in-library (no active queue) — fields come from
///     `RadarrMovieDetail.movieFile` / similar
/// The view body is the same; only the source of the fields differs.
struct ExistingFileBanner: View {
    let quality: String?
    let size: Int64?
    let customFormatScore: Int?
    let customFormats: [String]
    let fileName: String?

    init(quality: String?, size: Int64?, customFormatScore: Int?,
         customFormats: [String], fileName: String?) {
        self.quality = quality; self.size = size
        self.customFormatScore = customFormatScore
        self.customFormats = customFormats
        self.fileName = fileName
    }

    /// Build the banner from a queue row's `existing*` fields (upgrade-time
    /// metadata Radarr/Sonarr send when a download will replace something).
    init(item: QueueItem) {
        self.init(
            quality: item.existingQuality,
            size: item.existingSize,
            customFormatScore: item.existingCustomFormatScore,
            customFormats: item.existingCustomFormats,
            fileName: item.existingFileName
        )
    }

    /// Build the banner from an arr's library `movieFile` — the file the
    /// user already owns, no queue activity required.
    init(movieFile: ArrFile) {
        self.init(
            quality: movieFile.quality?.name,
            size: movieFile.size,
            customFormatScore: movieFile.customFormatScore,
            customFormats: (movieFile.customFormats ?? []).map(\.name),
            fileName: movieFile.relativePath
        )
    }

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
                if let q = quality, !q.isEmpty {
                    Text(q)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }
                if let size, size > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let s = customFormatScore, s != 0 {
                    Text("·").foregroundStyle(.tertiary)
                    let sign = s > 0 ? "+" : ""
                    Text("\(sign)\(s)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(s > 0 ? Color.green : Color.red)
                }
            }
            if !customFormats.isEmpty {
                TooltipFlowLayout(spacing: 4) {
                    ForEach(customFormats, id: \.self) { TagChip(text: $0) }
                }
            }
            if let name = fileName, !name.isEmpty {
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
        // Match QueueItemTooltip — no SwiftUI material backdrop, so the
        // native NSPopover chrome carries through.
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
