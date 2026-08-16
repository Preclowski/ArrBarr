import SwiftUI

// MARK: - Media header card
//
// Pulled out of MediaDetailComponents.swift — this single chrome
// component is used by every detail surface (movie / series / album
// detail, search-add panel). Owning its own file means the visual
// language can evolve without thumbing through a 1700-line file.

public struct RatingChip {
    /// Short on-pill text ("RT", "MC") — only rendered when the source has
    /// no brand mark. See `siteName` for the spelled-out name.
    let label: String
    let value: String
    let color: Color
    /// When set, the pill becomes a link to the rating's home page
    /// (IMDb title, TMDB record, RT/Metacritic search, …).
    let url: URL?
    /// Asset name of the service's brand icon (in `ServiceIcons.xcassets`) —
    /// shown in place of the text `label` when present.
    let iconName: String?
    /// How many people voted for `value`. Hover-only detail — an 8.6 off
    /// twelve votes and one off two million read identically on the pill,
    /// so the count rides in the tooltip rather than widening the chip.
    let votes: Int?
    /// The source spelled out for the tooltip ("Rotten Tomatoes") — a brand
    /// name, never localized. Nil for the sourceless `plain` pill.
    let siteName: String?

    public init(label: String, value: String, color: Color, url: URL? = nil,
                iconName: String? = nil, votes: Int? = nil, siteName: String? = nil) {
        self.label = label
        self.value = value
        self.color = color
        self.url = url
        self.iconName = iconName
        self.votes = votes
        self.siteName = siteName
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
    static func imdb(_ value: Double, linkTitle: String? = nil, imdbId: String? = nil,
                     votes: Int? = nil) -> RatingChip? {
        guard value > 0 else { return nil }
        return RatingChip(label: "IMDb", value: String(format: "%.1f", value), color: .yellow,
                          url: linkTitle.flatMap { RatingSiteLink.imdb(id: imdbId, title: $0) },
                          iconName: "rating-imdb", votes: votes, siteName: "IMDb")
    }

    static func tmdb(_ value: Double, linkTitle: String? = nil, tmdbId: Int? = nil,
                     votes: Int? = nil) -> RatingChip? {
        guard value > 0 else { return nil }
        return RatingChip(label: "TMDB", value: String(format: "%.1f", value), color: .teal,
                          url: linkTitle.flatMap { RatingSiteLink.tmdbMovie(id: tmdbId, title: $0) },
                          iconName: "rating-tmdb", votes: votes, siteName: "TMDB")
    }

    static func tvdb(_ value: Double, linkTitle: String? = nil, tvdbId: Int? = nil,
                     votes: Int? = nil) -> RatingChip? {
        guard value > 0 else { return nil }
        return RatingChip(label: "TVDB", value: String(format: "%.1f", value), color: .blue,
                          url: linkTitle.flatMap { RatingSiteLink.tvdbSeries(id: tvdbId, title: $0) },
                          iconName: "rating-tvdb", votes: votes, siteName: "TVDB")
    }

    static func rottenTomatoes(_ value: Double, linkTitle: String? = nil,
                               votes: Int? = nil) -> RatingChip? {
        guard value > 0 else { return nil }
        return RatingChip(label: "RT", value: "\(Int(value))%", color: .red,
                          url: linkTitle.flatMap { RatingSiteLink.rottenTomatoes(title: $0) },
                          iconName: "rating-rt", votes: votes, siteName: "Rotten Tomatoes")
    }

    static func metacritic(_ value: Double, linkTitle: String? = nil,
                           votes: Int? = nil) -> RatingChip? {
        guard value > 0 else { return nil }
        return RatingChip(label: "MC", value: "\(Int(value))", color: .green,
                          url: linkTitle.flatMap { RatingSiteLink.metacritic(title: $0) },
                          votes: votes, siteName: "Metacritic")
    }

    /// Sourceless score (Lidarr artists/albums, Sonarr seasons) — a plain
    /// yellow "Rating" pill with no brand mark or link.
    static func plain(_ value: Double, votes: Int? = nil) -> RatingChip? {
        guard value > 0 else { return nil }
        return RatingChip(label: "Rating", value: String(format: "%.1f", value), color: .yellow,
                          votes: votes)
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
    /// Pinned to the poster's bottom-right corner, over the artwork — the
    /// trailer badge's home. On the poster rather than in a row of its own so
    /// the affordance sits on the thing it plays.
    var posterBadge: AnyView?
    /// Pinned to the poster's TOP-right corner, over the artwork — the
    /// monitored bookmark's home on the detail surfaces. Opposite corner from
    /// `posterBadge` so the two never collide.
    var posterCornerAction: AnyView?
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
        posterBadge: AnyView? = nil,
        posterCornerAction: AnyView? = nil,
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
        self.posterBadge = posterBadge
        self.posterCornerAction = posterCornerAction
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

    private func posterView(width: CGFloat, height: CGFloat) -> some View {
        DetailHeroPoster(
            url: posterURL,
            apiKey: posterRequiresAuth ? apiKey : nil,
            size: CGSize(width: width, height: height),
            fallbackSymbol: fallbackSymbol,
            blurred: blurred,
            cornerAction: posterCornerAction,
            badge: posterBadge,
            onTap: onPosterTap
        )
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

    #if os(macOS)
    /// macOS has no pinch here: the menu-bar surface is a non-activating
    /// `NSPanel` and trackpad `.magnify` events never reach it — not the
    /// SwiftUI gesture, not even a local `NSEvent` monitor. (The same view
    /// pinches fine in the detached window, which is a real `NSWindow`.) So
    /// the Mac gets an explicit slider instead, which also serves Macs with
    /// a mouse. It fades out when the pointer leaves or goes idle so it
    /// never sits on top of the artwork it exists to reveal — and so does the
    /// close button, on the same timer: two pieces of chrome fading on
    /// separate schedules would read as a glitch.
    @State private var showsControls = false
    @State private var idleHide: Task<Void, Never>?
    /// True for the whole drag. A held mouse button stops delivering hover,
    /// so without this the idle countdown expires *while* you are scrubbing
    /// and the control fades out from under the pointer.
    @State private var isScrubbing = false

    /// Result of the last save, shown briefly then cleared. Not tied to
    /// `showsControls`: a confirmation that fades on the chrome's timer would
    /// vanish the moment the pointer left, which is exactly when you look.
    @State private var saveOutcome: PosterSaveOutcome?

    private enum PosterSaveOutcome { case saved, failed }

    private func savePosterToDownloads() {
        Task {
            let outcome = await Self.writePosterToDownloads(url: url, apiKey: apiKey)
            withAnimation(.smooth(duration: 0.2)) { saveOutcome = outcome }
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.smooth(duration: 0.3)) { saveOutcome = nil }
        }
    }

    /// Writes the `.full` copy — the one on screen — into ~/Downloads.
    ///
    /// Reads it out of `PosterStore` rather than re-fetching: the lightbox has
    /// already pulled that exact tier, so the common case touches no network
    /// at all. Requires `com.apple.security.files.downloads.read-write`; the
    /// sandbox denies the write without it.
    private static func writePosterToDownloads(url: URL, apiKey: String?) async -> PosterSaveOutcome {
        var data = PosterStore.storedData(for: url, tier: .full)
        if data == nil {
            _ = await PosterStore.shared.image(for: url, tier: .full, apiKey: apiKey)
            data = PosterStore.storedData(for: url, tier: .full)
        }
        guard let data else { return .failed }

        let fm = FileManager.default
        guard let dir = try? fm.url(for: .downloadsDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: false) else { return .failed }
        // *arr artwork is served as .../MediaCover/12/poster.jpg, so the last
        // component is all we get for a name. Never overwrite: a second save
        // of a different title would otherwise clobber the first.
        let stem = url.deletingPathExtension().lastPathComponent
        let base = stem.isEmpty ? "poster" : stem
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        var target = dir.appendingPathComponent("\(base).\(ext)")
        var suffix = 2
        while fm.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(base) \(suffix).\(ext)")
            suffix += 1
        }
        do { try data.write(to: target) } catch { return .failed }
        return .saved
    }

    /// Show the bar and restart the idle countdown.
    private func revealControls() {
        idleHide?.cancel()
        withAnimation(.smooth(duration: 0.18)) { showsControls = true }
        idleHide = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !isScrubbing else { return }
            withAnimation(.smooth(duration: 0.3)) { showsControls = false }
        }
    }
    #endif

    /// Applies one step of a zoom, from whichever input drives it.
    private func setZoom(_ value: CGFloat) {
        zoom = min(max(value, 1), 5)
    }

    /// End of a zoom: commit it, and recentre if we landed back at fit —
    /// otherwise a pan made while zoomed leaves the fitted poster off-screen.
    private func commitZoom() {
        baseZoom = zoom
        if zoom <= 1.01 {
            withAnimation(.smooth(duration: 0.2)) { offset = .zero; baseOffset = .zero }
        }
    }

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
                // Pinch to zoom, drag to pan once zoomed. iOS only — see the
                // `showsControls` note above for why the Mac gets a slider.
                #if os(iOS)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            setZoom(baseZoom * value.magnification)
                        }
                        .onEnded { _ in commitZoom() }
                )
                #endif
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
                #if os(macOS)
                // On the artwork only, not the whole lightbox: over a square
                // cover's letterbox bands there is no image to act on.
                .contextMenu {
                    Button(action: savePosterToDownloads) {
                        Label {
                            Text("detail.savePoster.button", bundle: .module)
                        } icon: {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                }
                #endif
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
            // Shared with the trailer overlay — see `LightboxCloseButton`,
            // which also carries the shadow the glass pill needs over
            // unpredictable artwork, and the Esc shortcut.
            LightboxCloseButton(labelKey: "detail.closePoster.button", action: onDismiss)
            #if os(macOS)
            // Fades on the same timer as the zoom slider. Deliberately still
            // hit-testable while invisible: clicking where it sits dismisses
            // either way (tap-anywhere already does), and taking hit-testing
            // away risks taking the Esc shortcut with it. iOS keeps it up
            // permanently — there is no pointer there to bring it back.
            .opacity(showsControls ? 1 : 0)
            #endif

            #if os(macOS)
            VStack(spacing: 10) {
                if saveOutcome != nil { saveNote }
                zoomBar
                    .opacity(showsControls ? 1 : 0)
                    // Not just invisible — an idle bar must not eat clicks
                    // meant for the tap-to-dismiss underneath it.
                    .allowsHitTesting(showsControls)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 16)
            #endif
        }
        #if os(macOS)
        // Reveal on any pointer movement over the lightbox, then let it time
        // out. `.onContinuousHover` rather than `.onHover` so a pointer that
        // stops and starts again inside the window brings it back.
        .onContinuousHover { phase in
            switch phase {
            case .active: revealControls()
            // Not while scrubbing: a drag that wanders off the window edge
            // still owns the pointer, and yanking the control mid-drag is the
            // same bug as letting the idle timer do it.
            case .ended where !isScrubbing:
                idleHide?.cancel()
                withAnimation(.smooth(duration: 0.3)) { showsControls = false }
            case .ended: break
            @unknown default: break
            }
        }
        // Show it once on open so it is discoverable at all — the countdown
        // takes it away again on its own.
        .onAppear { revealControls() }
        .onDisappear { idleHide?.cancel() }
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var saveNote: some View {
        Group {
            switch saveOutcome {
            case .failed: Text("detail.savePoster.failed", bundle: .module)
            default: Text("detail.savePoster.saved", bundle: .module)
            }
        }
        .scaledFont(size: 11, weight: .medium)
        .foregroundStyle(.white)
        // Same treatment as the slider: legibility from a shadow rather than
        // from a slab laid over the artwork.
        .shadow(color: .black.opacity(0.65), radius: 4, y: 1)
        .transition(.opacity)
    }

    private static let zoomBarWidth: CGFloat = 180
    private static let zoomKnob: CGFloat = 12

    /// Hand-drawn rather than a `Slider`, for the same reason the progress
    /// bars are: the stock control paints its filled half in the accent
    /// colour, which vanishes over light artwork, and there is no way to
    /// recolour just that half. White-on-dark-capsule reads over any poster.
    private var zoomBar: some View {
        let span = Self.zoomBarWidth - Self.zoomKnob
        let fraction = (zoom - 1) / 4
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(.black.opacity(0.4))
                .frame(height: 4)
            Capsule()
                .fill(.white)
                .frame(width: Self.zoomKnob / 2 + span * fraction, height: 4)
            Circle()
                .fill(.white)
                .frame(width: Self.zoomKnob, height: Self.zoomKnob)
                .offset(x: span * fraction)
        }
        .frame(width: Self.zoomBarWidth, height: Self.zoomKnob)
        .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
        // Padding first, then the hit shape: a 12pt-tall grab target is a
        // dart game. The padding stays invisible — no fill goes on it.
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isScrubbing = true
                    let f = min(max((value.location.x - Self.zoomKnob / 2) / span, 0), 1)
                    setZoom(1 + f * 4)
                    baseZoom = zoom
                    revealControls()
                }
                .onEnded { _ in
                    isScrubbing = false
                    commitZoom()
                    revealControls()
                }
        )
        .onContinuousHover { _ in revealControls() }
        .accessibilityLabel(Text("detail.zoomPoster.slider", bundle: .module))
        .accessibilityValue(Text(verbatim: String(format: "%.1f×", zoom)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setZoom(zoom + 0.5)
            case .decrement: setZoom(zoom - 0.5)
            @unknown default: break
            }
            commitZoom()
        }
    }
    #endif
}

/// Coloured capsule for a rating value (IMDb, RT, MC, …).
struct RatingPill: View {
    let chip: RatingChip
    /// Drives both the vote-count wording and its digit grouping, and tracks
    /// a live in-app language switch (see `AppLocalized`).
    @Environment(\.locale) private var locale

    public var body: some View {
        if let url = chip.url {
            Button { PlatformURLOpener.open(url) } label: {
                pill.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: helpText))
            #if os(macOS)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            #endif
        } else if !helpText.isEmpty {
            pill.help(Text(verbatim: helpText))
        } else {
            pill
        }
    }

    /// "1 234 567 votes" — nil when the source shipped no count (or zero,
    /// which *arr sends for unrated titles).
    private var votesLine: String? {
        guard let votes = chip.votes, votes > 0 else { return nil }
        return String(format: AppLocalized.string("rating.votes.format", locale: locale),
                      votes.formatted(.number.locale(locale)))
    }

    /// Source name, then the vote count under it. The name — not the link's
    /// host — because the brand mark on the pill is the thing being spelled
    /// out; where a click lands is obvious from it.
    private var helpText: String {
        [chip.siteName, votesLine].compactMap { $0 }.joined(separator: "\n")
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
