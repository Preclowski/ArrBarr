import SwiftUI

// MARK: - Queue-item primitives
//
// Tiny presentational atoms reused across every surface that renders a
// queue item (compact row, season-pack group row, hover tooltip,
// detail-view download section, multi-item list inside a detail
// section). Each one was repeated verbatim 4-6× across those files
// before this extraction; consolidating here keeps the shared visual
// language in lockstep — bump the score colour rule once and every
// row picks it up.
//
// Composition is still inline in each surface: that's the on-purpose
// limit of this pass. We're sharing leaves, not the tree.

/// Single capsule badge: either `New` (fresh download, no existing
/// file) or `Upgrade` (replacing an existing library file). The two
/// states are mutually exclusive — every queue entry is one or the
/// other, never both, since "Upgrade" by definition already implies
/// the file isn't new to the library.
public struct MediaBadgeCluster: View {
    let isUpgrade: Bool
    var size: Size

    public enum Size {
        /// Compact row cells — 8pt font, 4pt horizontal padding,
        /// tinted capsule background. Default for queue rows.
        case compact
        /// Tooltip header / detail title — 9-10pt font, 5-6pt padding,
        /// tinted capsule.
        case medium
        /// Quietest variant — uppercase tracked label, no background.
        /// For surfaces that already carry a lot of colour (e.g. the
        /// season episode list, where the row already paints the
        /// status tint across the background) and would read as noisy
        /// with another tinted capsule on top.
        case subtle
    }

    public init(isUpgrade: Bool, size: Size = .compact) {
        self.isUpgrade = isUpgrade
        self.size = size
    }

    public var body: some View {
        badge(
            labelKey: isUpgrade ? "Upgrade" : "New",
            color: isUpgrade ? .indigo : .accentColor
        )
    }

    @ViewBuilder
    private func badge(labelKey: String, color: Color) -> some View {
        if size == .subtle {
            // Background-free, uppercase + tracked, neutral `.secondary`
            // foreground — same vocabulary as the section headers
            // (`EPISODES`, `SEASON 0X`) in the tooltip. The row this
            // sits on already paints the status tint behind everything,
            // so a coloured label here was a second voice fighting for
            // attention. The literal text ("Upgrade" vs "New") carries
            // the semantic distinction; the chip styling is just the
            // genre of the label.
            Text(LocalizedStringKey(labelKey), bundle: .module)
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
        } else {
            Text(LocalizedStringKey(labelKey), bundle: .module)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, hPad)
                .padding(.vertical, vPad)
                .background(color.opacity(0.15), in: Capsule())
        }
    }

    private var fontSize: CGFloat { size == .compact ? 8 : 9 }
    private var hPad: CGFloat { size == .compact ? 4 : 5 }
    private var vPad: CGFloat { size == .compact ? 1 : 1 }
}

// MARK: -

/// Neutral download-client label — `.tertiary` text on the trailing
/// edge of the title / details row. Used to be a bright per-client
/// coloured capsule (orange for SABnzbd, blue for qBit…) which
/// collided with the status tint (Paused is orange too) — the
/// neutralised treatment lives here so every surface picks up the
/// fix.
public struct DownloadClientLabel: View {
    let name: String
    var size: CGFloat

    public init(name: String, size: CGFloat = 9) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        Text(name)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: -

/// Inline `+XXXX` / `-XXXX` score in green / red. Renders nothing
/// when `score == 0`. The status-line / details-line right gutter
/// across every surface pipes the item's `customFormatScore` (or the
/// existing file's) through this view.
public struct ScoreLabel: View {
    let score: Int
    var size: CGFloat
    var weight: Font.Weight

    public init(score: Int, size: CGFloat = 10, weight: Font.Weight = .semibold) {
        self.score = score
        self.size = size
        self.weight = weight
    }

    public var body: some View {
        if score != 0 {
            let sign = score > 0 ? "+" : ""
            Text("\(sign)\(score)")
                .font(.system(size: size, weight: weight))
                .foregroundStyle(score > 0 ? Color.green : Color.red)
        }
    }
}

// MARK: -

/// Tree-branch diff line for the existing (replaced) file's metadata.
/// Rendered as a sub-row beneath the new file's Quality line — uses
/// the `└─` box-drawing glyph to read as a child of the line above.
/// Includes an optional inline score delta (`(+50)` / `(-5)`) so the
/// user sees whether this upgrade actually gains points.
///
/// Used in the tooltip's `infoGrid` and in the detail view's
/// `DownloadSection`, so the same data shape reads the same way
/// whichever surface the user happens to be looking at.
/// Inline banner that surfaces the arr's own `statusMessages` payload
/// when a queue item carries warnings. Tinted with the item's status
/// colour (red for failed, orange for warning) so the banner reads as
/// "the explanation for that red pill above" rather than a generic
/// notice. Sits under `ProgressLine` in the detail view.
public struct QueueStatusMessagesBanner: View {
    let messages: [String]
    let tint: Color

    public init(messages: [String], tint: Color) {
        self.messages = messages
        self.tint = tint
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(messages, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(tint.opacity(0.25), lineWidth: 0.5)
        )
    }
}

public struct ExistingFileDiffRow: View {
    let existingQuality: String?
    let existingSize: Int64?
    let existingScore: Int?
    /// Current/new score — used to compute the delta. Pass the
    /// incoming file's `customFormatScore`. The view shows `(±N)` only
    /// when both scores are present AND differ.
    let newScore: Int

    public init(existingQuality: String?,
                existingSize: Int64?,
                existingScore: Int?,
                newScore: Int) {
        self.existingQuality = existingQuality
        self.existingSize = existingSize
        self.existingScore = existingScore
        self.newScore = newScore
    }

    public var body: some View {
        HStack(spacing: 4) {
            // `└─` reads as a tree-branch child of the row above —
            // visual nesting without an indigo "replaces" arrow that
            // was over-stating the importance of this line.
            Text(verbatim: "└─")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            if let q = existingQuality, !q.isEmpty {
                Text(q)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let size = existingSize, size > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let s = existingScore, s != 0 {
                Text("·").foregroundStyle(.tertiary)
                ScoreLabel(score: s, size: 11, weight: .regular)
            }
            if let existing = existingScore, existing != newScore {
                let delta = newScore - existing
                let sign = delta > 0 ? "+" : ""
                Text("(\(sign)\(delta))")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(delta > 0 ? Color.green : Color.red)
            }
        }
    }
}

// MARK: -

/// Chip-diff between new and existing custom-format sets. Renders
/// added chips with a green `+` prefix, removed chips with a red `−`.
/// Renders nothing when the sets are identical — the common case for
/// repacks / resolution bumps where the release group keeps the same
/// CF tags, so showing two identical chip strips was the visual
/// confusion this diff was built to eliminate.
public struct CustomFormatDiff: View {
    let newFormats: [String]
    let existingFormats: [String]

    public init(newFormats: [String], existingFormats: [String]) {
        self.newFormats = newFormats
        self.existingFormats = existingFormats
    }

    public var body: some View {
        let oldSet = Set(existingFormats)
        let newSet = Set(newFormats)
        let added = newFormats.filter { !oldSet.contains($0) }
        let removed = existingFormats.filter { !newSet.contains($0) }

        if !added.isEmpty || !removed.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if !added.isEmpty {
                    HStack(spacing: 4) {
                        Text(verbatim: "+")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                        TooltipFlowLayout(spacing: 3) {
                            ForEach(added, id: \.self) { TagChip(text: $0, color: .green) }
                        }
                    }
                }
                if !removed.isEmpty {
                    HStack(spacing: 4) {
                        Text(verbatim: "−")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                        TooltipFlowLayout(spacing: 3) {
                            ForEach(removed, id: \.self) { TagChip(text: $0, color: .red) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: -

/// Fast hover tooltip — fires after ~350 ms hover, renders via
/// `.popover` so the label floats free of parent clipping (our
/// earlier `.overlay`-based draft got eaten by the gradient backdrop
/// on row hover-overlays). Heavier chrome than a raw label but
/// guaranteed visible.
public struct ActionHoverTip: ViewModifier {
    let text: LocalizedStringKey
    @State private var show = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering = false

    public func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onHover { hovering in
                isHovering = hovering
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        if !Task.isCancelled, isHovering { show = true }
                    }
                } else {
                    show = false
                }
            }
            .popover(isPresented: $show, arrowEdge: .bottom) {
                Text(text, bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .fixedSize()
                    .popoverBehavior(.applicationDefined)
            }
        #else
        content
        #endif
    }
}

public extension View {
    /// Quick hover tooltip — fires faster than the native `.help()`
    /// (~350 ms vs ~1 s) and is guaranteed visible (NSPopover, not
    /// a clipped overlay).
    func actionHoverTip(_ text: LocalizedStringKey) -> some View {
        modifier(ActionHoverTip(text: text))
    }
}

// MARK: -

/// Reusable tooltip chrome for media items (search results,
/// upcoming items, etc.). Renders the canonical
/// `poster | (title · subtitle · divider · custom-content · overview)`
/// shape so every "preview-on-hover" surface in the app reads the
/// same. Callers slot whatever metadata-specific content fits in
/// the middle (rating chips, info grid, …) via `@ViewBuilder`.
///
/// Not used by `QueueItemTooltip` — that one has its own infoGrid +
/// inline upgrade diff + CF strip + chip diff stack which is too
/// idiosyncratic to fit a generic chrome. The two simpler tooltips
/// (search results + upcoming items) share this base.
public struct MediaTooltipChrome<Content: View>: View {
    let title: String
    let year: Int?
    let subtitle: String?
    let posterURL: URL?
    let posterRequiresAuth: Bool
    let apiKey: String?
    let posterSize: CGSize
    let blurred: Bool
    let fallbackSymbol: String
    let overview: String?
    let frameWidth: CGFloat
    @ViewBuilder let content: () -> Content

    public init(
        title: String,
        year: Int? = nil,
        subtitle: String? = nil,
        posterURL: URL?,
        posterRequiresAuth: Bool = false,
        apiKey: String? = nil,
        posterSize: CGSize = CGSize(width: 90, height: 135),
        blurred: Bool = false,
        fallbackSymbol: String = "photo",
        overview: String? = nil,
        frameWidth: CGFloat = 420,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.year = year
        self.subtitle = subtitle
        self.posterURL = posterURL
        self.posterRequiresAuth = posterRequiresAuth
        self.apiKey = apiKey
        self.posterSize = posterSize
        self.blurred = blurred
        self.fallbackSymbol = fallbackSymbol
        self.overview = overview
        self.frameWidth = frameWidth
        self.content = content
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterBlurContainer(blurred: blurred, cornerRadius: 6) {
                RemotePoster(
                    url: posterURL,
                    apiKey: posterRequiresAuth ? apiKey : nil,
                    size: posterSize,
                    cornerRadius: 6,
                    fallbackSymbol: fallbackSymbol
                )
            }
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(titleWithYear)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    if let sub = subtitle, !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                let custom = content()
                if shouldShowDivider {
                    Divider().opacity(0.5)
                }
                custom
                if let overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                        .padding(.top, 2)
                }
            }
        }
        .padding(12)
        .frame(width: frameWidth)
    }

    private var titleWithYear: String {
        if let year { return "\(title) (\(year))" }
        return title
    }

    /// Show the divider only when the content slot has something to
    /// separate from the header. EmptyView in the slot → no divider
    /// (avoids floating horizontal line under a bare title).
    private var shouldShowDivider: Bool {
        Content.self != EmptyView.self
    }
}

// MARK: -

/// Status symbol + tinted display name, both wearing the same
/// `status.tint` so the row picks up its semantic colour (blue for
/// Downloading, orange for Paused, green for Completed, etc.). Lives
/// at the leading edge of the status line on every surface.
public struct StatusIconLabel: View {
    let status: QueueItem.Status
    var iconSize: CGFloat
    var labelSize: CGFloat
    var labelWeight: Font.Weight

    public init(status: QueueItem.Status,
                iconSize: CGFloat = 8,
                labelSize: CGFloat = 10,
                labelWeight: Font.Weight = .regular) {
        self.status = status
        self.iconSize = iconSize
        self.labelSize = labelSize
        self.labelWeight = labelWeight
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: status.symbol)
                .font(.system(size: iconSize))
                .foregroundStyle(status.tint)
            Text(LocalizedStringKey(status.displayName))
                .font(.system(size: labelSize, weight: labelWeight))
                .foregroundStyle(status.tint)
        }
    }
}
