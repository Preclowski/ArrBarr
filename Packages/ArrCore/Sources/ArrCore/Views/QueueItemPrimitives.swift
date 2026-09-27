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

    public init(isUpgrade: Bool) {
        self.isUpgrade = isUpgrade
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

    public init(name: String) {
        self.name = name
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

/// The one place a custom-format score is turned into pixels.
///
/// ## The rule
///
/// **A bare number is always absolute — "this file scores N" — on every
/// surface.** Relative numbers ("N better than what you have") never
/// appear inline; they live only where a comparison is actually drawn,
/// with room to label both sides: the upgrade diff and the tooltips.
///
/// That is a deliberate narrowing. The same signed green number used to
/// mean the file's own score in the release list and the *change against
/// the file on disk* in a queue group row — identical pixels, opposite
/// meaning, and nothing on screen to tell them apart. Rendering both
/// ("+465 (+125)") would disambiguate but does not fit a 400 pt popover's
/// right gutter, so the ambiguous case is removed instead of marked.
///
/// ## Colour
///
/// One rule: **colour answers the most useful question the surface can
/// answer.**
///
/// - Where a `baseline` is known — the file this one would replace, or
///   the on-disk file pinned above a manual-search list — colour is the
///   **comparison**: green means "better than what you have", red means
///   worse, neutral means level. A release scoring +120 next to a +465
///   file on disk is a downgrade and must not read as a win just because
///   its own number is positive.
/// - Where there is no baseline, colour falls back to the **sign of the
///   value**, which is the only thing left to say.
///
/// The number itself never changes: absolute either way.
public struct ScoreLabel: View {
    let score: Int
    /// Score of the file this one is measured against, when there is one.
    /// `nil` = nothing to compare with, so colour goes by sign.
    let baseline: Int?
    var size: CGFloat
    var weight: Font.Weight

    public init(score: Int, baseline: Int? = nil, size: CGFloat = 10, weight: Font.Weight = .medium) {
        self.score = score
        self.baseline = baseline
        self.size = size
        self.weight = weight
    }

    /// Green / red / neutral for this label, per the rule above.
    private var tint: Color {
        guard let baseline else { return Self.color(score) }
        return Self.deltaColor(score - baseline)
    }

    public var body: some View {
        if score != 0 {
            Text(verbatim: Self.text(score))
                .scaledFont(size: size, weight: weight, monospacedDigit: true)
                .foregroundStyle(tint)
                .accessibilityLabel(Text("common.customFormatScore.button", bundle: .module))
                .accessibilityValue(Text(verbatim: Self.text(score)))
        }
    }

    // MARK: - Shared formatting
    //
    // Table and grid cells lay their own text out (aligned columns, fixed
    // label widths) but must not invent their own signs or colours. They
    // call these instead, so "what does green mean here" has exactly one
    // answer per context.

    /// Signed absolute score. Rendered verbatim so a locale's grouping
    /// separator can't sneak into a four-digit score.
    public static func text(_ score: Int) -> String {
        "\(score > 0 ? "+" : "")\(score)"
    }

    /// Colour for an absolute score — the sign of the value.
    public static func color(_ score: Int) -> Color {
        score > 0 ? .green : (score < 0 ? .red : .secondary)
    }

    /// Signed change. `±0` rather than `0` so a wash reads as "compared,
    /// no movement" instead of "score is zero".
    public static func deltaText(_ delta: Int) -> String {
        delta == 0 ? "±0" : "\(delta > 0 ? "+" : "")\(delta)"
    }

    /// Colour for a change — the DIRECTION, not the sign of either side.
    /// A file scoring −200 that replaces one scoring −500 is a gain and
    /// reads green, even though both numbers are negative. The old code
    /// painted every delta green unconditionally, so a losing upgrade
    /// announced itself as a win.
    public static func deltaColor(_ delta: Int) -> Color {
        delta > 0 ? .green : (delta < 0 ? .red : .secondary)
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

    /// A stalled/rejected download can carry a wall of `statusMessages`
    /// (import-rejection reasons, tracker errors) that otherwise swamps the
    /// detail view. Collapse to a few lines by default with a Show more / Show
    /// less toggle; the height probe below only surfaces the toggle when the
    /// warning genuinely overflows, so short warnings stay button-free.
    @State private var expanded = false
    @State private var clampedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    private let collapsedLineLimit = 3

    public init(messages: [String], tint: Color, actionURL: URL? = nil) {
        self.messages = messages
        self.tint = tint
        self.actionURL = actionURL
    }

    /// Join into one block so `lineLimit` clamps the whole warning rather than
    /// each message line independently.
    private var text: String { messages.joined(separator: "\n") }

    /// True when the collapsed render is shorter than the full render — i.e.
    /// there's genuinely more to reveal. Measured from fixed hidden probes (not
    /// the visible text), so it stays valid while expanded and "Show less"
    /// doesn't vanish. +0.5 slop for sub-pixel text-layout rounding.
    private var isTruncated: Bool { fullHeight > clampedHeight + 0.5 }

    /// Same rule as `ExpandableOverview`: the disclosure only pays for itself
    /// when it hides more than ~1.5 lines. Line height is derived from the
    /// measured collapsed render so the threshold tracks font scaling.
    private var hiddenOverflowIsWorthAButton: Bool {
        guard clampedHeight > 0 else { return true }
        let lineHeight = clampedHeight / CGFloat(collapsedLineLimit)
        return fullHeight - clampedHeight > lineHeight * 1.5
    }

    private var showsFullText: Bool {
        expanded || (isTruncated && !hiddenOverflowIsWorthAButton)
    }

    public var body: some View {
        // Warning icon dropped: the status pill rendered immediately
        // above already carries the triangle — repeating it here was
        // visual stutter. The tinted backdrop alone carries the
        // "this is the warning explanation" signal.
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .scaledFont(size: 11)
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .lineLimit(showsFullText ? nil : collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) { heightProbes }

            if isTruncated && hiddenOverflowIsWorthAButton {
                Button {
                    withAnimation(.smooth(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text(expanded ? "discover.showLess.button" : "queue.showMore.button", bundle: .module)
                            .scaledFont(size: 11, weight: .medium)
                        // Disclosure glyph — the button's own text already
                        // says which way it goes.
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .scaledFont(size: 9, weight: .semibold)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(tint)
                }
                .buttonStyle(.plain)
            }

            if let actionURL {
                Button {
                    PlatformURLOpener.open(actionURL)
                } label: {
                    HStack(spacing: 4) {
                        Text("detail.openInBrowser.button", bundle: .module)
                        Image(systemName: "arrow.up.right.square")
                            .scaledFont(size: 10, weight: .medium)
                            .accessibilityHidden(true)
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

    /// Two hidden, non-interactive measuring sticks at the banner's real width:
    /// one clamped to `collapsedLineLimit`, one unlimited. Their height gap is
    /// what tells us the warning overflows the collapsed view — a layout probe,
    /// not a brittle character-count guess.
    private var heightProbes: some View {
        ZStack(alignment: .topLeading) {
            probe(lineLimit: collapsedLineLimit)
                .background(GeometryReader { g in
                    Color.clear.preference(key: BannerClampedHeightKey.self, value: g.size.height)
                })
            probe(lineLimit: nil)
                .background(GeometryReader { g in
                    Color.clear.preference(key: BannerFullHeightKey.self, value: g.size.height)
                })
        }
        .onPreferenceChange(BannerClampedHeightKey.self) { clampedHeight = $0 }
        .onPreferenceChange(BannerFullHeightKey.self) { fullHeight = $0 }
    }

    private func probe(lineLimit: Int?) -> some View {
        Text(text)
            .scaledFont(size: 11)
            .lineSpacing(2)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct BannerClampedHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct BannerFullHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: -

/// Reusable tooltip chrome for media items (search results,
/// upcoming items, etc.). Renders the canonical
/// `poster | (title · subtitle · divider · custom-content · overview)`
/// shape so every "preview-on-hover" surface in the app reads the
/// same. Callers slot whatever metadata-specific content fits in
/// the middle (rating chips, info grid, …) via `@ViewBuilder`.
///
/// Every rich tooltip goes through this chrome now (queue rows, season
/// packs, library tiles, search results, upcoming rows) — one 480 pt
/// footprint, one poster size, one header style. The lone hold-out is
/// `CastTooltip` (a fixed-size person card with async fill), which shares
/// no anatomy with media tooltips.
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
    let frameWidth: CGFloat
    /// The title-row corner takes AT MOST two chips, typed so a third
    /// can't sneak in and squeeze the title: `contextChip` (who/where —
    /// download client, release status) then `statusChip` (ownership /
    /// download state — Pobrane, Upgrade/New). No loose text here ever;
    /// counts and other facts belong in the info grid.
    let contextChip: AnyView?
    let statusChip: AnyView?
    @ViewBuilder let content: () -> Content

    /// The canonical tooltip poster: 2:3, or square for Lidarr covers.
    public static func posterSize(for source: QueueItem.Source) -> CGSize {
        source == .lidarr ? CGSize(width: 110, height: 110) : CGSize(width: 110, height: 165)
    }

    public init(
        title: String,
        year: Int? = nil,
        subtitle: String? = nil,
        posterURL: URL?,
        posterRequiresAuth: Bool = false,
        apiKey: String? = nil,
        posterSize: CGSize = CGSize(width: 110, height: 165),
        blurred: Bool = false,
        fallbackSymbol: String = "photo",
        frameWidth: CGFloat = 480,
        contextChip: AnyView? = nil,
        statusChip: AnyView? = nil,
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
        self.frameWidth = frameWidth
        self.contextChip = contextChip
        self.statusChip = statusChip
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
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(titleWithYear)
                            .scaledFont(size: 13, weight: .semibold)
                            .lineLimit(2)
                        if contextChip != nil || statusChip != nil {
                            Spacer(minLength: 4)
                            HStack(spacing: 4) {
                                if let contextChip { contextChip }
                                if let statusChip { statusChip }
                            }
                        }
                    }
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
                // Synopsis placement is the caller's job (TooltipOverview,
                // directly under its info grid) — appending it here put it
                // below the chips/filename on file-bearing tooltips.
                content()
            }
        }
        .padding(12)
        .frame(width: frameWidth)
    }

    private var titleWithYear: String {
        if let year { return "\(title) (\(year))" }
        return title
    }

}

// MARK: -

/// Tinted status word in a tinted-outline chip, wearing `status.tint`
/// so the row picks up its semantic colour (blue for Downloading,
/// orange for Paused, green for Completed, etc.). Lives at the leading
/// edge of the status line on every surface.
public struct StatusIconLabel: View {
    let status: QueueItem.Status
    var labelSize: CGFloat
    var labelWeight: Font.Weight

    public init(status: QueueItem.Status,
                labelSize: CGFloat = 9,
                labelWeight: Font.Weight = .medium) {
        self.status = status
        self.labelSize = labelSize
        self.labelWeight = labelWeight
    }

    public var body: some View {
        // Badge-styled to match TagChip / MediaBadgeCluster. Single visual
        // idiom across "status pill", "upgrade chip", "custom format" so the
        // status row reads as one cohesive strip of chips instead of
        // free-floating text next to bordered pills.
        Text(LocalizedStringKey(status.displayName))
            .scaledFont(size: labelSize, weight: labelWeight)
            .foregroundStyle(status.tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                    .stroke(status.tint.opacity(0.30), lineWidth: 0.75)
            )
        .fixedSize()
    }
}
