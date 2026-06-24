import SwiftUI

public extension QueueItem.Status {
    var symbol: String {
        switch self {
        case .downloading: return "arrow.down.circle.fill"
        case .paused: return "pause.circle.fill"
        case .queued: return "clock.fill"
        case .importing: return "tray.and.arrow.down.fill"
        case .completed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .paused: return .orange
        // Queued / deferred sits between "missing" (grey) and "paused" (orange):
        // a muted amber so it reads as "waiting", not active and not stopped.
        case .queued: return Color(hue: 0.09, saturation: 0.42, brightness: 0.72)
        case .failed, .warning: return .red
        case .completed: return .green
        case .importing: return .purple
        default: return .blue
        }
    }
}

public struct QueueRowView: View {
    let item: QueueItem

    /// Compound title: `Show · S03E04 · Episode title` for series rows,
    /// plain title for movies. Lets every row stay one title line tall
    /// regardless of source so the diff line below sits flush with the
    /// poster bottom.
    private var rowTitle: String {
        if let sub = item.subtitle, !sub.isEmpty {
            return "\(item.title) · \(sub)"
        }
        return item.title
    }

    /// Action callbacks instead of an `@ObservedObject viewModel` so the row
    /// re-renders only when its own `item` value changes — not on every
    /// QueueViewModel publish. Closures are wrapped in `Equatable` checks at
    /// the SwiftUI diff level via the surrounding `ForEach(... id: \.id)`.
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void
    var onShowDetail: (() -> Void)? = nil
    @EnvironmentObject var configStore: ConfigStore
    /// Surfaces that have a permanent detail pane (the desktop window) set
    /// this to `true` so we skip the redundant long-hover tooltip. The
    /// menu-bar popover leaves it false.
    @Environment(\.suppressRowTooltip) private var suppressRowTooltip
    /// True when the whole arr stack is unreachable — hide the mutating
    /// controls (they'd fail without a live LAN connection).
    @Environment(\.queueOffline) private var isOffline
    @State private var isHovering = false
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    /// Posts the trash request to the shared ConfirmCenter so the
    /// overlay can render at panel-full width — `.overlay` rendered
    /// inline on this row clips the card to row bounds and the button
    /// labels truncate.
    private func requestDeleteConfirm() {
        ConfirmCenter.request(PendingConfirm(
            title: "Cancel this download?",
            message: "This will remove the download from the client.",
            confirmLabel: "Cancel download",
            cancelLabel: "Keep download",
            isDestructive: true,
            onConfirm: onDelete
        ))
    }

    /// Pause/resume go straight to the download client (not via the arr), so
    /// they need a client that's both *configured* and *reachable*. The common
    /// away-from-home case — arrs exposed publicly, download clients LAN-only —
    /// keeps the queue visible (and delete works, since the arr performs it) but
    /// must hide pause/resume because they'd just fail. `.unknown` (not yet
    /// probed) stays allowed; only a confirmed `.down` gates.
    private var canControl: Bool {
        guard let kind = configStore.selectedDownloadClient(for: item.downloadProtocol) else { return false }
        if case .down = ConnectionHealth.shared.state(for: .arr(kind)) { return false }
        return true
    }

    private var canPauseResume: Bool {
        item.status == .downloading || item.status == .paused || item.status == .queued
    }

    /// A queued (deferred / behind the client's queue limit) item or a paused
    /// one both get the "play" affordance — for queued it force-starts.
    private var showsPlay: Bool {
        item.isPaused || item.status == .queued
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PosterBlurContainer(blurred: configStore.shouldBlurPoster(for: item.source), cornerRadius: Tokens.Radius.chip) {
                RemotePoster(
                    url: item.posterURL,
                    apiKey: item.posterRequiresAuth ? apiKeyForSource : nil,
                    size: posterSize,
                    cornerRadius: Tokens.Radius.chip,
                    fallbackSymbol: item.source.symbol
                )
            }
            // macOS: pause/resume lives ON the poster (hover-revealed). The row
            // has no delete button — cancelling a download is intentionally out
            // of the glanceable queue list.
            #if os(macOS)
            .overlay {
                if isHovering && canControl && canPauseResume && !isOffline {
                    posterControl.transition(.opacity)
                }
            }
            #endif

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        // Title row carries the full identity — for
                        // series it's "Show · S03E04 · Episode title"
                        // (instead of a separate subtitle line) so
                        // series and movie rows share the same height
                        // and the diff line below isn't pushed past
                        // the poster.
                        Text(rowTitle)
                            .scaledFont(size: 12)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        // Chevron next to title telegraphs "this drills
                        // into a detail view" without relying on hover.
                        LinkChevron(size: 9)

                        Spacer(minLength: 4)

                        // Upgrade/New badge lives here on the title row's
                        // trailing edge (moved out of the progress card's
                        // header below).
                        MediaBadgeCluster(isUpgrade: item.isUpgrade)
                    }

                    // Status + meta + score row dropped — same info
                    // now lives inside `DownloadProgressCard`'s
                    // header below. Quality / size / client all live
                    // in the long-hover tooltip so the row stays
                    // glanceable: title + status card, period.
                }

                DownloadProgressCard(
                    item: item,
                    fadeTrailing: !(isHovering && canControl),
                    showUpgradeDiff: false,
                    showHeader: true,
                    showBadge: false,
                    compactSpec: true
                )

                // Custom-format strip replaces the old release-name line:
                // the incoming file's custom formats as muted chips (TagChip,
                // like the diff view). Kept to a SINGLE line — overflow fades
                // out under a trailing transparency gradient instead of
                // wrapping or hard-clipping.
                if !item.customFormats.isEmpty {
                    // A horizontal ScrollView takes the PROPOSED width and
                    // clips overflow, so it never widens the row (the prior
                    // `.fixedSize()` propagated the chips' full intrinsic
                    // width up, making each row as wide as its tag count).
                    // Scrolling is disabled — the trailing gradient just
                    // fades the overflow into transparency.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3) {
                            ForEach(item.customFormats, id: \.self) { tag in
                                TagChip(text: tag, color: .secondary)
                            }
                        }
                    }
                    .scrollDisabled(true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .mask(
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.85),
                                .init(color: .clear, location: 1.0),
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                }
            }
        }
        .padding(.horizontal, Tokens.Spacing.queueRowH)
        .padding(.vertical, 6)
        // No row hover-tint background — only the chevron reacts to hover; the
        // poster reveals its pause/resume control on hover instead.
        // ContentShape + onTapGesture before the hover overlay so the
        // overlay's action icons keep their own hit-testing — without
        // this order the row-wide tap-gesture swallowed clicks on the
        // trash icon and the action never fired.
        .contentShape(Rectangle())
        .onTapGesture {
            onShowDetail?()
        }
        .contextMenu {
            // Offline → no mutating menu items; the header chip explains why.
            if !isOffline {
                if canControl && canPauseResume {
                    Button {
                        if showsPlay { onResume() } else { onPause() }
                    } label: {
                        if item.status == .queued {
                            Label { Text("queue.startNow.button", bundle: .module) } icon: { Image(systemName: "play.fill") }
                        } else if item.isPaused {
                            Label { Text("queue.resume.button", bundle: .module) } icon: { Image(systemName: "play.fill") }
                        } else {
                            Label { Text("queue.pause.button", bundle: .module) } icon: { Image(systemName: "pause.fill") }
                        }
                    }
                }
                Button(role: .destructive) {
                    requestDeleteConfirm()
                } label: {
                    Label { Text("queue.removeFromQueue.button", bundle: .module) } icon: { Image(systemName: "trash") }
                }
            }
        }
        // Hover-only affordances live on macOS. On iOS the same information
        // is available by tapping into the detail view, and the floating
        // tooltip popover would render as a sheet — wrong UX for a brief
        // glance. So both the hover-state row tint and the long-hover
        // tooltip are macOS-only.
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
            hoverTask?.cancel()
            if hovering && !suppressRowTooltip {
                hoverTask = Task { @MainActor [self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if !Task.isCancelled && self.isHovering { showTooltip = true }
                }
            } else {
                // Tooltip is now read-only (no action buttons), so we
                // can close it immediately on row hover-out — no need
                // to keep it alive for the user to reach controls.
                showTooltip = false
            }
        }
        // .applicationDefined behaviour (baked into tooltipPopover) keeps
        // the popover from being eaten by a stray first-click; we close it
        // ourselves on row hover-out.
        .tooltipPopover(isPresented: $showTooltip, arrowEdge: .trailing) {
            QueueItemTooltip(
                item: item,
                apiKey: item.posterRequiresAuth ? apiKeyForSource : nil,
                locale: configStore.currentLocale
            )
        }
        #endif
        // Light up the drill-in LinkChevron whenever the row is hovered
        // (reuses the existing isHovering, no extra onHover).
        .environment(\.linkRowHovering, isHovering)
        // No local overlay — trash button now posts to
        // `ConfirmCenter.shared` (see requestDeleteConfirm) so the
        // confirmation renders at panel-full width from
        // PopoverContentView's body.
    }

    // MARK: - Poster helpers

    private var posterSize: CGSize {
        switch item.source {
        case .radarr, .sonarr, .whisparr: return CGSize(width: 40, height: 60)
        case .lidarr: return CGSize(width: 40, height: 40)
        }
    }

    private var apiKeyForSource: String? {
        configStore.serviceConfig(for: item.source).apiKey
    }

    // MARK: - Actions

    #if os(macOS)
    /// Pause/resume affordance overlaid on the poster (hover-revealed). The
    /// queue row has no delete button on macOS — cancelling a download is
    /// intentionally out of the glanceable list (use the detail view / the
    /// *arr). iOS keeps swipe actions (see QueueListView).
    @ViewBuilder
    private var posterControl: some View {
        Button {
            if showsPlay { onResume() } else { onPause() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                    .fill(.black.opacity(0.5))
                DownloadProgressRing(
                    systemName: showsPlay ? "play.fill" : "pause.fill",
                    progress: item.progress,
                    diameter: 26,
                    lineWidth: 2
                )
            }
        }
        .buttonStyle(.plain)
        .help(item.status == .queued
              ? Text("queue.startNow.button", bundle: .module)
              : (item.isPaused ? Text("queue.resume.button", bundle: .module) : Text("queue.pause.button", bundle: .module)))
    }
    #endif
}


// MARK: - Rich tooltip

public struct QueueItemTooltip: View {
    let item: QueueItem
    var apiKey: String? = nil
    var locale: Locale = Locale(identifier: "en")
    @EnvironmentObject var configStore: ConfigStore

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterBlurContainer(blurred: configStore.shouldBlurPoster(for: item.source), cornerRadius: Tokens.Radius.card) {
                RemotePoster(
                    url: item.posterURL,
                    apiKey: apiKey,
                    size: posterSize,
                    cornerRadius: Tokens.Radius.card,
                    fallbackSymbol: item.source.symbol
                )
            }
            tooltipContent
        }
        .padding(12)
        .frame(width: 480)
        // No `.background(.regularMaterial)` — that would paint a SwiftUI
        // material brighter than NSPopover's native chrome, making the
        // tooltip read as a lighter rectangle next to the parent popover.
        // PopoverBehaviorAdjuster clears the hosting view's layer instead
        // so the native chrome shines through and the tooltip matches.
    }

    private var posterSize: CGSize {
        switch item.source {
        case .radarr, .sonarr, .whisparr: return CGSize(width: 110, height: 165)
        case .lidarr: return CGSize(width: 110, height: 110)
        }
    }

    private var tooltipContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            // Experiment: upgrades now use the extracted side-by-side
            // `UpgradeDiffView` (current file → incoming, with gained/lost
            // format chips) instead of the inline grid diff. The grid then
            // only carries the contextual extras the diff view doesn't cover
            // (indexer, release file name, replaced on-disk path).
            if item.isUpgrade {
                UpgradeDiffView(item: item, showFilenames: true)
            }
            infoGrid

            // For non-upgrades the side-by-side doesn't apply, so keep the
            // plain custom-format chip strip. Upgrades get their gained/lost
            // chips from `UpgradeDiffView` above.
            if !item.isUpgrade, !item.customFormats.isEmpty || item.customFormatScore != 0 {
                customFormatChipStrip(
                    tags: item.customFormats,
                    score: item.customFormatScore != 0 ? item.customFormatScore : nil
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Match QueueRowView's title pattern: title + Upgrade tag
            // adjacent on the left, download client neutralised on the
            // trailing edge. The colour-collision rationale that drove
            // the change on the row applies to the tooltip too — the
            // tooltip just had it independently.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.title)
                    .scaledFont(size: 13, weight: .semibold)
                    .lineLimit(2)
                Spacer(minLength: 4)
                // Upgrade/New badge sits on the right next to the download
                // client (not crowding the title on the left).
                MediaBadgeCluster(isUpgrade: item.isUpgrade, size: .medium)
                if let client = item.downloadClient {
                    DownloadClientLabel(name: client, size: 10)
                }
            }
            if let sub = item.subtitle {
                Text(sub)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var infoGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
            // Quality / Size only for non-upgrades — for upgrades the incoming
            // quality and size already live in `UpgradeDiffView` above.
            if !item.isUpgrade {
                if let q = item.quality, !q.isEmpty {
                    row("Quality", value: "\(q) · \(sizeString)")
                } else {
                    row("Size", value: sizeString)
                }
            }
            if let indexer = item.indexer, !indexer.isEmpty {
                row("Indexer", value: indexer)
            }
            // Release file name: only for non-upgrades here. Upgrades render
            // the old→new quality diff AND both filenames (untruncated) inside
            // `UpgradeDiffView` above, so the grid stays out of their way and
            // only carries the indexer — otherwise the tooltip showed the same
            // comparison twice (the arrow diff plus a stacked duplicate).
            if !item.isUpgrade, let file = item.releaseName, !file.isEmpty {
                row("File", value: file, mono: true, wraps: true)
            }
        }
    }

    private var sizeString: String {
        ByteCountFormatter.string(fromByteCount: item.sizeTotal, countStyle: .file)
    }

    @ViewBuilder
    private func row(_ label: String, value: String, valueColor: Color? = nil, mono: Bool = false, wraps: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(label), bundle: .module)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .foregroundStyle(valueColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                .lineLimit(wraps ? nil : 2)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

func downloadClientColor(_ name: String) -> Color {
    let n = name.lowercased()
    if n.contains("sab") { return .orange }
    if n.contains("nzbget") { return .green }
    if n.contains("qbit") { return .blue }
    if n.contains("transmission") { return .red }
    if n.contains("rtorrent") || n.contains("rutorrent") { return .teal }
    if n.contains("deluge") { return .purple }
    return .gray
}

// `customFormatChipStrip` + `TagChip` + `TooltipFlowLayout` are
// now in `Chips.swift`.

// `TooltipActionButton` + `IconButton` are now in
// `ActionPrimitives.swift`.

// MARK: - Shared row chrome
//
// SwiftUI's linear `ProgressView` silently ignores `.frame(height: 3)`,
// which is what made the Sonarr group rows render visibly thicker than
// Radarr/Lidarr rows even though both wrote the same modifier. Every
// progress bar in the app — listing rows, group rows, season tooltips,
// detail panels — now goes through `ThinProgressBar` so thickness stays
// pixel-identical regardless of context.
public struct ThinProgressBar: View {
    let progress: Double
    /// Filled-portion tint — typically `status.tint` (blue for
    /// Downloading, orange for Paused, red for Warning). Restored
    /// after an earlier neutral-white iteration: with multiple
    /// download protocols / states on screen at once, the colour
    /// is what makes a paused row jump out from a downloading one
    /// at a glance. The status icon alone wasn't enough.
    var tint: Color = .primary
    var height: CGFloat = 3

    public init(progress: Double, tint: Color = .primary, height: CGFloat = 3) {
        self.progress = progress
        self.tint = tint
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.primary.opacity(0.12))
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(tint)
                    .frame(width: geo.size.width * max(0, min(1, progress)))
            }
        }
        .frame(height: height)
    }
}

// `CustomFormatStrip` lives in `Chips.swift` now.
