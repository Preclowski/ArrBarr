import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Media header card

public struct RatingChip {
    /// Short on-pill text ("RT", "MC"), shown only when the source has no brand mark.
    let label: String
    let value: String
    let color: Color
    let url: URL?
    /// Asset in `ServiceIcons.xcassets`, shown in place of `label`.
    let iconName: String?
    /// Tooltip-only: an 8.6 off twelve votes and one off two million read identically on the pill.
    let votes: Int?
    /// A brand name, never localized. Nil for the `plain` pill.
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

/// The one place each rating source's label, colour, icon, format and link rule live.
/// Every factory returns nil for a zero score: 0.0 means "not rated yet".
public extension RatingChip {
    static func imdb(_ value: Double, linkTitle: String? = nil, imdbId: String? = nil,
                     votes: Int? = nil) -> RatingChip? {
        guard value > 0 else { return nil }
        return RatingChip(label: "IMDb", value: value.ratingText, color: .yellow,
                          url: linkTitle.flatMap { RatingSiteLink.imdb(id: imdbId, title: $0) },
                          iconName: "rating-imdb", votes: votes, siteName: "IMDb")
    }

    static func tmdb(_ value: Double, linkTitle: String? = nil, tmdbId: Int? = nil,
                     votes: Int? = nil) -> RatingChip? {
        guard value > 0 else { return nil }
        return RatingChip(label: "TMDB", value: value.ratingText, color: .teal,
                          url: linkTitle.flatMap { RatingSiteLink.tmdbMovie(id: tmdbId, title: $0) },
                          iconName: "rating-tmdb", votes: votes, siteName: "TMDB")
    }

    static func tvdb(_ value: Double, linkTitle: String? = nil, tvdbId: Int? = nil,
                     votes: Int? = nil) -> RatingChip? {
        guard value > 0 else { return nil }
        return RatingChip(label: "TVDB", value: value.ratingText, color: .blue,
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

    /// Sourceless score (Lidarr, Sonarr seasons): no brand mark, no link.
    static func plain(_ value: Double, votes: Int? = nil) -> RatingChip? {
        guard value > 0 else { return nil }
        return RatingChip(label: "Rating", value: value.ratingText, color: .yellow,
                          votes: votes)
    }
}

/// RT and Metacritic ids never reach the arr payloads, so those always link to search.
enum RatingSiteLink {
    private static func q(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
    static func imdb(id: String?, title: String) -> URL? {
        if let id, !id.isEmpty { return URL(string: "https://www.imdb.com/title/\(id)/") }
        return URL(string: "https://www.imdb.com/find/?q=\(q(title))")
    }
    static func tmdbMovie(id: Int?, title: String) -> URL? {
        if let id, id > 0 { return URL(string: "https://www.themoviedb.org/movie/\(id)") }
        return URL(string: "https://www.themoviedb.org/search?query=\(q(title))")
    }
    static func tvdbSeries(id: Int?, title: String) -> URL? {
        if let id, id > 0 { return URL(string: "https://thetvdb.com/dereferrer/series/\(id)") }
        return URL(string: "https://thetvdb.com/search?query=\(q(title))")
    }
    static func rottenTomatoes(title: String) -> URL? {
        URL(string: "https://www.rottentomatoes.com/search?search=\(q(title))")
    }
    static func metacritic(title: String) -> URL? {
        URL(string: "https://www.metacritic.com/search/\(q(title))/")
    }
}

/// Shared header card for detail views, the search add panel and tooltips; every field is optional.
struct MediaHeaderCard: View {
    let title: String
    var subtitle: String?
    var year: Int?
    var runtime: Int?
    var network: String?
    var certification: String?
    /// Appended to the runtime · network · rating row (e.g. the episode air date).
    var extraMetadata: [String] = []
    /// ISO 3166-1 alpha-2 codes, localized at render so the row follows a live language switch.
    var countries: [String]
    var genres: [String]
    var ratings: [RatingChip]
    /// Renders beside the poster, clamped by `ExpandableOverview`.
    var overview: String?
    let posterURL: URL?
    var posterRequiresAuth: Bool
    var apiKey: String?
    var fallbackSymbol: String
    var posterAspect: CGFloat
    var blurred: Bool
    var trailing: AnyView?
    var titleBadge: AnyView?
    var onPosterTap: ((URL?) -> Void)?
    /// Pinned to the poster's top corner (the monitored bookmark).
    var posterCornerAction: AnyView?
    /// Rendered above the title (the episode header's series/season links).
    var aboveTitle: AnyView?
    var watched: Bool = false
    var libraryMark: LibraryMark?
    /// Off when the NavigationStack toolbar already shows `Title (Year)`.
    var showTitle: Bool = true
    /// Shows skeletons for the runtime row and overview while the detail fetch is in flight.
    var metadataLoading: Bool = false
    /// A movie's director(s) or a series' creator(s).
    var directedBy: [CastMember] = []
    var directedByKey: LocalizedStringKey = "detail.directedBy.label"
    /// Credits are still on their way: hold the director's line so the overview doesn't drop when it lands.
    var directedByLoading = false
    /// nil renders the names as plain text.
    var onTapPerson: ((CastMember) -> Void)?

    /// From the environment, not `Locale.current`, so a live language switch re-renders the row.
    @Environment(\.locale) private var locale

    init(
        title: String,
        subtitle: String? = nil,
        year: Int? = nil,
        runtime: Int? = nil,
        network: String? = nil,
        certification: String? = nil,
        extraMetadata: [String] = [],
        countries: [String] = [],
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
        posterCornerAction: AnyView? = nil,
        aboveTitle: AnyView? = nil,
        watched: Bool = false,
        libraryMark: LibraryMark? = nil,
        showTitle: Bool = true,
        metadataLoading: Bool = false,
        directedBy: [CastMember] = [],
        directedByKey: LocalizedStringKey = "detail.directedBy.label",
        directedByLoading: Bool = false,
        onTapPerson: ((CastMember) -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.year = year
        self.runtime = runtime
        self.network = network
        self.certification = certification
        self.extraMetadata = extraMetadata
        self.countries = countries
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
        self.posterCornerAction = posterCornerAction
        self.aboveTitle = aboveTitle
        self.watched = watched
        self.libraryMark = libraryMark
        self.showTitle = showTitle
        self.metadataLoading = metadataLoading
        self.directedBy = directedBy
        self.directedByKey = directedByKey
        self.directedByLoading = directedByLoading
        self.onTapPerson = onTapPerson
    }

    var body: some View {
        let posterWidth: CGFloat = 110
        let posterHeight = posterWidth / posterAspect
        HStack(alignment: .top, spacing: 12) {
            posterView(width: posterWidth, height: posterHeight)
            VStack(alignment: .leading, spacing: 4) {
                if let aboveTitle {
                    aboveTitle
                }
                if showTitle {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // Skeleton instead of a blank line that jumps when the name lands.
                        if title.isEmpty && metadataLoading {
                            SkeletonBar(width: 180, height: 15)
                        } else {
                            titleWithYear
                                .scaledFont(size: 15, weight: .semibold)
                                .lineLimit(3)
                        }
                        if let titleBadge {
                            titleBadge
                        }
                    }
                } else if let titleBadge {
                    titleBadge
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                if !genres.isEmpty {
                    GenreChips(genres: genres)
                } else if metadataLoading {
                    SkeletonBar(width: 120, height: 13, cornerRadius: Tokens.Radius.chip)
                }
                if hasMetadataRow {
                    metadataRow
                } else if metadataLoading {
                    SkeletonBar(width: 150, height: 11)
                }
                if !ratings.isEmpty {
                    // Scrolls rather than wraps so four pills fit the narrow column; no scrollClipDisabled,
                    // so scrolled pills clip at the column edge instead of bleeding over the poster.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(ratings, id: \.label) { RatingPill(chip: $0) }
                        }
                    }
                } else if metadataLoading {
                    HStack(spacing: 6) {
                        SkeletonBar(width: 46, height: 15, cornerRadius: Tokens.Radius.chip)
                        SkeletonBar(width: 46, height: 15, cornerRadius: Tokens.Radius.chip)
                    }
                }
                if !directedBy.isEmpty {
                    directedByLine
                } else if directedByLoading {
                    SkeletonBar(width: 130, height: 11)
                }
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
            || !countries.isEmpty
            || !extraMetadata.isEmpty
    }

    private func posterView(width: CGFloat, height: CGFloat) -> some View {
        DetailHeroPoster(
            url: posterURL,
            apiKey: posterRequiresAuth ? apiKey : nil,
            size: CGSize(width: width, height: height),
            fallbackSymbol: fallbackSymbol,
            blurred: blurred,
            cornerAction: posterCornerAction,
            watched: watched,
            libraryMark: libraryMark,
            onTap: onPosterTap
        )
    }

    @ViewBuilder
    private var directedByLine: some View {
        DirectedByLine(people: directedBy, labelKey: directedByKey, onTapPerson: onTapPerson)
    }

    /// Each segment is `fixedSize` and carries its trailing dot: a plain HStack squeezed long
    /// country names over several lines, and a wrapped line must not open with a separator.
    @ViewBuilder
    private var metadataRow: some View {
        let countryNames = CountryProvider.displayNames(countries, locale: locale)
        let segments: [String] = [
            runtime.flatMap { $0 > 0 ? $0.runtimeText : nil },
            network.flatMap { $0.isEmpty ? nil : $0 },
            certification.flatMap { $0.isEmpty ? nil : $0 },
            countryNames.isEmpty ? nil : countryNames.joined(separator: " / "),
        ].compactMap { $0 } + extraMetadata
        TooltipFlowLayout(spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                HStack(spacing: 6) {
                    Text(segment).foregroundStyle(.secondary)
                    if idx < segments.count - 1 { SeparatorDot() }
                }
                .fixedSize()
            }
        }
        .scaledFont(size: 11)
    }
}

// MARK: - Poster lightbox

/// The art fades in from many points at once and flows into place; the front refracts it like a glass ridge.
private struct IgniteReveal: ViewModifier, Animatable {
    var progress: CGFloat
    let size: CGSize
    let seed: Float
    let enabled: Bool

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // Off once done: a layer effect rasterises at 1×, which would blur the 5× zoom.
        content.layerEffect(
            ShaderLibrary.bundle(.module).posterIgnite(.float2(size), .float(Float(progress)), .float(seed)),
            maxSampleOffset: CGSize(width: 80, height: 80),
            isEnabled: enabled && progress < 1
        )
    }
}

struct PosterLightbox: View {
    let url: URL
    var apiKey: String?
    /// Width / height of the art: 2:3 for posters, 1:1 for album art.
    var aspectRatio: CGFloat
    let onDismiss: () -> Void

    init(
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

    /// Updated in `.onChanged` (more reliable than `@GestureState` here); `baseZoom`/`baseOffset`
    /// hold the committed value so successive gestures compound.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep: CGFloat = 0
    /// New ignition points on every open.
    @State private var igniteSeed = Float.random(in: 0..<1)
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    #if os(macOS)
    /// The menu-bar NSPanel never receives trackpad `.magnify` events, so macOS gets a slider.
    /// It shares the close button's fade timer so the two pieces of chrome fade together.
    @State private var showsControls = false
    @State private var idleHide: Task<Void, Never>?
    /// A held mouse button stops delivering hover, so the idle timer would otherwise fade the bar mid-drag.
    @State private var isScrubbing = false

    /// Not tied to `showsControls`: it would vanish when the pointer leaves, exactly when you look.
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

    /// Reads the `.full` tier from `PosterStore` instead of re-fetching.
    /// Needs the `files.downloads.read-write` entitlement or the sandbox denies the write.
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
        // *arr artwork is `.../MediaCover/12/poster.jpg`, so the name is thin; never overwrite a previous save.
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

    @State private var scrollMonitor: Any?

    /// A local NSEvent monitor: SwiftUI has no scroll-wheel gesture and an overlaid NSView would
    /// eat tap-to-dismiss. The menu-bar panel delivers scroll even though it never delivers `.magnify`.
    private func startScrollZoom() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Precise (trackpad) deltas are dozens of points per flick; a wheel sends a few coarse clicks.
            let gain = event.hasPreciseScrollingDeltas ? 0.006 : 0.06
            let factor = 1 + event.scrollingDeltaY * gain
            guard factor > 0 else { return nil }
            setZoom(zoom * factor)
            baseZoom = zoom
            if zoom <= 1.01 { offset = .zero; baseOffset = .zero }
            revealControls()
            return nil   // the lightbox owns the surface; nothing below scrolls
        }
    }

    private func stopScrollZoom() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

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

    private func setZoom(_ value: CGFloat) {
        zoom = min(max(value, 1), 5)
    }

    /// Recentre when back at fit, or a pan made while zoomed leaves the poster off-screen.
    private func commitZoom() {
        baseZoom = zoom
        if zoom <= 1.01 {
            withAnimation(.smooth(duration: 0.2)) { offset = .zero; baseOffset = .zero }
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // `.regularMaterial` blurs the popover without going solid black.
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            // No insets: the macOS popover is 400×600, exactly a 2:3 poster.
            GeometryReader { geo in
                let posterW = min(geo.size.width, geo.size.height * aspectRatio)
                let posterH = posterW / aspectRatio
                // Fit, not fill: covering a 2:3 window with square Lidarr art would crop a third of the cover.
                let fullBleed = posterW >= geo.size.width - 0.5 && posterH >= geo.size.height - 0.5
                RemotePoster(
                    url: url,
                    apiKey: apiKey,
                    // The only place that zooms to 5×, so it loads full resolution (memory only, never disk).
                    tier: .full,
                    size: CGSize(width: posterW, height: posterH),
                    cornerRadius: fullBleed ? 0 : Tokens.Radius.panel,
                    fallbackSymbol: "photo"
                )
                .modifier(IgniteReveal(progress: sweep, size: CGSize(width: posterW, height: posterH),
                                       seed: igniteSeed, enabled: !reduceMotion))
                .frame(width: posterW, height: posterH)
                .scaleEffect(zoom)
                .offset(offset)
                .shadow(color: .black.opacity(fullBleed ? 0 : 0.5), radius: 20, y: 8)
                // iOS only; macOS gets the slider and scroll-to-zoom (see `showsControls`).
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
            // Scoped to the poster: the close button below must stay inside the safe area.
            .ignoresSafeArea()

            // Full-bleed art hides every other exit, so an explicit close button (with the Esc shortcut).
            LightboxCloseButton(labelKey: "detail.closePoster.button", action: onDismiss)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #if os(macOS)
            // Stays hit-testable while invisible so the Esc shortcut keeps working. iOS has no pointer to bring it back, so it stays up.
            .opacity(showsControls ? 1 : 0)
            #endif

            #if os(macOS)
            VStack(spacing: 10) {
                if saveOutcome != nil { saveNote }
                zoomBar
                    .opacity(showsControls ? 1 : 0)
                    // An idle bar must not eat clicks meant for tap-to-dismiss.
                    .allowsHitTesting(showsControls)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 16)
            #endif
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { sweep = 1 }
        }
        #if os(macOS)
        .onAppear { startScrollZoom() }
        .onDisappear { stopScrollZoom() }
        #endif
        #if os(macOS)
        // `.onContinuousHover` so a pointer that stops and starts again inside the window brings it back.
        .onContinuousHover { phase in
            switch phase {
            case .active: revealControls()
            // A drag that leaves the window still owns the pointer; don't yank the control mid-drag.
            case .ended where !isScrubbing:
                idleHide?.cancel()
                withAnimation(.smooth(duration: 0.3)) { showsControls = false }
            case .ended: break
            @unknown default: break
            }
        }
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
        .shadow(color: .black.opacity(0.65), radius: 4, y: 1)
        .transition(.opacity)
    }

    private static let zoomBarWidth: CGFloat = 180
    private static let zoomKnob: CGFloat = 12

    /// Hand-drawn: `Slider` paints its filled half in the accent colour, which vanishes over light artwork.
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
        // Padding before the hit shape: a 12pt-tall grab target is too small.
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

struct RatingPill: View {
    let chip: RatingChip
    @Environment(\.locale) private var locale

    var body: some View {
        if let url = chip.url {
            Button { PlatformURLOpener.open(url) } label: {
                pillContent
                    .hoverChipOutline(chip.color, opacity: 0.30,
                                      shape: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: helpText))
            #if os(macOS)
            .pointerStyle(.link)
            #endif
        } else if !helpText.isEmpty {
            pill.help(Text(verbatim: helpText))
        } else {
            pill
        }
    }

    /// nil when the source sent no count or zero (*arr's value for unrated titles).
    private var votesLine: String? {
        guard let votes = chip.votes, votes > 0 else { return nil }
        return String(format: AppLocalized.string("rating.votes.format", locale: locale),
                      votes.formatted(.number.locale(locale)))
    }

    private var helpText: String {
        [chip.siteName, votesLine].compactMap { $0 }.joined(separator: "\n")
    }

    private var pill: some View {
        pillContent.chipOutline(chip.color)
    }

    private var pillContent: some View {
        HStack(spacing: 3) {
            if let iconName = chip.iconName {
                // Non-template so the brand colours show.
                Image(iconName, bundle: .module)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 11)
            } else {
                // Brand names have no catalogue entry and stay as they are; "Rating" is translated.
                Text(LocalizedStringKey(chip.label), bundle: .module)
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(chip.color)
            }
            Text(chip.value)
                .scaledFont(size: 10, weight: .semibold, monospacedDigit: true)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }
}

// MARK: - Poster lightbox presentation

extension View {
    /// Content under an overlay needs all four: a hidden layer still holds pointer regions and tooltips,
    /// hands its I-beam to what is drawn over it, and stays in the accessibility tree.
    func parked(_ isParked: Bool, opacity parkedOpacity: Double = 0) -> some View {
        self.opacity(isParked ? parkedOpacity : 1)
            .allowsHitTesting(!isParked)
            .disabled(isParked)
            .accessibilityHidden(isParked)
    }
}

public extension View {
    /// iOS uses `.fullScreenCover` to cover the nav and tab bars; macOS overlays inside the popover.
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
        // The lightbox is a sibling of the parked content, so its dismiss gestures stay live.
        parked(url.wrappedValue != nil).overlay {
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
