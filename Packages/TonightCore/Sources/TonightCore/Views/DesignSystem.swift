import SwiftUI
import ArrCore
import MediaKit
import AppKit

// The design-system base: the small set of shared controls every view builds
// from, so titles, ratings, scrims and paging controls look the same
// everywhere. New views should reach for these before inventing their own.

// MARK: - Layout constants

/// The lane the floating glass sidebar occupies. Full-bleed heros ignore
/// the leading safe area and pad their content by this to clear it.
let sidebarWidth: CGFloat = 210

/// How wide the sidebar's leading safe-area inset actually is right now —
/// measured once at the root, because the user can resize the column. Heros
/// ignore this inset to span the whole window; the copy under them pads by
/// it to stay out from behind the glass.
private struct SidebarLaneKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

public extension EnvironmentValues {
    var sidebarLane: CGFloat {
        get { self[SidebarLaneKey.self] }
        set { self[SidebarLaneKey.self] = newValue }
    }
}

/// Height of the window's traffic-light strip. Content that runs under a
/// floating back button starts below it, so nothing ever crowds the button.
let titleBarHeight: CGFloat = 44

/// Where a page's chrome starts. The floating back button, every header
/// strip and the filter inspector's header all sit in this one band, so the
/// back control is at the same height whether it floats over artwork or
/// rides in a strip — the credits list used to start a strip's height lower
/// than the person page it was pushed from.
let pageChromeTop: CGFloat = 14

// MARK: - Canonical artwork

@MainActor
public extension MediaItem {
    /// The poster to show: the one the user's media server holds, when it has
    /// this title and they haven't switched the preference off — otherwise
    /// TMDB's.
    ///
    /// One accessor rather than a decision at every call site: a grid that
    /// mixed the two sources would look like a bug, and the detail page
    /// showing a different poster than the card it was opened from reads as
    /// one too.
    var displayPosterURL: URL? {
        ExternalLibraryStore.shared.posterURL(for: self) ?? posterURL
    }

    /// Same rule for the big one. The server serves a single size, so this is
    /// the same file as the card's — which means the detail page paints from
    /// the cache instead of downloading again.
    var displayLargePosterURL: URL? {
        ExternalLibraryStore.shared.posterURL(for: self) ?? largePosterURL
    }

    /// The backdrop behind a hero: the user's own if their server has one.
    var displayBackdropURL: URL? {
        ExternalLibraryStore.shared.backdropURL(for: self) ?? backdropURL
    }

    /// The wide (16:9) card's picture, at card size — the server's backdrop
    /// when it has one, TMDB's `w780` otherwise.
    var displayCardBackdropURL: URL? {
        ExternalLibraryStore.shared.cardBackdropURL(for: self) ?? backdropCardURL
    }

    /// The title as its own marketing draws it, on transparency — nil for
    /// everything the media server doesn't hold, which is when a hero falls
    /// back to setting the title in type.
    var logoURL: URL? {
        ExternalLibraryStore.shared.logoURL(for: self)
    }
}

// MARK: - Canonical title

public extension MediaItem {
    /// The one way a title is written anywhere in the app: "Title (Year)".
    var displayTitle: String {
        year.map { "\(title) (\(String($0)))" } ?? title
    }
}

/// A title over artwork: the clear logo when the user's media server has one,
/// the words otherwise.
///
/// This is the single reason a hero reads as Apple TV rather than as a
/// screenshot with a caption — and it degrades to type without ceremony,
/// which matters because most of what the app browses is not in anybody's
/// library. Sized by HEIGHT, never stretched: a logo is a picture of a
/// wordmark and its aspect ratio is the design.
struct TitleMark: View {
    let item: MediaItem
    /// Cap for the logo. The typed fallback is not affected by it.
    var height: CGFloat
    var font: Font
    /// Used when the media server has no logo — TMDB ships one for most
    /// titles, and it is the same artwork the server's agents download.
    var fallbackLogo: URL? = nil
    /// True while the caller is still finding out whether there is a logo.
    /// The space is held empty until the answer is in: setting the title in
    /// type and swapping it for a picture a moment later is the one thing
    /// this control must never do.
    var pending = false

    var body: some View {
        if let logo = item.logoURL ?? fallbackLogo {
            RemoteImage(url: logo, contentMode: .fit, showsPlaceholder: false)
                .frame(maxWidth: 520, maxHeight: height, alignment: .leading)
                .accessibilityLabel(Text(item.displayTitle))
        } else if pending {
            Color.clear.frame(height: height)
        } else {
            Text(item.displayTitle)
                .font(font)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
        }
    }
}

// MARK: - Skeletons

/// The grey shape a piece of copy will occupy, pulsing gently while the real
/// thing is on its way.
///
/// A spinner says "something is happening somewhere"; this says "a paragraph
/// goes here, and it is nearly ready" — and because it has the shape and the
/// place of what replaces it, nothing jumps when the payload lands.
struct SkeletonBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = 13
    var radius: CGFloat = 5

    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.white.opacity(bright ? 0.16 : 0.07))
            .frame(width: width, height: height)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    bright = true
                }
            }
    }
}

// MARK: - Hero copy

/// The measurements of the copy block over a hero — the logo, the claim, the
/// facts and the scores. Home and a title page draw the same block in the
/// same place, so both read them from here rather than each tuning its own
/// paddings until they nearly match.
enum HeroCopy {
    /// Between the rows of the block.
    static let spacing: CGFloat = 10
    /// Air under the logo and under the claim: the two things that need to
    /// breathe before the small type starts.
    static let underLogo: CGFloat = 8
    static let underTagline: CGFloat = 4
    /// From the artwork's bottom edge, and from the window's side.
    static let bottom: CGFloat = 18
    static let inset: CGFloat = 28
    static let logoHeight: CGFloat = 108
    /// Rows that arrive late (the claim, the library marks) hold their height
    /// from the first frame. Without that the block grows under the logo and
    /// pushes it up the moment the payload lands — the jump this whole hero
    /// was built to avoid.
    static let taglineHeight: CGFloat = 24
    static let availabilityHeight: CGFloat = 24
    static let titleFont = Font.system(size: 40, weight: .bold)
    /// Height of the rows a title page carries under the scores — the
    /// library marks and the Trailer / Add to List / Watched controls. Home
    /// has none of them and holds the space instead, so the logo lands at the
    /// same height on both screens and paging into a title does not move it.
    /// Everything under the logo — claim, facts, scores, library marks and
    /// the controls — occupies this box whether or not it is full. It is the
    /// one number that keeps the logo at the same height on Home and on a
    /// title page, instead of each screen adding up its own rows.
    static let belowLogo: CGFloat = 196
}

/// The copy block over a hero: the logo, the claim under it, and a fixed box
/// holding whatever rows the page puts below them.
///
/// Home's marquee and a title page draw this same block, and used to draw it
/// twice — same `TitleMark`, same shadow, same skeleton, same paddings, in two
/// files. Sharing only the numbers (`HeroCopy`) was the worst of both: a
/// layout change needed two edits, and doing one of them still compiled and
/// still looked nearly right.
///
/// What the two screens genuinely disagree on stays out of here, in `rows`:
/// Home's facts are one inert joined line, a title page's are a list with
/// person links, buttons and library marks in it.
struct HeroCopyBlock<Rows: View>: View {
    let item: MediaItem
    /// Passed through to `TitleMark` — see its own doc for why `pending` is
    /// stated by the caller and never inferred from a missing logo.
    var fallbackLogo: URL? = nil
    var pending: Bool
    /// The claim, not the plot. Nothing is drawn for a loaded title that has
    /// none; the skeleton shows only while the payload is still out.
    var tagline: String?
    /// Home holds its claim to one line inside a fixed width; a title page is
    /// bounded by the poster beside it instead.
    var taglineMaxWidth: CGFloat? = nil
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: HeroCopy.spacing) {
            TitleMark(item: item, height: HeroCopy.logoHeight, font: HeroCopy.titleFont,
                      fallbackLogo: fallbackLogo, pending: pending)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
                .padding(.bottom, HeroCopy.underLogo)
            VStack(alignment: .leading, spacing: HeroCopy.spacing) {
                taglineBox
                rows
            }
            // Fixed, and it must stay fixed even now that one view draws it:
            // the box holds a different NUMBER of rows on the two screens, so
            // its height is what keeps the logo above it at one y — sized to
            // its content it would sit at two, and paging Home into a title
            // would move it.
            .frame(height: HeroCopy.belowLogo, alignment: .top)
        }
    }

    @ViewBuilder
    private var taglineBox: some View {
        Group {
            if let tagline, !tagline.isEmpty {
                Text(tagline)
                    .font(.title3.italic())
                    .opacity(0.85)
                    .lineLimit(taglineMaxWidth == nil ? nil : 1)
                    .frame(maxWidth: taglineMaxWidth, alignment: .leading)
            } else if pending {
                SkeletonBar(width: 320, height: 15)
            }
        }
        .frame(height: HeroCopy.taglineHeight, alignment: .leading)
        .padding(.bottom, HeroCopy.underTagline)
    }
}

// MARK: - The sidebar's lane

/// The lane's live value, published rather than passed by value.
///
/// `\.sidebarLane` is still how a view reads it, but what RootView puts in
/// the environment has to come from here: a `navigationDestination` closure
/// is built once and keeps whatever it captured then — zero, on the first
/// frame, before the split view has been laid out — so a pushed page read a
/// lane of zero for as long as it lived and drew its copy under the glass.
/// An `ObservableObject` re-renders the page when the real width lands.
@MainActor
final class SidebarLaneWidth: ObservableObject {
    static let shared = SidebarLaneWidth()
    @Published var width: CGFloat = 0
    private init() {}
}

/// The two sanctioned ways to read `\.sidebarLane`. Nothing else does
/// arithmetic on it: the lane used to be a bare number three call sites
/// interpreted differently — the hero copy added the inset, the chevrons did
/// not, the shelves did not — so "does this one add the inset?" had to be
/// answered by reading the neighbours.

/// Starts this content past the glass, for everything that is NOT hero copy:
/// the shelves and sections under a hero, and the leading paging chevron.
///
/// `enabled` is not decoration. A page only ignores the leading safe area
/// while it has a full-bleed hero to run under the glass; without one the
/// real safe area already holds the content clear, and adding the lane on top
/// would inset it twice.
private struct ClearOfSidebar: ViewModifier {
    @Environment(\.sidebarLane) private var lane
    let enabled: Bool

    func body(content: Content) -> some View {
        content.padding(.leading, enabled ? lane : 0)
    }
}

/// The insets of a copy block over a hero: clear of the glass, then the same
/// air from the window's side and bottom that the other hero uses.
private struct HeroCopyInsets: ViewModifier {
    @Environment(\.sidebarLane) private var lane

    func body(content: Content) -> some View {
        content
            .padding(.leading, lane + HeroCopy.inset)
            .padding(.trailing, HeroCopy.inset)
            .padding(.bottom, HeroCopy.bottom)
    }
}

extension View {
    /// See `ClearOfSidebar`. Pass `false` on a page with no full-bleed hero.
    func clearOfSidebar(_ enabled: Bool = true) -> some View {
        modifier(ClearOfSidebar(enabled: enabled))
    }

    /// See `HeroCopyInsets`.
    func heroCopyInsets() -> some View {
        modifier(HeroCopyInsets())
    }
}

// MARK: - Glass

/// The rim highlight that sells the glass: bright top, faint bottom.
/// Shared by every glass control (quiz buttons, rating pills, chevrons).
let glassRim = LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.08)],
                              startPoint: .top, endPoint: .bottom)

/// The chrome every page-header control wears: Sort, the View menu, Filters.
///
/// Quiet at rest — a label and a symbol, no plate, no rim — a soft fill under
/// the pointer, and the accent only when the control is actually doing
/// something. Glass capsules belong over artwork, where there is a picture to
/// float above; in a header strip they read as a row of buttons stamped into
/// a toolbar, which is the look this replaces.
private struct HeaderControl: ViewModifier {
    let active: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .font(.callout.weight(.medium))
            .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.12), value: active)
    }

    private var fill: AnyShapeStyle {
        if active { return AnyShapeStyle(.tint.opacity(0.16)) }
        return hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)
    }
}

extension View {
    /// Glass capsule chrome for controls floating over artwork.
    func glassCapsule() -> some View {
        background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(glassRim, lineWidth: 1))
    }

    /// The chrome every page-header control wears: a glass capsule that
    /// brightens when its state is on. One rule, so the layout switch, the
    /// library filter and the Filters button read as one row of controls
    /// rather than three widgets from three eras.
    func glassControl(active: Bool = false) -> some View {
        modifier(HeaderControl(active: active))
    }

    /// The chrome every pushed page wears: it starts at the window's top
    /// edge, wears the same (empty, transparent) window toolbar as the
    /// sections, and carries its own back control rather than the toolbar's,
    /// which sat right on top of the traffic lights.
    func pushedPage() -> some View {
        // A pushed page gets the window-toolbar inset back even though the
        // stack ignores it, which pushed the page a bar's height down.
        ignoresSafeArea(edges: .top)
        // Same toolbar configuration the stack root declares — see RootView.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar(removing: .title)
            .navigationBarBackButtonHidden(true)
    }

    /// Pushed pages whose content runs full-bleed under the top edge — a
    /// detail's backdrop, a person's page — float the back control over that
    /// artwork. A page with a header strip puts a `BackButton()` in the strip
    /// instead: floated, it stacks a second row of chrome above the title.
    func floatingBackButton() -> some View {
        pushedPage()
            .overlay(alignment: .topLeading) {
                // The overlay gets its own full-bleed container: placed in the
                // page's safe area it sat a toolbar's height too low, however
                // far up the page itself started.
                BackButton()
                    .padding(.leading, 20)
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .ignoresSafeArea(edges: .top)
            }
    }
}

// MARK: - Back

/// `pushedPage()` for a view that is only sometimes pushed — the genre
/// browse is the same view as the Movies section, which has no page to go
/// back to (and shows no back control).
struct PushedPage: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.pushedPage()
        } else {
            content
        }
    }
}

/// The app's back control: a glass circle sitting in the content, clear of
/// the sidebar. Replaces the window toolbar's back button, which had no
/// column to sit in once the content went full-bleed.
struct BackButton: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hovering = false

    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.8))
                .shadow(color: .black.opacity(0.5), radius: 3)
                .frame(width: 30, height: 30)
                .glassCapsule()
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("[", modifiers: .command)
        .onHover { hovering = $0 }
    }
}

// MARK: - Backdrop scrim

/// The one backdrop scrim: a whisper of darkness up top for the toolbar
/// area, and enough at the bottom to carry white type without ever reaching
/// flat black — the artwork should still be visible where it meets the page.
/// The detail header and the Home marquee share it, so heros always match.
struct BackdropScrim: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.22), location: 0),
                .init(color: .clear, location: 0.3),
                .init(color: .black.opacity(0.5), location: 0.72),
                .init(color: .black.opacity(0.76), location: 0.94),
                .init(color: .black.opacity(0.86), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
}

extension View {
    /// The hero's bottom edge. The banner used to stop at a hard line; art
    /// and scrim now dissolve together, so the backdrop reads as something
    /// behind the page rather than a card pasted on top of it. The fade runs
    /// long — it starts around a third down and eases out over the whole
    /// bottom half, never a visible edge anywhere along the way.
    func heroFade() -> some View {
        mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.32),
                    .init(color: .black.opacity(0.94), location: 0.45),
                    .init(color: .black.opacity(0.82), location: 0.58),
                    .init(color: .black.opacity(0.62), location: 0.70),
                    .init(color: .black.opacity(0.40), location: 0.81),
                    .init(color: .black.opacity(0.20), location: 0.90),
                    .init(color: .black.opacity(0.07), location: 0.96),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
    }
}

// MARK: - Ratings

/// One score from one service, ready to render. `value == nil` renders an
/// icon-only chip (a bare link, e.g. IMDb before its score arrives).
struct ServiceScore: Identifiable {
    let icon: String      // BrandIcon name: "tmdb" / "imdb" / "rt" / "tvdb"
    var value: String?
    var detail: String?   // e.g. vote count
    var url: URL?         // wraps the chip in a Link
    /// For services ArrCore ships no mark for — see `BrandMark.fallbackSymbol`.
    var fallbackSymbol: String? = nil
    var fallbackTint: Color = .secondary
    var id: String { icon }
}

extension ServiceScore {
    /// The single place scores get assembled and formatted — every view
    /// builds its ratings row through this, so order and precision never
    /// drift between screens.
    /// `external` is whatever MediaKit gathered beyond TMDB's own score —
    /// today Radarr's metadata proxy (IMDb / Rotten Tomatoes), tomorrow
    /// whatever provider claims `.ratings`. The view never learns which.
    static func row(tmdb: Double?, votes: Int? = nil, tmdbURL: URL? = nil,
                    external: MediaKit.Ratings? = nil,
                    imdbURL: URL? = nil) -> [ServiceScore] {
        var scores: [ServiceScore] = []
        // How many people said so, per service — compact, because "2 666 038"
        // is three times the width of the score it qualifies.
        // In brackets, always: next to "6,4" a bare "18" reads as part of
        // the score.
        func count(_ votes: Int?) -> String? {
            guard let votes, votes > 0 else { return nil }
            return "(\(votes.formatted(.number.notation(.compactName))))"
        }
        if let tmdb, tmdb > 0 {
            scores.append(ServiceScore(
                icon: "tmdb",
                value: tmdb.formatted(.number.precision(.fractionLength(1))),
                detail: count(votes),
                url: tmdbURL))
        }
        if let imdb = external?.value(for: .imdb), imdb > 0 {
            scores.append(ServiceScore(
                icon: "imdb",
                value: imdb.formatted(.number.precision(.fractionLength(1))),
                detail: count(external?.scores.first { $0.service == .imdb }?.voteCount),
                url: imdbURL))
        } else if let imdbURL {
            scores.append(ServiceScore(icon: "imdb", value: nil, url: imdbURL))
        }
        if let rt = external?.value(for: .rottenTomatoes), rt > 0 {
            scores.append(ServiceScore(icon: "rt", value: "\(Int(rt))%"))
        }
        // Series only: TheTVDB is what Sonarr carries, and for a show TMDB
        // barely knows it is often the only score there is. No fallback glyph:
        // ArrCore ships TheTVDB's real mark, and a stand-in here would only
        // hide the day it goes missing.
        if let tvdb = external?.value(for: .tvdb), tvdb > 0 {
            let votes = external?.scores.first { $0.service == .tvdb }?.voteCount
            scores.append(ServiceScore(
                icon: "tvdb",
                value: tvdb.formatted(.number.precision(.fractionLength(1))),
                detail: count(votes)))
        }
        return scores
    }
}

/// THE multi-service ratings control. Three variants only:
/// - `.glass`: big glass pills for heros and the Quiz.
/// - `.chip`: compact capsules for the detail header and the list layout.
/// - `.inline`: bare icon + value, no plate and no colour of its own — the
///   detail hero's corner, poster captions, reviews. Every score is written
///   with the mark of the service it came from; a bare star belongs nowhere.
struct ScoreStrip: View {
    enum Style { case glass, chip, inline }
    let scores: [ServiceScore]
    var style: Style = .glass
    /// Size multiplier for the `.inline` variant only — a poster caption
    /// wants it at 1, the detail hero's corner reads it from across the room.
    var scale: CGFloat = 1
    /// Vote counts alongside each score. Off by default: a poster caption has
    /// a poster's width, and the count is the least of what it has to say.
    var showsVotes = false
    /// White cuts of the service marks — see `BrandIcon.mono`.
    var mono = false
    /// One score per line, `.inline` only — the hero's corner reads as a
    /// short column of services rather than one long sentence of numbers.
    var axis: Axis = .horizontal

    var body: some View {
        let spacing = (style == .glass ? 10 : 8) * (style == .inline ? scale : 1)
        if axis == .vertical {
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(scores) { score in
                    pill(score).modifier(LinkChip(url: score.url))
                }
            }
        } else {
            HStack(spacing: spacing) {
                ForEach(scores) { score in
                    pill(score).modifier(LinkChip(url: score.url))
                }
            }
        }
    }

    /// Vote counts are detail: they ride along in the plated variants, and in
    /// the inline one only where there is room for them (the detail hero's
    /// corner) — never in a poster caption, where space is a poster's width.
    private var showsDetail: Bool { style != .inline || showsVotes }

    @ViewBuilder
    private func pill(_ score: ServiceScore) -> some View {
        let content = HStack(spacing: style == .glass ? 7 : 5) {
            BrandMark(name: score.icon, height: iconHeight(score.icon), mono: mono,
                      fallbackSymbol: score.fallbackSymbol,
                      fallbackTint: mono ? .white : score.fallbackTint)
            if let value = score.value {
                Text(value)
                    .font(style == .glass
                        ? .system(size: 15, weight: .bold)
                        : .system(size: 12 * (style == .inline ? scale : 1),
                                  weight: .semibold))
            }
            if let detail = score.detail, showsDetail {
                Text(detail)
                    .font(style == .inline
                        ? .system(size: 9.5 * scale, weight: .medium)
                        : (style == .glass ? .caption : .caption2))
                    .opacity(style == .inline ? 0.75 : 0.65)
            }
        }
        switch style {
        case .glass:
            content
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .glassCapsule()
        case .chip:
            content
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.white.opacity(0.16), in: Capsule())
        case .inline:
            // No colour of its own: over artwork the score is white and
            // full-strength, in a caption the caller asks for `.secondary`.
            content
        }
    }

    private func iconHeight(_ icon: String) -> CGFloat {
        baseIconHeight(icon) * (style == .inline ? scale : 1)
    }

    private func baseIconHeight(_ icon: String) -> CGFloat {
        switch (style, icon) {
        case (.glass, "imdb"): 15
        case (.glass, "tvdb"): 13
        case (.glass, _): 14
        case (.chip, "tmdb"): 11
        case (.chip, "imdb"): 14
        case (.chip, "tvdb"): 11
        case (.chip, _): 12
        case (.inline, "tmdb"): 9
        case (.inline, "imdb"): 11
        case (.inline, "tvdb"): 9
        case (.inline, _): 10
        }
    }
}

/// Wraps a chip in a Link when a URL is available; leaves it inert otherwise.
struct LinkChip: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            Link(destination: url) { content }
                .buttonStyle(.plain)
                .pointerStyle(.link)
        } else {
            content
        }
    }
}

// MARK: - Paging chevron

/// Apple-style paging arrow: a quiet white chevron floating at the edge
/// that turns fully white on hover. Used by the detail's previous/next,
/// the Home marquee and every shelf. `arrowKeys` opts into bare-arrow-key
/// paging — only one control per screen should claim it.
struct PagingChevron: View {
    enum Direction { case previous, next }
    let direction: Direction
    var arrowKeys = false
    /// Title the arrow moves to, shown as a tooltip.
    var help: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: direction == .previous ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.5))
                .shadow(color: .black.opacity(0.6), radius: 4)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")

        if arrowKeys {
            button.keyboardShortcut(direction == .previous ? .leftArrow : .rightArrow,
                                    modifiers: [])
        } else {
            button
        }
    }
}

// MARK: - Full-height sidebar

/// Window chrome SwiftUI can't express: the titlebar height that puts the
/// traffic lights inside the sidebar panel, and hard limits on the sidebar
/// column. `navigationSplitViewColumnWidth(min:ideal:max:)` is advisory —
/// the divider still dragged past half the window and could collapse the
/// column with no way to bring it back, so the limits are set on the
/// `NSSplitViewItem` itself, which is authoritative.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(from: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { apply(from: view) }
    }

    private func apply(from view: NSView) {
        guard let window = view.window else { return }
        window.titlebarAppearsTransparent = true
        // No title text in the bar either — the section name belongs in the
        // sidebar, not stamped over the hero art.
        window.titleVisibility = .hidden
        // A unified toolbar gives the titlebar its full height, which is
        // what drops the traffic lights to where Apple TV has them; the
        // short titlebar had them riding up in the corner.
        window.toolbarStyle = .unified
        // The toolbar exists purely for its height: without one the titlebar
        // is short and the traffic lights ride up out of the sidebar panel.
        // It carries no items, and the separator that made it read as a
        // strip across the top of the detail page is switched off.
        // The toolbar exists purely for its height: without one the titlebar
        // is short and the traffic lights ride up out of the sidebar panel.
        // It stays EMPTY on every page — no title, no items. SwiftUI crashes
        // in `updateToolbarIfNeeded` when a page changes what the toolbar
        // holds, so pages put their chrome in their own content instead (see
        // `floatingBackButton`, the library grids' Select button).
        if window.toolbar == nil { window.toolbar = NSToolbar() }
        window.titlebarSeparatorStyle = .none
        guard let item = splitController(window.contentViewController)?.splitViewItems.first
        else { return }
        // NOTE: `allowsFullHeightLayout` is deliberately NOT set — with it
        // the hero's backdrop collapsed to nothing. The unified toolbar
        // alone puts the lights where they belong.
        // Limits only. Fighting an in-progress collapse from a KVO callback
        // crashed the app mid-drag; the column is kept visible from the
        // SwiftUI side instead.
        // Widths come from the SwiftUI column modifier; this only keeps the
        // column from collapsing away, which nothing could undo.
        item.canCollapse = false
    }

    private func splitController(_ controller: NSViewController?) -> NSSplitViewController? {
        guard let controller else { return nil }
        if let split = controller as? NSSplitViewController { return split }
        for child in controller.children {
            if let split = splitController(child) { return split }
        }
        return nil
    }

}

// MARK: - Scroll-wheel paging

/// Invisible overlay that turns a horizontal trackpad swipe / mouse wheel
/// over its area into previous/next paging (`-1` / `+1`). Clicks pass
/// straight through; vertical scrolling stays with the enclosing scroll
/// view. Pair it with `PagingChevron`s so every paged element also pages
/// by scroll.
struct ScrollWheelPager: NSViewRepresentable {
    let onPage: (Int) -> Void

    func makeNSView(context: Context) -> WheelCatcher {
        let view = WheelCatcher()
        view.onPage = onPage
        return view
    }

    func updateNSView(_ view: WheelCatcher, context: Context) {
        view.onPage = onPage
    }

    final class WheelCatcher: NSView {
        /// Minimum time between two pages. A trackpad flick arrives as a
        /// long burst of deltas and a mouse wheel carries no phase at all,
        /// so the phase-based guard alone let a single flick run through a
        /// dozen titles.
        private static let cooldown: TimeInterval = 0.18

        var onPage: ((Int) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var consumedGesture = false
        private var lastPagedAt: TimeInterval = 0

        // Never intercept clicks — the catcher listens via an event monitor.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return event }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }

            if event.phase == .began {
                accumulated = 0
                consumedGesture = false
            }
            // One page per swipe — the momentum tail is noise, swallow it.
            if consumedGesture { return nil }
            accumulated += event.scrollingDeltaX
            if abs(accumulated) > 50 {
                // …and one page per cooldown window, whatever the device:
                // keep eating the deltas, just don't turn them into pages.
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastPagedAt < Self.cooldown {
                    accumulated = 0
                    return nil
                }
                lastPagedAt = now
                // Natural scrolling: fingers left (negative delta) → next.
                onPage?(accumulated < 0 ? 1 : -1)
                accumulated = 0
                consumedGesture = event.phase != [] || event.momentumPhase != []
            }
            return nil
        }
    }
}



// MARK: - Glass segmented picker

/// The glass two-way switch: a capsule of glass with a bright pill that
/// slides under the chosen option. Used where a segmented control would sit
/// on artwork or a bar and the system's flat one looks pasted on.
struct GlassSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    /// The options, in the order they are drawn.
    let options: [(value: Value, title: String)]

    @Namespace private var pill
    @State private var hovering: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        selection = option.value
                    }
                } label: {
                    Text(option.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(.background)
                                                  : AnyShapeStyle(.primary))
                        .opacity(selected || hovering == option.value ? 1 : 0.7)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background {
                            if selected {
                                // One pill for the whole control, so it
                                // travels between the options instead of
                                // fading out here and in over there.
                                Capsule()
                                    .fill(.primary)
                                    .matchedGeometryEffect(id: "glass.segment", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 ? option.value : nil }
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(glassRim, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
