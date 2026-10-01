import SwiftUI

// MARK: - Queue-item primitives

/// `New` (no existing file) or `Upgrade` (replaces a library file); never both.
struct MediaBadgeCluster: View {
    let isUpgrade: Bool

    init(isUpgrade: Bool) {
        self.isUpgrade = isUpgrade
    }

    var body: some View {
        // Same chrome as TagChip so these align pixel-for-pixel with custom-format chips.
        TagChip(
            text: NSLocalizedString(isUpgrade ? "Upgrade" : "New",
                                    bundle: .module, comment: ""),
            color: isUpgrade ? .indigo : .accentColor
        )
    }
}

// MARK: -

struct DownloadClientLabel: View {
    let name: String

    init(name: String) {
        self.name = name
    }

    var body: some View {
        OutlineLabel(text: name, tint: .secondary, fontSize: 8)
    }
}

/// Outline capsule: tinted border and text, no fill.
struct OutlineLabel: View {
    let text: String
    let tint: Color
    var fontSize: CGFloat

    init(text: String, tint: Color, fontSize: CGFloat = 8) {
        self.text = text
        self.tint = tint
        self.fontSize = fontSize
    }

    var body: some View {
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

/// The one place a custom-format score is turned into pixels. The number is always
/// absolute; relative numbers appear only where a comparison is drawn and labelled.
/// Colour compares against `baseline` when known (a +120 next to a +465 file on disk
/// is a downgrade), else goes by sign.
struct ScoreLabel: View {
    let score: Int
    /// `nil` = nothing to compare with, so colour goes by sign.
    let baseline: Int?
    var size: CGFloat
    var weight: Font.Weight

    init(score: Int, baseline: Int? = nil, size: CGFloat = 10, weight: Font.Weight = .medium) {
        self.score = score
        self.baseline = baseline
        self.size = size
        self.weight = weight
    }

    private var tint: Color {
        guard let baseline else { return Self.color(score) }
        return Self.deltaColor(score - baseline)
    }

    var body: some View {
        if score != 0 {
            Text(verbatim: Self.text(score))
                .scaledFont(size: size, weight: weight, monospacedDigit: true)
                .foregroundStyle(tint)
                .accessibilityLabel(Text("common.customFormatScore.button", bundle: .module))
                .accessibilityValue(Text(verbatim: Self.text(score)))
        }
    }

    // MARK: - Shared formatting
    // Table and grid cells lay out their own text but take signs and colours from here.

    /// Rendered verbatim so a locale's grouping separator can't sneak into a score.
    nonisolated static func text(_ score: Int) -> String {
        "\(score > 0 ? "+" : "")\(score)"
    }

    nonisolated static func color(_ score: Int) -> Color {
        score > 0 ? .green : (score < 0 ? .red : .secondary)
    }

    /// `±0` rather than `0` so a wash reads as "compared, no movement".
    nonisolated static func deltaText(_ delta: Int) -> String {
        delta == 0 ? "±0" : "\(delta > 0 ? "+" : "")\(delta)"
    }

    /// By direction, not sign: −200 replacing −500 is a gain and reads green.
    nonisolated static func deltaColor(_ delta: Int) -> Color {
        delta > 0 ? .green : (delta < 0 ? .red : .secondary)
    }
}

// MARK: -

/// The arr's own `statusMessages`, tinted with the item's status colour.
struct QueueStatusMessagesBanner: View {
    let messages: [String]
    let tint: Color
    /// These messages are usually actionable only in the arr's own UI, hence the CTA.
    let actionURL: URL?

    @State private var expanded = false
    @State private var clampedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    private let collapsedLineLimit = 3

    init(messages: [String], tint: Color, actionURL: URL? = nil) {
        self.messages = messages
        self.tint = tint
        self.actionURL = actionURL
    }

    /// One block so `lineLimit` clamps the whole warning, not each line.
    private var text: String { messages.joined(separator: "\n") }

    /// Measured from hidden probes, not the visible text, so "Show less" survives
    /// expanding. +0.5 slop for sub-pixel rounding.
    private var isTruncated: Bool { fullHeight > clampedHeight + 0.5 }

    /// Same rule as `ExpandableOverview`: disclose only when it hides more than ~1.5 lines.
    private var hiddenOverflowIsWorthAButton: Bool {
        guard clampedHeight > 0 else { return true }
        let lineHeight = clampedHeight / CGFloat(collapsedLineLimit)
        return fullHeight - clampedHeight > lineHeight * 1.5
    }

    private var showsFullText: Bool {
        expanded || (isTruncated && !hiddenOverflowIsWorthAButton)
    }

    var body: some View {
        // No warning icon: the status pill right above already carries the triangle.
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

    /// Collapsed vs unlimited hidden renders at the real width; their height gap
    /// is the overflow test.
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

/// Shared chrome for every rich tooltip except `CastTooltip`; callers slot
/// the metadata in the middle.
struct MediaTooltipChrome<Content: View>: View {
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
    /// At most two typed chips so a third can't squeeze the title; counts belong in the info grid.
    let contextChip: AnyView?
    let statusChip: AnyView?
    @ViewBuilder let content: () -> Content

    /// 2:3, or square for Lidarr covers.
    static func posterSize(for source: QueueItem.Source) -> CGSize {
        source == .lidarr ? CGSize(width: 110, height: 110) : CGSize(width: 110, height: 165)
    }

    init(
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

    var body: some View {
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
                // Synopsis is the caller's job: appended here it landed below the
                // chips on file-bearing tooltips.
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

struct StatusIconLabel: View {
    let status: QueueItem.Status
    var labelSize: CGFloat
    var labelWeight: Font.Weight

    init(status: QueueItem.Status,
                labelSize: CGFloat = 9,
                labelWeight: Font.Weight = .medium) {
        self.status = status
        self.labelSize = labelSize
        self.labelWeight = labelWeight
    }

    var body: some View {
        Text(verbatim: status.displayName)
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

/// The poster half of the delete animation: dims the artwork and pops a trash glyph.
struct PosterLeavingMark: ViewModifier {
    @Environment(\.queueRowLeaving) private var leaving

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                    .fill(.black.opacity(0.5))
                Image(systemName: "trash.fill")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(.white)
                    .scaleEffect(leaving ? 1 : 0.5)
            }
            .opacity(leaving ? 1 : 0)
            .allowsHitTesting(false)
        }
    }
}
