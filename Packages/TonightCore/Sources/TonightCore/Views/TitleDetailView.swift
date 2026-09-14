import SwiftUI
import ArrCore
import MediaKit

/// Rich title page: edge-to-edge backdrop that melts into the window
/// background, all the key facts on the cover, poster on the right.
struct TitleDetailView: View {
    let selection: TitleSelection
    @EnvironmentObject private var config: TonightConfig

    @State private var index: Int
    @State private var details: TitleDetails?
    /// Scores beyond TMDB's own, gathered by MediaKit. They land a moment
    /// after the page does, which is why the strip animates them in.
    @State private var ratings: MediaKit.Ratings?
    /// Owned / watched, gathered from whichever of Radarr, Sonarr and the
    /// media server can speak for this title.
    @State private var availability: Availability?
    @State private var error: String?
    @State private var showTrailer = false
    @State private var showPoster = false
    @State private var expandedReview: TitleDetails.Review?
    /// The clip the trailers row asked for; the Trailer button plays the
    /// best one through the same sheet.
    @State private var playing: TitleDetails.Video?

    init(selection: TitleSelection) {
        self.selection = selection
        _index = State(initialValue: min(max(0, selection.index),
                                         max(0, selection.items.count - 1)))
    }

    /// The title currently shown — previous/next moves through the
    /// collection the user came from.
    private var item: MediaItem { selection.items[index] }

    var body: some View {
        Group {
            if let error, details == nil {
                QuietMessage(systemImage: "wifi.slash",
                             title: String(localized: "Can't load title", bundle: .module),
                             subtitle: error,
                             action: (String(localized: "Retry", bundle: .module),
                                      { Task { await load() } }))
            } else {
                // The hero is drawn from the card the user clicked, before
                // anything is fetched: same artwork, same logo, same place.
                // Only the rows nobody could know yet wait for the payload.
                loaded(details)
            }
        }
        .floatingBackButton()
        .task(id: item.id) { await load() }
        .sheet(isPresented: $showTrailer) {
            if let key = details?.trailerYouTubeKey {
                TrailerSheet(youTubeKey: key, title: item.title)
            }
        }
        .sheet(isPresented: $showPoster) {
            PosterLightbox(url: TitleDetailView.fullPosterURL(details?.item ?? item),
                           title: item.title)
        }
        .sheet(item: $playing) { video in
            TrailerSheet(youTubeKey: video.id, title: video.name.isEmpty ? item.title : video.name)
        }
        .sheet(item: $expandedReview) { review in
            ReviewSheet(review: review, title: item.displayTitle)
        }
    }

    /// Previous/next within the originating collection — chevrons, arrow
    /// keys and horizontal scrolling all land here.
    private func page(_ delta: Int) {
        let target = index + delta
        guard selection.items.indices.contains(target) else { return }
        withAnimation(.easeOut(duration: 0.15)) { index = target }
    }

    private func load() async {
        error = nil
        // Whatever the screen we came from already fetched — Home asks for
        // the same payload to write its marquee — so a click opens a page
        // that is already there instead of a spinner over the same picture.
        details = DetailsCache.shared[item.id]
        ratings = nil
        availability = nil
        let tmdb = TMDBService(apiKey: config.tmdbApiKey, region: config.watchRegion)
        do {
            // Ask for FIELDS, not for services: the graph decides who can
            // answer (Radarr for films, Sonarr for series, the media server
            // for what was actually watched) and merges what comes back.
            async let snapshot = MediaStack.shared.snapshot(
                for: item, fields: [.ratings, .availability])
            let loaded = try await tmdb.details(for: item)
            DetailsCache.shared.store(loaded, for: item.id)
            details = loaded
            let gathered = await snapshot
            ratings = gathered.ratings
            availability = gathered.availability
        } catch {
            self.error = shortDescription(of: error)
        }
    }

    // MARK: - Layout

    private func loaded(_ d: TitleDetails?) -> some View {
        // The sidebar floats over this column as a leading safe-area inset:
        // the backdrop ignores it and spans the whole window, the copy below
        // steps back out by the same width.
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header(d)
                if let d {
                VStack(alignment: .leading, spacing: 28) {
                    if let overview = d.overview, !overview.isEmpty {
                        section("Storyline") {
                            Text(overview)
                                .font(.body)
                                .lineSpacing(3)
                                .frame(maxWidth: 760, alignment: .leading)
                        }
                    }
                    if d.videos.count > 1 { trailersSection(d) }
                    if !d.cast.isEmpty { castShelf(d) }
                    // The episode list is long and is what the page ends on
                    // before the shelves; the trailers and the faces come
                    // first, where a viewer is still deciding.
                    if d.item.type == .tv && !d.seasons.isEmpty {
                        SeasonsSection(show: d.item, seasons: d.seasons)
                    }
                    if !d.recommendations.isEmpty {
                        Shelf(title: String(localized: "More Like This", bundle: .module),
                              items: d.recommendations)
                    }
                    if !d.tmdbLists.isEmpty { listsSection(d) }
                    if !d.reviews.isEmpty { reviewsSection(d) }
                }
                .clearOfSidebar()
                } else {
                    loadingSections
                        .clearOfSidebar()
                }
            }
            // Climbs under the toolbar strip the scroll view reserves, so
            // the backdrop starts at the window's own top edge.
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: [.top, .leading])
        // Ignoring the safe area is not enough on its own: the scroll
        // view still reserves the toolbar's height as a content margin,
        // which left an empty band above the hero.
        .contentMargins(.top, 0, for: .scrollContent)
    }

    /// Full-bleed backdrop. Two gradients: a dark scrim that keeps the white
    /// type readable, and a final fade into the window background so the
    /// image dissolves into the page instead of ending at a hard edge.
    private func header(_ d: TitleDetails?) -> some View {
        // Everything the hero needs before the payload lands comes from the
        // card that was clicked; `d` only fills in the words.
        let shown = d?.item ?? item
        return ZStack(alignment: .bottom) {
            HeroBanner(url: shown.displayBackdropURL ?? shown.displayLargePosterURL, height: 620)
                .overlay(BackdropScrim())
                .heroFade()

            HStack(alignment: .bottom, spacing: 24) {
                // Home has usually already learned the logo for this title;
                // if it has not, hold the space rather than flashing the name
                // in type. The claim is bounded by the poster beside it, so
                // no width cap here.
                HeroCopyBlock(item: shown, fallbackLogo: d?.logoURL,
                              pending: d == nil, tagline: d?.tagline) {
                    factsLine(d, item: shown)
                    scoresLine(d, item: shown)
                    availabilityLine(d)
                        .frame(height: HeroCopy.availabilityHeight, alignment: .leading)
                    buttonsLine(d)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .colorScheme(.dark)
                .foregroundStyle(.white)

                RemoteImage(url: shown.displayLargePosterURL)
                    .frame(width: 225, height: 338)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                    .layoutPriority(1)
                    .onTapGesture { showPoster = true }
                    .pointerStyle(.zoomIn)
            }
            .heroCopyInsets()
        }
        // A horizontal swipe / wheel over the backdrop pages like the
        // chevrons do.
        .overlay(ScrollWheelPager { delta in page(delta) })
        // Previous/next hug the banner's edges, centered on its height —
        // flush enough to stay clear of the text and poster.
        .overlay(alignment: .leading) {
            if selection.items.count > 1 && index > 0 {
                PagingChevron(direction: .previous, arrowKeys: true,
                              help: selection.items[index - 1].displayTitle) { page(-1) }
                    .clearOfSidebar()
                }
        }
        .overlay(alignment: .trailing) {
            if selection.items.count > 1 && index < selection.items.count - 1 {
                PagingChevron(direction: .next, arrowKeys: true,
                              help: selection.items[index + 1].displayTitle) { page(1) }
            }
        }
    }

    /// Scores, flat under the facts: the service's mark in one ink, the
    /// number, and the vote count in brackets, at the size everything else
    /// in the hero is set in. No plate, no corner, no shadow — the scrim
    /// under the hero already carries white type.
    @ViewBuilder
    private func scoresLine(_ d: TitleDetails?, item: MediaItem) -> some View {
        // The card already carries TMDB's score, so the line is written
        // before the payload lands and only grows when IMDb answers.
        let scores = ServiceScore.row(tmdb: d?.rating ?? item.rating,
                                      votes: d?.voteCount ?? item.voteCount,
                                      tmdbURL: d?.tmdbURL,
                                      external: ratings, imdbURL: d?.imdbURL)
            .filter { $0.value != nil }
        if !scores.isEmpty {
            ScoreStrip(scores: scores, style: .inline, showsVotes: true, mono: true)
                .animation(.easeOut(duration: 0.25), value: ratings?.value(for: .imdb))
        }
    }

    /// The meta line: runtime/seasons · genres · the studio's own mark, and
    /// nothing that wears a plate. Scores live in the corner. The studio is
    /// the production company, never the broadcaster — TMDB will happily
    /// answer "network" with whichever station aired the thing.
    private func factsLine(_ d: TitleDetails?, item: MediaItem) -> some View {
        var parts: [String] = []
        // A logo has no year in it, and `displayTitle` is not on screen when
        // one is shown — so the year joins the facts rather than vanishing.
        if (item.logoURL ?? d?.logoURL) != nil, let year = item.year {
            parts.append(String(year))
        }
        if let runtime = d?.runtimeMinutes, runtime > 0 {
            parts.append(Duration.seconds(runtime * 60)
                .formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        }
        if let seasons = d?.seasonCount {
            parts.append(String(format: String(localized: "%d seasons", bundle: .module), seasons))
            if let episodes = d?.episodeCount {
                parts.append(String(format: String(localized: "%d episodes", bundle: .module), episodes))
            }
        }
        let genres = d?.genres ?? []
        if !genres.isEmpty { parts.append(genres.prefix(3).joined(separator: " · ")) }
        // Where it was made sits next to who made it, at the end of the line:
        // the two facts a viewer reads together.
        parts.append(contentsOf: d?.countryNames ?? [])
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .font(.callout.weight(.medium))
                }
                if d == nil { SkeletonBar(width: 260) }
                if let studio = d?.studios.first {
                    if !parts.isEmpty { Text(verbatim: "·").font(.callout).opacity(0.45) }
                    // In words, not in logos: two unlabelled marks in a row
                    // are a guessing game, and the studio is one fact among
                    // the others on this line.
                    Text(verbatim: studio.name)
                        .font(.callout.weight(.medium))
                }
            }
            if let d { creditLine(d) }
        }
        .opacity(0.92)
    }

    /// "Director: Denis Villeneuve ›" — the credit is a way into the person
    /// page, so every name carries the chevron that says so.
    @ViewBuilder
    private func creditLine(_ d: TitleDetails) -> some View {
        let people = d.directors.isEmpty ? d.creators : d.directors
        let label = d.directors.isEmpty
            ? String(localized: "Created by", bundle: .module)
            : String(localized: "Director", bundle: .module)
        if !people.isEmpty {
            HStack(spacing: 8) {
                Text("\(label):")
                ForEach(people) { person in
                    NavigationLink(value: PersonRef(id: person.id, name: person.name)) {
                        HStack(spacing: 1) {
                            Text(person.name)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .opacity(0.75)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                }
            }
            .font(.callout)
            .opacity(0.8)
        }
    }

    /// Where you can watch it: the services streaming it, and — the question
    /// the app exists to answer — which of the configured libraries actually
    /// has it.
    @ViewBuilder
    private func availabilityLine(_ d: TitleDetails?) -> some View {
        let libraries = librarySources
        let providers = d?.streamingProviders ?? []
        if !providers.isEmpty || !libraries.isEmpty {
            HStack(spacing: 12) {
                if !providers.isEmpty {
                    HStack(spacing: 6) {
                        Text("Watch", bundle: .module)
                            .font(.system(size: 9, weight: .semibold))
                            .textCase(.uppercase)
                            .opacity(0.55)
                        ForEach(providers) { provider in
                            // No link: the only URL TMDB gives is its own
                            // "where to watch" page, and a mark that says
                            // Netflix must open Netflix or nothing.
                            BrandLogo(name: provider.name, url: provider.logoURL, height: 22)
                        }
                    }
                }
                if !providers.isEmpty && !libraries.isEmpty {
                    Rectangle()
                        .fill(.white.opacity(0.25))
                        .frame(width: 1, height: 16)
                }
                if !libraries.isEmpty {
                    Text("Own", bundle: .module)
                        .font(.system(size: 9, weight: .semibold))
                        .textCase(.uppercase)
                        .opacity(0.55)
                }
                ForEach(libraries, id: \.name) { source in
                    libraryMark(source)
                }
            }
            .animation(.easeOut(duration: 0.25), value: availability?.sources)
        }
    }

    /// One configured library and its answer. Not a list of the arrs: every
    /// service that was asked says yes or no here, because "it is in Plex but
    /// not in Radarr" is the useful sentence, and a chip that only ever names
    /// the winners cannot write it.
    private struct LibrarySource {
        enum State { case downloaded, inLibrary, missing }
        let name: String
        let state: State
        let isMediaServer: Bool

        var present: Bool { state != .missing }
    }

    private var librarySources: [LibrarySource] {
        guard let availability else { return [] }
        let server = ArrBarrProfile.mediaServerConfig()?.kind.displayName
        return availability.sources.map {
            LibrarySource(name: $0,
                          state: availability.downloaded.contains($0) ? .downloaded : .inLibrary,
                          isMediaServer: $0 == server)
        } + availability.absent.map {
            LibrarySource(name: $0, state: .missing, isMediaServer: $0 == server)
        }
    }

    /// Where clicking the mark goes: the arrs hand back their own page (or
    /// their add-a-title search when they do not have it), the media server
    /// gets a search on its web app.
    private func libraryURL(_ source: LibrarySource) -> URL? {
        if let link = availability?.links[source.name] { return link }
        return ExternalLibraryStore.mediaServerWebURL(title: item.title)
    }

    private func libraryMark(_ source: LibrarySource) -> some View {
        // The mark alone cannot say whether the file is there — every one of
        // them is drawn in the same white — so the state is a word next to
        // it, in ArrBarr's outlined state chip: green when the file is on
        // disk, accent when the service merely knows the title.
        let state: (word: LocalizedStringKey, tint: Color)? = switch source.state {
        case .downloaded: ("Downloaded", .green)
        case .inLibrary: ("In library", Color(nsColor: .controlAccentColor))
        case .missing: ("Missing", .white)
        }
        return HStack(spacing: 5) {
            BrandMark(name: source.name.lowercased(), height: 14,
                      fallbackSymbol: "internaldrive.fill", fallbackTint: .white)
            Text(verbatim: source.name)
                .font(.caption.weight(.medium))
            // A media server has the file or it is not listed at all — the
            // two arr states (knows about it / has it) are the arrs' own
            // distinction, and spelling one out next to Plex says nothing.
            if let state, !source.isMediaServer {
                Text(state.word, bundle: .module)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(state.tint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(state.tint.opacity(0.55), lineWidth: 1)
                    )
            }
        }
        // A service that does not have it steps back; the one that does is
        // at full strength.
        .opacity(source.present ? 0.95 : 0.4)
        .modifier(LinkChip(url: libraryURL(source)))
        .help(Text(String(format: String(localized: source.present
                                         ? "In %@" : "Not in %@", bundle: .module),
                          source.name)))
    }

    private func buttonsLine(_ d: TitleDetails?) -> some View {
        HStack(spacing: 10) {
            Button {
                showTrailer = true
            } label: {
                Label {
                    Text("Trailer", bundle: .module)
                } icon: {
                    BrandMark(name: "youtube", height: 13, fallbackSymbol: "play.fill",
                              fallbackTint: .white)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.25))
            .disabled(d?.trailerYouTubeKey == nil)

            AddToListMenu(item: d?.item ?? item)
                .menuStyle(.borderedButton)
                .fixedSize()

            WatchedToggle(item: d?.item ?? item, compact: true)
                .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .padding(.top, 6)
    }

    /// The shape of the page while it loads: a storyline paragraph and a row
    /// of cast circles, in their own places.
    private var loadingSections: some View {
        VStack(alignment: .leading, spacing: 28) {
            section("Storyline") {
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBar(width: 700)
                    SkeletonBar(width: 640)
                    SkeletonBar(width: 380)
                }
            }
            section("Cast") {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(0..<8, id: \.self) { _ in
                        VStack(spacing: 6) {
                            SkeletonBar(width: 84, height: 84, radius: 42)
                            SkeletonBar(width: 70, height: 10)
                            SkeletonBar(width: 50, height: 9)
                        }
                        .frame(width: 100)
                    }
                }
            }
        }
    }

    /// Every clip TMDB has, as wide stills — the same shape as a backdrop
    /// card, because that is what a trailer thumbnail is.
    private func trailersSection(_ d: TitleDetails) -> some View {
        section("Trailers") {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(d.videos) { video in
                        Button { playing = video } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack {
                                    RemoteImage(url: video.thumbnailURL)
                                        .frame(width: 260, height: 146)
                                        .clipShape(RoundedRectangle(cornerRadius: 10,
                                                                    style: .continuous))
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 34))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .shadow(color: .black.opacity(0.5), radius: 6)
                                }
                                Text(video.name)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                if let kind = video.kind {
                                    Text(verbatim: kind)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 260, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func castShelf(_ d: TitleDetails) -> some View {
        section("Cast") {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(d.cast) { member in
                        NavigationLink(value: PersonRef(id: member.id, name: member.name)) {
                            VStack(spacing: 6) {
                                RemoteImage(url: member.photoURL)
                                    .frame(width: 84, height: 84)
                                    .clipShape(Circle())
                                Text(member.name)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(2)
                                if let character = member.character, !character.isEmpty {
                                    Text(character)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(width: 100)
                            .multilineTextAlignment(.center)
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func listsSection(_ d: TitleDetails) -> some View {
        section("Featured in Lists") {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(d.tmdbLists) { list in
                        NavigationLink(value: list) {
                            HStack(spacing: 6) {
                                BrandMark(name: "tmdb", height: 9)
                                Text(list.name)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text(String(list.itemCount))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func reviewsSection(_ d: TitleDetails) -> some View {
        section("Reviews") {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(d.reviews) { review in
                        Button {
                            expandedReview = review
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(review.author)
                                        .font(.callout.weight(.semibold))
                                    Spacer()
                                    if let rating = review.rating {
                                        ScoreStrip(scores: ServiceScore.row(tmdb: rating),
                                                   style: .inline)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(review.content)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(9)
                                Text("Read more", bundle: .module)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(16)
                            .frame(width: 360, alignment: .topLeading)
                            .background(.quaternary.opacity(0.5),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func section(_ key: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(key, bundle: .module)
                .font(.title3.weight(.semibold))
            content()
        }
        .padding(.horizontal, 28)
    }
}

/// Full review in a scrollable sheet — the shelf cards clamp long texts.
private struct ReviewSheet: View {
    let review: TitleDetails.Review
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(review.author)
                        .font(.headline)
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let rating = review.rating {
                    ScoreStrip(scores: ServiceScore.row(tmdb: rating), style: .inline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            ScrollView {
                Text(review.content)
                    .font(.callout)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button { dismiss() } label: { Text("Close", bundle: .module) }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 500)
    }
}

extension TitleDetailView {
    @MainActor
    static func fullPosterURL(_ item: MediaItem) -> URL? {
        // The server's copy when it has one — clicking a poster must open the
        // poster you clicked, not TMDB's different one. Otherwise the biggest
        // TMDB rendition that is still a sane download.
        ExternalLibraryStore.shared.posterURL(for: item)
            ?? item.posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w780\($0)") }
    }
}
