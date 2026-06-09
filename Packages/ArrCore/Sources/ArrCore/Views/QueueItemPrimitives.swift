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
        // Match TagChip's chrome exactly (9pt medium, 5/1 padding, 30%
        // stroke) so Upgrade / New chips and custom-format chips align
        // pixel-for-pixel when they sit in the same row — no jarring
        // "this one is taller" mismatch.
        TagChip(
            text: NSLocalizedString(isUpgrade ? "Upgrade" : "New",
                                    bundle: .module, comment: ""),
            color: isUpgrade ? .indigo : .accentColor
        )
    }
}

// MARK: -

/// Download-client label — outline capsule matching `MediaBadgeCluster`
/// and any other compact label across the app. Neutral secondary tint
/// so it reads as metadata, not as a status indicator.
public struct DownloadClientLabel: View {
    let name: String
    var size: CGFloat

    public init(name: String, size: CGFloat = 9) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        OutlineLabel(text: name, tint: .secondary, fontSize: 8)
    }
}

/// Shared outline-capsule label primitive — tinted border, no fill,
/// tinted text. Used by `MediaBadgeCluster`, `DownloadClientLabel`,
/// and any other compact metadata chip. One look across every
/// surface; per-callsite tint conveys semantic distinction.
public struct OutlineLabel: View {
    let text: String
    let tint: Color
    var fontSize: CGFloat

    public init(text: String, tint: Color, fontSize: CGFloat = 8) {
        self.text = text
        self.tint = tint
        self.fontSize = fontSize
    }

    public var body: some View {
        Text(text)
            .scaledFont(size: fontSize, weight: .semibold)
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.chip).stroke(tint.opacity(0.32), lineWidth: 0.75)
            )
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
    /// When non-nil, the view renders `score − existing` as a signed
    /// delta (green for gains, red for losses, neutral `±0` for a wash).
    /// `nil` keeps the legacy raw-score rendering used by surfaces that
    /// just want to show the file's own score with no upgrade context.
    let existing: Int?
    var size: CGFloat
    var weight: Font.Weight

    public init(score: Int, size: CGFloat = 10, weight: Font.Weight = .semibold) {
        self.score = score
        self.existing = nil
        self.size = size
        self.weight = weight
    }

    /// Diff-mode initializer — `new` is the incoming file's score,
    /// `from` the existing file's score it's replacing. Used for queue /
    /// upgrade rows where the actionable info is "are we gaining or
    /// losing points?" rather than the absolute number. Falls back to a
    /// raw `new` render when `from == nil` (fresh download — no
    /// replacement target to diff against).
    public init(delta new: Int, from existing: Int?, size: CGFloat = 10, weight: Font.Weight = .semibold) {
        self.score = new
        self.existing = existing
        self.size = size
        self.weight = weight
    }

    public var body: some View {
        if let existing {
            // Diff mode renders absolute + delta — "+465 (+125)" reads as
            // "score is 465, up by 125" in one glance. The delta is
            // what's tinted (green / red / neutral) since gain-or-loss
            // is the actionable signal; the absolute score sits in
            // primary so it's still legible at a distance.
            // Absolute score takes the gain/loss tint (it's the headline
            // number — green for "this download has positive score",
            // red for negative). The delta sits in a desaturated mint
            // alongside — present but secondary, since the absolute
            // already encodes the direction via the sign on the number
            // itself.
            let delta = score - existing
            let scoreSign = score > 0 ? "+" : ""
            let deltaSign = delta > 0 ? "+" : (delta == 0 ? "±" : "")
            let scoreColor: Color = score > 0 ? .green : (score < 0 ? .red : .secondary)
            HStack(spacing: 3) {
                Text(verbatim: "\(scoreSign)\(score)")
                    .foregroundStyle(scoreColor)
                Text(verbatim: "(\(deltaSign)\(delta))")
                    .foregroundStyle(Color.green.opacity(0.55))
            }
            .scaledFont(size: size, weight: weight, monospacedDigit: true)
        } else if score != 0 {
            let sign = score > 0 ? "+" : ""
            Text(verbatim: "\(sign)\(score)")
                .scaledFont(size: size, weight: weight)
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
    /// Optional arr-side URL to surface as a trailing CTA. When set,
    /// the banner adds an "Open in browser" link/button — these
    /// messages are usually actionable only inside Sonarr/Radarr's
    /// own UI (manual import, blocklist, edit grab), so the CTA gets
    /// the user there in one click instead of forcing them to
    /// re-navigate from the popover's header.
    let actionURL: URL?

    public init(messages: [String], tint: Color, actionURL: URL? = nil) {
        self.messages = messages
        self.tint = tint
        self.actionURL = actionURL
    }

    public var body: some View {
        // Warning icon dropped: the status pill rendered immediately
        // above already carries the triangle — repeating it here was
        // visual stutter. The tinted backdrop alone carries the
        // "this is the warning explanation" signal.
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(messages, id: \.self) { line in
                    Text(line)
                        .scaledFont(size: 11)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let actionURL {
                Button {
                    PlatformURLOpener.open(actionURL)
                } label: {
                    HStack(spacing: 4) {
                        Text("detail.openInBrowser.button", bundle: .module)
                        Image(systemName: "arrow.up.right.square")
                            .scaledFont(size: 10, weight: .medium)
                    }
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(tint)
                }
                .buttonStyle(.plain)
                .help(Text("detail.openInBrowser.button", bundle: .module))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.card)
                .stroke(tint.opacity(0.25), lineWidth: 0.5)
        )
    }
}

/// "Replacing <existing spec>" line — Apple Software Update pattern.
/// Per-dimension suppression: only renders tokens that *differ* from
/// the incoming file. Identical quality/size/score collapse to
/// silence; if everything's identical, the whole line falls back to
/// a single muted "Same spec, retagged" / "Re-downloading identical
/// release" message. The principle: equality is silence.
/// Wraps a NEW/OLD diff section in a labeled column — small uppercase
/// caption above the content, a vertical tint-coloured rail down the
/// left side, and dimmed-secondary content treatment. Used on the
/// EXISTING half of upgrade diffs so the user can tell which side is
/// the file being replaced at a glance.
public struct DiffSection<Content: View>: View {
    let captionKey: LocalizedStringKey
    let tint: Color
    let content: () -> Content

    public init(captionKey: LocalizedStringKey, tint: Color = .orange, @ViewBuilder content: @escaping () -> Content) {
        self.captionKey = captionKey
        self.tint = tint
        self.content = content
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule()
                .fill(tint.opacity(0.55))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(captionKey, bundle: .module)
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(tint.opacity(0.85))
                    .tracking(0.6)
                content()
            }
        }
    }
}

public struct ExistingFileDiffRow: View {
    let existingQuality: String?
    let existingSize: Int64?
    let existingScore: Int?
    /// Incoming file's score — used to compute the delta and to
    /// decide whether existing score is worth showing.
    let newScore: Int
    /// Optional incoming-side dimensions for equality comparison.
    /// When nil, suppression isn't applied — caller is treating the
    /// row as a plain "OLD info" line without comparing to NEW.
    let newQuality: String?
    let newSize: Int64?
    /// True when tag sets differ between new and existing — flips
    /// the "all-identical" fallback from "re-downloading identical"
    /// to "same spec, retagged".
    let tagsDiffer: Bool

    public init(existingQuality: String?,
                existingSize: Int64?,
                existingScore: Int?,
                newScore: Int,
                newQuality: String? = nil,
                newSize: Int64? = nil,
                tagsDiffer: Bool = false) {
        self.existingQuality = existingQuality
        self.existingSize = existingSize
        self.existingScore = existingScore
        self.newScore = newScore
        self.newQuality = newQuality
        self.newSize = newSize
        self.tagsDiffer = tagsDiffer
    }

    public var body: some View {
        HStack(spacing: 4) {
            // Left-aligned now — sits directly under the NEW spec
            // line in the card, reading as a vertical NEW→OLD column.
            // `arrow.turn.down.right` reads as "branching down from
            // the line above" → the OLD info is the source the NEW
            // line came from.
            Image(systemName: "arrow.turn.down.right")
                .scaledFont(size: 9, weight: .semibold)
                .foregroundStyle(.tertiary)
            content
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        let showQuality = shouldShow(existingQuality, newQuality)
        let showSize = shouldShowSize
        let showScore = shouldShowScore
        if !showQuality && !showSize && !showScore {
            // Everything matches — fall back to one muted phrase
            // instead of repeating identical values on both sides.
            Text(tagsDiffer
                    ? String(localized: "queue.sameSpecRetagged.button", bundle: .module)
                    : String(localized: "queue.reDownloadingIdenticalRelease.label", bundle: .module))
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                if showQuality, let q = existingQuality, !q.isEmpty {
                    Text(q)
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                if showSize, let size = existingSize, size > 0 {
                    if showQuality { SeparatorDot() }
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                if showScore {
                    if showQuality || showSize { SeparatorDot() }
                    if let s = existingScore, s != 0 {
                        ScoreLabel(score: s, size: 11, weight: .regular)
                    }
                    if let existing = existingScore, existing != newScore {
                        let delta = newScore - existing
                        let sign = delta > 0 ? "+" : ""
                        Text(verbatim: "(\(sign)\(delta))")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(delta > 0 ? Color.green : Color.red)
                    }
                }
            }
        }
    }

    private func shouldShow(_ existing: String?, _ new: String?) -> Bool {
        guard let existing, !existing.isEmpty else { return false }
        guard let new else { return true }   // no comparator → assume divergent
        return existing != new
    }

    /// 5% tolerance — torrent re-encodes often differ by <1% in size
    /// while being meaningfully different files. Same-quality re-grabs
    /// (the case this rule targets) cluster much tighter than 5%.
    private var shouldShowSize: Bool {
        guard let existing = existingSize, existing > 0 else { return false }
        guard let new = newSize, new > 0 else { return true }
        let ratio = Double(abs(existing - new)) / Double(max(existing, new))
        return ratio > 0.05
    }

    private var shouldShowScore: Bool {
        guard let existing = existingScore else { return false }
        return existing != newScore
    }
}

// MARK: -

/// Chip-diff between new and existing custom-format sets. Renders
/// added chips with a green `+` prefix, removed chips with a red `−`.
/// Renders the removed-formats row of a CF diff: items the existing
/// file has that the new release drops. The *added* side is encoded
/// directly into the upstream `CustomFormatChips` strip — green chips
/// in the new-spec row read as added without duplicating each tag
/// across a separate "+" line (the previous design painted the same
/// chip twice, which was the source of "if DV Boost was added why is
/// it also in the white list?" confusion).
///
/// Renders nothing when nothing was removed.
public struct CustomFormatDiff: View {
    let newFormats: [String]
    let existingFormats: [String]

    public init(newFormats: [String], existingFormats: [String]) {
        self.newFormats = newFormats
        self.existingFormats = existingFormats
    }

    public var body: some View {
        let newSet = Set(newFormats)
        let removed = existingFormats.filter { !newSet.contains($0) }

        if !removed.isEmpty {
            HStack(spacing: 4) {
                Text(verbatim: "−")
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(.red)
                TooltipFlowLayout(spacing: 3) {
                    ForEach(removed, id: \.self) { TagChip(text: $0, color: .red) }
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
                    .scaledFont(size: 11, weight: .medium)
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
            PosterBlurContainer(blurred: blurred, cornerRadius: Tokens.Radius.card) {
                RemotePoster(
                    url: posterURL,
                    apiKey: posterRequiresAuth ? apiKey : nil,
                    size: posterSize,
                    cornerRadius: Tokens.Radius.card,
                    fallbackSymbol: fallbackSymbol
                )
            }
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(titleWithYear)
                        .scaledFont(size: 13, weight: .semibold)
                        .lineLimit(2)
                    if let sub = subtitle, !sub.isEmpty {
                        Text(sub)
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                // Decorative divider between header and content
                // dropped — tooltip's typographic hierarchy (semibold
                // title vs. body text) already separates the two
                // visually, and an explicit hairline added noise.
                content()
                if let overview, !overview.isEmpty {
                    Text(overview)
                        .scaledFont(size: 11)
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
    /// When false, drop the tinted-outline chip chrome and render just the
    /// icon + text inline. Queue rows use this — the bordered "pill" read as
    /// a redundant label there; the icon + coloured word carry the status.
    var bordered: Bool

    public init(status: QueueItem.Status,
                iconSize: CGFloat = 9,
                labelSize: CGFloat = 9,
                labelWeight: Font.Weight = .medium,
                bordered: Bool = true) {
        self.status = status
        self.iconSize = iconSize
        self.labelSize = labelSize
        self.labelWeight = labelWeight
        self.bordered = bordered
    }

    public var body: some View {
        // Badge-styled to match TagChip / MediaBadgeCluster — icon +
        // text on a single tinted-outline chip. Single visual idiom
        // across "status pill", "upgrade chip", "custom format" so the
        // status row reads as one cohesive strip of chips instead of
        // free-floating text next to bordered pills.
        HStack(spacing: 3) {
            Image(systemName: status.symbol)
                .scaledFont(size: iconSize)
            Text(LocalizedStringKey(status.displayName))
                .scaledFont(size: labelSize, weight: labelWeight)
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, bordered ? 5 : 0)
        .padding(.vertical, bordered ? 1 : 0)
        .overlay(
            Group {
                if bordered {
                    RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                        .stroke(status.tint.opacity(0.30), lineWidth: 0.75)
                }
            }
        )
        .fixedSize()
    }
}
