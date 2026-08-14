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

/// Attaches the row's open-detail tap only when an action is set. With a nil
/// action the gesture is omitted (not just a no-op closure) so it doesn't
/// swallow the click `List(selection:)` needs in queue multi-select mode.
/// (Shared by `QueueGroupRowView`, which has the same row-tap.)
struct RowTapToOpen: ViewModifier {
    let action: (() -> Void)?
    func body(content: Content) -> some View {
        if let action {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}

/// Whether (and how) a queue row shows its multi-select circle over the
/// poster. `.hidden` = normal mode (no overlay); the others draw a hollow /
/// filled selection ring on a dark scrim on top of the artwork.
enum RowSelectionState { case hidden, unselected, selected }

/// The selection ring overlaid ON the poster in multi-select mode — the
/// artwork stays visible under a dark scrim so the row keeps its identity;
/// accent + filled when selected, hollow white otherwise.
struct SelectionCircle: View {
    let selected: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                .fill(.black.opacity(selected ? 0.45 : 0.30))
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white.opacity(0.9)))
        }
        .contentShape(Rectangle())
        // The ring mirrors the row's selection state, which the row
        // itself publishes via the `.isSelected` trait — announcing
        // "checkmark circle fill" on top of that is just noise.
        .accessibilityHidden(true)
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
    /// Multi-select state — `.hidden` (default) = no overlay; otherwise the
    /// selection circle is drawn over the poster.
    var selectionState: RowSelectionState = .hidden
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
        // Demo has no download client to configure, and hiding pause/resume
        // there would hide one of the things the demo exists to show. The
        // action is served by the fixture state — see DemoQueueState.
        if DemoMode.isActive { return true }
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
            // Multi-select mode overlays the selection ring ON the poster
            // (dark scrim + circle) — the artwork stays visible underneath.
            PosterBlurContainer(blurred: configStore.shouldBlurPoster(for: item.source), cornerRadius: Tokens.Radius.chip) {
                RemotePoster(
                    url: item.posterURL,
                    apiKey: item.posterRequiresAuth ? apiKeyForSource : nil,
                    tier: .icon,
                    size: posterSize,
                    cornerRadius: Tokens.Radius.chip,
                    fallbackSymbol: item.source.symbol
                )
            }
            // macOS: pause/resume lives ON the poster (hover-revealed). The row
            // has no delete button — cancelling a download is intentionally out
            // of the glanceable queue list. Suppressed while selecting — the
            // poster is the checkbox then.
            #if os(macOS)
            .overlay {
                if selectionState == .hidden && isHovering && canControl && canPauseResume && !isOffline {
                    posterControl.transition(.opacity)
                }
            }
            #endif
            .overlay {
                if selectionState != .hidden {
                    SelectionCircle(selected: selectionState == .selected)
                        .transition(.opacity)
                }
            }

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
                        // Hidden from VoiceOver — the row's own `.isButton`
                        // trait + hint say the same thing.
                        LinkChevron(size: 9)
                            .accessibilityHidden(true)

                        Spacer(minLength: 4)

                        // Upgrade/New badge on the title line's trailing edge —
                        // the card's status row below has no room for it next
                        // to the client label + quality · size spec.
                        MediaBadgeCluster(isUpgrade: item.isUpgrade)
                    }

                    // Status / badge / client / quality / size live in
                    // `DownloadProgressCard`'s header below; the score
                    // trails the custom-format strip under it.
                }

                DownloadProgressCard(
                    item: item,
                    showUpgradeDiff: false,
                    showHeader: true,
                    compactSpec: true
                )

                // Custom-format strip replaces the old release-name line:
                // the incoming file's custom formats as muted chips, with the
                // custom-format score pinned on the row's trailing edge.
                if !item.customFormats.isEmpty || item.customFormatScore != 0 {
                    QueueRowFormatStrip(
                        formats: item.customFormats,
                        score: item.customFormatScore,
                        baseline: item.existingCustomFormatScore
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
        // Row-tap opens the detail — but ONLY when there's a target. The queue's
        // multi-select mode passes `onShowDetail: nil`, which drops the gesture
        // entirely so the List's own selection click isn't swallowed.
        .modifier(RowTapToOpen(action: onShowDetail))
        // VoiceOver would otherwise walk this row as a dozen disconnected
        // fragments (title, badge, status word, quality, size, score, every
        // custom-format chip). Merge them into one element, hand the progress
        // bar's fill over as the element's value, and — since the row is a
        // bare tap gesture, not a Button — say out loud that it's tappable.
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(max(0.0, min(1.0, item.progress)), format: .percent.precision(.fractionLength(0))))
        .accessibilityAddTraits(onShowDetail != nil ? .isButton : [])
        .accessibilityAddTraits(selectionState == .selected ? .isSelected : [])
        .accessibilityHint(onShowDetail != nil
                           ? Text("Show download details", bundle: .module)
                           : Text(verbatim: ""))
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
        // `.help` is a tooltip, not a label — without this the button
        // announces as "play fill" / "pause fill".
        .accessibilityLabel(item.status == .queued
                            ? Text("queue.startNow.button", bundle: .module)
                            : (item.isPaused ? Text("queue.resume.button", bundle: .module) : Text("queue.pause.button", bundle: .module)))
    }
    #endif
}


// MARK: - Custom-format strip (queue rows)

/// One-line custom-format chip strip with the custom-format score pinned on
/// the trailing edge. Shared by `QueueRowView` and `QueueGroupRowView` so the
/// score sits in the same spot on single and season-pack rows. Chips keep to
/// a SINGLE line — overflow fades out under a trailing transparency gradient
/// instead of wrapping or hard-clipping.
struct QueueRowFormatStrip: View {
    let formats: [String]
    let score: Int
    let baseline: Int?

    var body: some View {
        HStack(spacing: 6) {
            // A horizontal ScrollView takes the PROPOSED width and clips
            // overflow, so it never widens the row (a `.fixedSize()` here
            // would propagate the chips' full intrinsic width up, making
            // each row as wide as its tag count). Scrolling is disabled —
            // the trailing gradient just fades the overflow into
            // transparency.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(formats, id: \.self) { tag in
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
            if score != 0 {
                ScoreLabel(score: score, baseline: baseline, size: 10)
            }
        }
    }
}

// MARK: - Rich tooltip

public struct QueueItemTooltip: View {
    let item: QueueItem
    var apiKey: String? = nil
    var locale: Locale = Locale(identifier: "en")
    @EnvironmentObject var configStore: ConfigStore

    public var body: some View {
        // Shared tooltip chrome — one footprint/header/poster treatment for
        // every media tooltip (see MediaTooltipChrome).
        MediaTooltipChrome(
            title: item.title,
            subtitle: item.subtitle,
            posterURL: item.posterURL,
            posterRequiresAuth: apiKey != nil,
            apiKey: apiKey,
            posterSize: MediaTooltipChrome<EmptyView>.posterSize(for: item.source),
            blurred: configStore.shouldBlurPoster(for: item.source),
            fallbackSymbol: item.source.symbol,
            // Corner grammar: [context: client][status: Upgrade/New].
            contextChip: item.downloadClient.map { AnyView(DownloadClientLabel(name: $0, size: 10)) },
            statusChip: AnyView(MediaBadgeCluster(isUpgrade: item.isUpgrade, size: .medium))
        ) {
            tooltipContent
        }
    }

    @ViewBuilder
    private var tooltipContent: some View {
        // Experiment: upgrades now use the extracted side-by-side
        // `UpgradeDiffView` (current file → incoming, with gained/lost
        // format chips) instead of the inline grid diff. The grid then
        // only carries the contextual extras the diff view doesn't cover
        // (indexer, release file name, replaced on-disk path).
        if item.isUpgrade {
            UpgradeDiffView(item: item, showFilenames: true)
        }
        TooltipInfoGrid(lines: infoLines)

        // For non-upgrades the side-by-side doesn't apply, so keep the
        // plain custom-format chip strip. Upgrades get their gained/lost
        // chips from `UpgradeDiffView` above.
        if !item.isUpgrade, !item.customFormats.isEmpty || item.customFormatScore != 0 {
            customFormatChipStrip(
                tags: item.customFormats,
                score: item.customFormatScore != 0 ? item.customFormatScore : nil
            )
        }
        // Only for non-upgrades: upgrades render both filenames inside
        // `UpgradeDiffView`, so repeating one here doubled the comparison.
        if !item.isUpgrade {
            TooltipFileName(name: item.releaseName)
        }
    }

    private var infoLines: [TooltipInfoLine] {
        var lines: [TooltipInfoLine] = []
        // Quality / Size only for non-upgrades — for upgrades the incoming
        // quality and size already live in `UpgradeDiffView` above. One
        // fact per row (the "q · size" splice was the odd one out).
        if !item.isUpgrade {
            if let q = item.quality, !q.isEmpty {
                lines.append(TooltipInfoLine(labelKey: "Quality", value: q))
            }
            lines.append(TooltipInfoLine(labelKey: "Size", value: sizeString))
        }
        if let indexer = item.indexer, !indexer.isEmpty {
            lines.append(TooltipInfoLine(labelKey: "Indexer", value: indexer))
        }
        return lines
    }

    private var sizeString: String {
        ByteCountFormatter.string(fromByteCount: item.sizeTotal, countStyle: .file)
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
        // Two rectangles carry the whole "how far along is this" story, so
        // there is literally nothing for VoiceOver to read. Name the bar and
        // publish the fill as its value — the one number that matters.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Download progress", bundle: .module))
        .accessibilityValue(Text(max(0.0, min(1.0, progress)), format: .percent.precision(.fractionLength(0))))
    }
}

// `CustomFormatStrip` lives in `Chips.swift` now.
