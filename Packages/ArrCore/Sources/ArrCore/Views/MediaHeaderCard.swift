import SwiftUI

// MARK: - Media header card
//
// Pulled out of MediaDetailComponents.swift — this single chrome
// component is used by every detail surface (movie / series / album
// detail, search-add panel). Owning its own file means the visual
// language can evolve without thumbing through a 1700-line file.

public struct RatingChip {
    let label: String
    let value: String
    let color: Color
    /// When set, the pill becomes a link to the rating's home page
    /// (IMDb title, TMDB record, RT/Metacritic search, …).
    let url: URL?
    /// Asset name of the service's brand icon (in `ServiceIcons.xcassets`) —
    /// shown in place of the text `label` when present.
    let iconName: String?

    public init(label: String, value: String, color: Color, url: URL? = nil, iconName: String? = nil) {
        self.label = label
        self.value = value
        self.color = color
        self.url = url
        self.iconName = iconName
    }
}

/// The ONE place each rating source's label, colour, brand icon, value
/// format and deep-link rule live. Call sites (detail heroes, search/add
/// panel, tooltips, discover cards) build chips exclusively through these,
/// so a chip for the same source can't render differently between views.
///
/// `linkTitle == nil` → unlinked pill (the tooltip convention: hover chrome,
/// not a click target). Passing a title links to the site's record when an
/// id is known, its search otherwise.
///
/// Every factory returns `nil` for a zero/absent score — 0.0 is "not rated
/// yet", not a rating, and hiding it HERE means no surface can disagree.
public extension RatingChip {
    static func imdb(_ value: Double, linkTitle: String? = nil, imdbId: String? = nil) -> RatingChip? {
        guard value > 0 else { return nil }
        return RatingChip(label: "IMDb", value: String(format: "%.1f", value), color: .yellow,
                          url: linkTitle.flatMap { RatingSiteLink.imdb(id: imdbId, title: $0) },
                          iconName: "rating-imdb")
    }

    static func tmdb(_ value: Double, linkTitle: String? = nil, tmdbId: Int? = nil) -> RatingChip? {
        guard value > 0 else { return nil }
        return RatingChip(label: "TMDB", value: String(format: "%.1f", value), color: .teal,
                          url: linkTitle.flatMap { RatingSiteLink.tmdbMovie(id: tmdbId, title: $0) },
                          iconName: "rating-tmdb")
    }

    static func tvdb(_ value: Double, linkTitle: String? = nil, tvdbId: Int? = nil) -> RatingChip? {
        guard value > 0 else { return nil }
        return RatingChip(label: "TVDB", value: String(format: "%.1f", value), color: .blue,
                          url: linkTitle.flatMap { RatingSiteLink.tvdbSeries(id: tvdbId, title: $0) },
                          iconName: "rating-tvdb")
    }

    static func rottenTomatoes(_ value: Double, linkTitle: String? = nil) -> RatingChip? {
        guard value > 0 else { return nil }
        return RatingChip(label: "RT", value: "\(Int(value))%", color: .red,
                          url: linkTitle.flatMap { RatingSiteLink.rottenTomatoes(title: $0) },
                          iconName: "rating-rt")
    }

    static func metacritic(_ value: Double, linkTitle: String? = nil) -> RatingChip? {
        guard value > 0 else { return nil }
        return RatingChip(label: "MC", value: "\(Int(value))", color: .green,
                          url: linkTitle.flatMap { RatingSiteLink.metacritic(title: $0) })
    }

    /// Sourceless score (Lidarr artists/albums, Sonarr seasons) — a plain
    /// yellow "Rating" pill with no brand mark or link.
    static func plain(_ value: Double) -> RatingChip? {
        guard value > 0 else { return nil }
        return RatingChip(label: "Rating", value: String(format: "%.1f", value), color: .yellow)
    }
}

/// Builders for the pages a rating chip can deep-link to. Direct record
/// links when an id is known; the site's search otherwise — RT and
/// Metacritic ids never reach the arr payloads at all.
public enum RatingSiteLink {
    private static func q(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
    public static func imdb(id: String?, title: String) -> URL? {
        if let id, !id.isEmpty { return URL(string: "https://www.imdb.com/title/\(id)/") }
        return URL(string: "https://www.imdb.com/find/?q=\(q(title))")
    }
    public static func tmdbMovie(id: Int?, title: String) -> URL? {
        if let id, id > 0 { return URL(string: "https://www.themoviedb.org/movie/\(id)") }
        return URL(string: "https://www.themoviedb.org/search?query=\(q(title))")
    }
    public static func tvdbSeries(id: Int?, title: String) -> URL? {
        if let id, id > 0 { return URL(string: "https://thetvdb.com/dereferrer/series/\(id)") }
        return URL(string: "https://thetvdb.com/search?query=\(q(title))")
    }
    public static func rottenTomatoes(title: String) -> URL? {
        URL(string: "https://www.rottentomatoes.com/search?search=\(q(title))")
    }
    public static func metacritic(title: String) -> URL? {
        URL(string: "https://www.metacritic.com/search/\(q(title))/")
    }
}

/// Shared header card used by the queue detail view, the search add
/// panel, and any other "what is this thing?" surface. Right column
/// scales by what's provided — every field is optional, callers pass
/// only the data their source can supply.
public struct MediaHeaderCard: View {
    let title: String
    var subtitle: String?
    var year: Int?
    var runtime: Int?
    var network: String?
    var certification: String?
    var genres: [String]
    var ratings: [RatingChip]
    /// Synopsis text. When present it renders in the right column
    /// beside the poster (tooltip layout) instead of below the whole
    /// card, so the description starts next to the artwork rather than
    /// under it. Wraps in an `ExpandableOverview` (4-line clamp + Show
    /// more) so a long synopsis still flows below the poster.
    var overview: String?
    let posterURL: URL?
    var posterRequiresAuth: Bool
    var apiKey: String?
    var fallbackSymbol: String
    var posterAspect: CGFloat
    var blurred: Bool
    var trailing: AnyView?
    /// Small tag rendered inline next to the title — e.g. an
    /// "Upgrade" pill. Used to float standalone beneath the rating
    /// chips before; pinned to the title now so it has a clear
    /// referent.
    var titleBadge: AnyView?
    /// Optional poster-tap handler — when present, the poster is
    /// wrapped in a button that fires this closure with its URL,
    /// letting the host raise a lightbox.
    var onPosterTap: ((URL?) -> Void)?
    /// Hides the title + year line. DetailView sets this when the
    /// NavigationStack toolbar carries `Title (Year)` so the hero card
    /// doesn't duplicate it. Tooltips / popovers keep the in-card title
    /// (no nav chrome there to host it).
    var showTitle: Bool = true
    /// While true, the right column shows skeleton placeholders for the
    /// metadata that's still loading (the runtime/cert row + overview)
    /// instead of sitting empty until the detail fetch lands. Defaults off,
    /// so callers that always pass complete data are unaffected.
    var metadataLoading: Bool = false

    public init(
        title: String,
        subtitle: String? = nil,
        year: Int? = nil,
        runtime: Int? = nil,
        network: String? = nil,
        certification: String? = nil,
        genres: [String] = [],
        ratings: [RatingChip] = [],
        overview: String? = nil,
        posterURL: URL?,
        posterRequiresAuth: Bool = false,
        apiKey: String? = nil,
        fallbackSymbol: String = "film",
        posterAspect: CGFloat = 2.0/3.0,
        blurred: Bool = false,
        trailing: AnyView? = nil,
        titleBadge: AnyView? = nil,
        onPosterTap: ((URL?) -> Void)? = nil,
        showTitle: Bool = true,
        metadataLoading: Bool = false
    ) {
        self.title = title
        self.subtitle = subtitle
        self.year = year
        self.runtime = runtime
        self.network = network
        self.certification = certification
        self.genres = genres
        self.ratings = ratings
        self.overview = overview
        self.posterURL = posterURL
        self.posterRequiresAuth = posterRequiresAuth
        self.apiKey = apiKey
        self.fallbackSymbol = fallbackSymbol
        self.posterAspect = posterAspect
        self.blurred = blurred
        self.trailing = trailing
        self.titleBadge = titleBadge
        self.onPosterTap = onPosterTap
        self.showTitle = showTitle
        self.metadataLoading = metadataLoading
    }

    public var body: some View {
        let posterWidth: CGFloat = 110
        let posterHeight = posterWidth / posterAspect
        HStack(alignment: .top, spacing: 12) {
            posterView(width: posterWidth, height: posterHeight)
            VStack(alignment: .leading, spacing: 4) {
                if showTitle {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        titleWithYear
                            .scaledFont(size: 15, weight: .semibold)
                            .lineLimit(3)
                        if let titleBadge {
                            titleBadge
                        }
                    }
                } else if let titleBadge {
                    // Badge still has a home — pulled out of the title row
                    // and floated above the metadata so it doesn't get
                    // lost when the title moves to the nav bar.
                    titleBadge
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                if !genres.isEmpty {
                    GenreChips(genres: genres)
                }
                // Row 1 — metadata: runtime · network · certification.
                if hasMetadataRow {
                    metadataRow
                } else if metadataLoading {
                    SkeletonBar(width: 150, height: 11)
                }
                // Row 2 — ratings (IMDb / TMDB / RT / MC for movies, the
                // single Rating pill for series), on their OWN row UNDER
                // the metadata so movie + series headers read identically.
                if !ratings.isEmpty {
                    // Horizontal scroll instead of wrapping: in the narrow
                    // detail column four rating pills (IMDb/TMDB/RT/MC) would
                    // otherwise break onto a second line. The ScrollView clips
                    // to the right column (NO scrollClipDisabled) so scrolled
                    // pills hide at the column edge instead of bleeding left
                    // over the poster.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(ratings, id: \.label) { RatingPill(chip: $0) }
                        }
                    }
                }
                // Synopsis sits beside the poster (tooltip layout) so the
                // description starts next to the artwork; a long one wraps
                // down below the poster on its own.
                if let overview, !overview.isEmpty {
                    ExpandableOverview(text: overview)
                        .padding(.top, 2)
                } else if metadataLoading {
                    SkeletonLines(count: 3)
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

    private var hasMetadataRow: Bool {
        (runtime ?? 0) > 0
            || (network.map { !$0.isEmpty } ?? false)
            || (certification.map { !$0.isEmpty } ?? false)
    }

    @ViewBuilder
    private func posterView(width: CGFloat, height: CGFloat) -> some View {
        let poster = PosterBlurContainer(blurred: blurred, cornerRadius: Tokens.Radius.card) {
            RemotePoster(
                url: posterURL,
                apiKey: posterRequiresAuth ? apiKey : nil,
                size: CGSize(width: width, height: height),
                cornerRadius: Tokens.Radius.card,
                fallbackSymbol: fallbackSymbol
            )
        }
        if let onPosterTap {
            Button { onPosterTap(posterURL) } label: { poster }
                .buttonStyle(.plain)
                .help(Text("detail.showPoster.button", bundle: .module))
                .accessibilityLabel(Text("detail.showPoster.button", bundle: .module))
        } else {
            poster
        }
    }

    /// Metadata row under the genres: runtime · network · certification
    /// (dot-joined plain text). Ratings get their own row below this.
    @ViewBuilder
    private var metadataRow: some View {
        HStack(spacing: 6) {
            let segments: [String] = [
                (runtime ?? 0) > 0 ? "\(runtime!) min" : nil,
                network.flatMap { $0.isEmpty ? nil : $0 },
                certification.flatMap { $0.isEmpty ? nil : $0 },
            ].compactMap { $0 }
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                if idx > 0 { SeparatorDot() }
                Text(segment).foregroundStyle(.secondary)
            }
        }
        .scaledFont(size: 11)
    }
}

// MARK: - Poster lightbox
//
// Shared full-popover poster preview. Used by every detail surface
// that wants tap-to-enlarge on its poster — `DetailView`,
// `SearchAddPanel`, etc. Lifted out of `DetailView` so the chrome
// (frosted scrim, GeometryReader-fit poster, Apple-style xmark
// dismiss, tap-anywhere-to-close) lives in exactly one place.

public struct PosterLightbox: View {
    let url: URL
    var apiKey: String?
    /// Width / height ratio of the underlying art. Movie / series
    /// posters are 2:3 (≈0.667), album art is 1:1 (1.0). Hardcoding
    /// 2:3 made Lidarr lightboxes render too tall.
    var aspectRatio: CGFloat
    let onDismiss: () -> Void

    public init(
        url: URL,
        apiKey: String? = nil,
        aspectRatio: CGFloat = 2.0 / 3.0,
        onDismiss: @escaping () -> Void
    ) {
        self.url = url
        self.apiKey = apiKey
        self.aspectRatio = aspectRatio
        self.onDismiss = onDismiss
    }

    /// Live zoom (1 = fit). Updated continuously during the pinch via
    /// `.onChanged` (more reliable than `@GestureState` here), clamped 1…5.
    /// `baseZoom`/`baseOffset` hold the committed value between gestures so
    /// successive pinches/drags compound instead of snapping back.
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            // Frosted-glass scrim — `.regularMaterial` blurs the
            // popover chrome underneath without going solid black.
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            // Poster grows to the window edges. No insets: the macOS popover is
            // 400×600 and a 2:3 poster is exactly that ratio, so dropping the
            // margins fills the window pixel-perfect with nothing cropped.
            GeometryReader { geo in
                let posterW = min(geo.size.width, geo.size.height * aspectRatio)
                let posterH = posterW / aspectRatio
                // Still *fit*, not fill — Lidarr art is square (aspectRatio 1),
                // and covering a 2:3 window with it would eat a third of the
                // cover. Square art letterboxes and keeps its card treatment;
                // only artwork that genuinely reaches both edges goes full-bleed.
                let fullBleed = posterW >= geo.size.width - 0.5 && posterH >= geo.size.height - 0.5
                RemotePoster(
                    url: url,
                    apiKey: apiKey,
                    // The lightbox zooms to 5×, so it is the one place that wants
                    // the source at full resolution — held in memory for the
                    // sheet's lifetime, never written to disk.
                    tier: .full,
                    size: CGSize(width: posterW, height: posterH),
                    // Rounded corners over a full-bleed image would just carve
                    // notches out of the artwork with nothing behind them.
                    cornerRadius: fullBleed ? 0 : Tokens.Radius.panel,
                    fallbackSymbol: "photo"
                )
                .frame(width: posterW, height: posterH)
                .scaleEffect(zoom)
                .offset(offset)
                // Likewise the lift shadow: it needs a surface to fall on.
                .shadow(color: .black.opacity(fullBleed ? 0 : 0.5), radius: 20, y: 8)
                // Pinch to zoom (iOS finger / macOS trackpad), drag to pan
                // once zoomed. `.onChanged` drives the live scale; the two
                // gestures run simultaneously so you can pinch-and-pan.
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            zoom = min(max(baseZoom * value, 1), 5)
                        }
                        .onEnded { _ in
                            baseZoom = zoom
                            if zoom <= 1.01 {
                                withAnimation(.smooth(duration: 0.2)) { offset = .zero; baseOffset = .zero }
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard zoom > 1 else { return }
                            offset = CGSize(width: baseOffset.width + value.translation.width,
                                            height: baseOffset.height + value.translation.height)
                        }
                        .onEnded { _ in baseOffset = offset }
                )
                .contentShape(Rectangle())
                // Tap: zoom back out when zoomed, otherwise dismiss.
                .onTapGesture {
                    if zoom > 1 {
                        withAnimation(.smooth(duration: 0.2)) {
                            zoom = 1; baseZoom = 1; offset = .zero; baseOffset = .zero
                        }
                    } else {
                        onDismiss()
                    }
                }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            // Only the artwork bleeds past the safe area — without this the
            // GeometryReader is inset by it and the poster stops short of the
            // notch and home indicator, i.e. "full screen" minus two strips.
            // Scoped to the poster on purpose: the close button below has to
            // stay *inside* the safe area, and it can only do that if the stack
            // around it still respects one.
            .ignoresSafeArea()

            // The xmark used to be dropped here, on the grounds that the scrim
            // and the native back chevron were both visible behind the poster.
            // Full-bleed took away both — the artwork now covers the popover to
            // the last pixel — so with no visible affordance the only ways out
            // (tap anywhere, Esc) are invisible ones you have to already know.
            // Hence a real button, which also carries the Esc shortcut that the
            // zero-sized placeholder used to hold.
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .scaledFont(size: 12, weight: .semibold)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassPill()
            #if os(macOS)
            .keyboardShortcut(.cancelAction)
            #endif
            .help(Text("detail.closePoster.button", bundle: .module))
            .accessibilityLabel(Text("detail.closePoster.button", bundle: .module))
            // Poster art is unpredictable — a light sky behind the glass pill
            // would swallow it — so lean on the same shadow the pill loses when
            // the artwork goes full-bleed.
            .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
            .padding(12)
        }
    }
}

/// Coloured capsule for a rating value (IMDb, RT, MC, …).
struct RatingPill: View {
    let chip: RatingChip
    public var body: some View {
        if let url = chip.url {
            Button { PlatformURLOpener.open(url) } label: {
                pill.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: url.host() ?? url.absoluteString))
            #if os(macOS)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            #endif
        } else {
            pill
        }
    }

    private var pill: some View {
        HStack(spacing: 3) {
            if let iconName = chip.iconName {
                // Brand mark (full colour, appearance-adaptive) in place of the
                // text label. Non-template so IMDb yellow / RT red etc. show.
                Image(iconName, bundle: .module)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 11)
            } else {
                Text(chip.label)
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(chip.color)
            }
            Text(chip.value)
                .scaledFont(size: 10, weight: .semibold, monospacedDigit: true)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.chip).stroke(chip.color.opacity(0.30), lineWidth: 0.75))
    }
}

// MARK: - Poster lightbox presentation

public extension View {
    /// Present `PosterLightbox` truly full-screen. iOS uses `.fullScreenCover`
    /// so it covers the nav bar + tab bar (no header, no back button — dismiss
    /// by tapping the poster). macOS overlays it inside the popover.
    @ViewBuilder
    func posterLightbox(url: Binding<URL?>, apiKey: String?, aspectRatio: CGFloat) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: Binding(
            get: { url.wrappedValue != nil },
            set: { if !$0 { url.wrappedValue = nil } }
        )) {
            if let u = url.wrappedValue {
                PosterLightbox(url: u, apiKey: apiKey, aspectRatio: aspectRatio,
                               onDismiss: { url.wrappedValue = nil })
            }
        }
        #else
        overlay {
            if let u = url.wrappedValue {
                PosterLightbox(url: u, apiKey: apiKey, aspectRatio: aspectRatio,
                               onDismiss: { url.wrappedValue = nil })
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        #endif
    }
}
