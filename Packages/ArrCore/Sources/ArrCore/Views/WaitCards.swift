import SwiftUI

/// One "Did you know that…" while the indexers answer a manual search: a
/// sentence in markdown (bold marks names and numbers), an optional second
/// sentence, and the portraits of the people it talks about.
nonisolated struct WaitStory: Identifiable, Hashable, Sendable {
    struct Person: Hashable, Sendable {
        let name: String
        let imageURL: URL?
    }
    let sentence: String
    var support: String? = nil
    var people: [Person] = []
    var id: String { sentence }
}

/// What the pushing detail screen already knows about the title. Everything
/// here is a value it holds; the provider only adds cache-first TMDB reads.
struct WaitCardContext {
    var movie: RadarrMovieDetail? = nil
    var series: SonarrSeriesDetail? = nil
    var album: LidarrAlbumDetail? = nil
    var seriesYear: Int? = nil
    var cast: [CastMember] = []
    var directors: [CastMember] = []
    var posterURL: URL? = nil
    /// The arr's key when `posterURL` points at the arr itself.
    var posterApiKey: String? = nil

    var title: String {
        movie?.title ?? series?.title ?? album?.title ?? ""
    }
    var year: Int? {
        movie?.year ?? series?.year ?? album?.releaseDate.flatMap { Int($0.prefix(4)) } ?? seriesYear
    }
}

/// Composes stories from templates. Every fact comes from the records in hand
/// or a cache-first TMDB read; a missing fact means a missing story, never an
/// error or a blank.
enum WaitStoryProvider {
    /// Stories that need no network, ready on first render.
    static func localStories(_ ctx: WaitCardContext, locale: Locale = .current) -> [WaitStory] {
        var stories: [WaitStory] = []
        let title = ctx.title
        guard !title.isEmpty else { return [] }
        let rating = ctx.movie?.ratings?.tmdb?.value ?? ctx.movie?.ratings?.imdb?.value ?? ctx.series?.ratings?.value
        if let rating, rating > 0 {
            let score = rating.formatted(.number.precision(.fractionLength(1)))
            var support: String?
            if let genres = ctx.movie?.genres ?? ctx.series?.genres, !genres.isEmpty {
                support = L("wait.story.genres \(genres.prefix(3).map { GenreName.localized($0, locale: locale) }.joined(separator: ", "))")
            }
            stories.append(WaitStory(sentence: L("wait.story.rated \(title) \(score)"), support: support))
        }
        if let years = yearsAgo(ctx.year) {
            let by = ctx.movie?.studio ?? ctx.series?.network ?? ctx.album?.artist?.artistName
            let sentence = by.map { L("wait.story.premiereBy \(title) \(years) \($0)") } ?? L("wait.story.premiere \(title) \(years)")
            let minutes = ctx.movie?.runtime ?? ctx.series?.runtime ?? ctx.album?.duration.map { $0 / 60_000 }
            stories.append(WaitStory(sentence: sentence, support: runtime(minutes, perEpisode: ctx.series != nil)))
        }
        let faces = ctx.cast.filter { $0.imageURL != nil }.prefix(3)
        if faces.count >= 2, let director = ctx.directors.first {
            let names = faces.map { "**\($0.name)**" }.joined(separator: ", ")
            stories.append(WaitStory(sentence: L("wait.story.directedStarring \(director.name) \(names)"),
                                     people: [.init(name: director.name, imageURL: director.imageURL)] + faces.map { .init(name: $0.name, imageURL: $0.imageURL) }))
        }
        return stories
    }

    /// Stories from TMDB, shuffled so a long wait on the same title reads
    /// differently each time.
    static func remoteStories(_ ctx: WaitCardContext, configStore: ConfigStore) async -> [WaitStory] {
        let key = configStore.tmdbApiKey
        guard !key.isEmpty, !ctx.title.isEmpty else { return [] }
        let client = TMDBClient(apiKey: key)
        var stories: [WaitStory] = []
        let title = ctx.title

        var owned: [Int: String] = [:]
        if ctx.movie != nil, configStore.radarr.isConfigured {
            let library = await LibraryIndex.shared.movies(config: configStore.radarr, revalidate: false)
            owned = Dictionary(library.compactMap { r in
                if let id = r.tmdbId, let t = r.title { return (id, t) } else { return nil }
            }, uniquingKeysWith: { a, _ in a })
        }

        if let m = ctx.movie, let id = m.tmdbId, id > 0 {
            let facts = try? await client.movieFacts(movieId: id)
            let crew = (try? await client.movieCredits(movieId: id))?.crew ?? []
            let composer = crew.first { $0.job == "Original Music Composer" }
            let writer = crew.first { $0.job == "Screenplay" || $0.job == "Writer" }
            let dop = crew.first { $0.job == "Director of Photography" }

            if let f = facts, let budget = f.budget, let revenue = f.revenue, budget > 0, revenue > 0 {
                let money = Decimal.FormatStyle.Currency(code: "USD").notation(.compactName).precision(.significantDigits(2...3))
                let sentence = L("wait.story.money \(title) \(Decimal(budget).formatted(money)) \(Decimal(revenue).formatted(money))")
                var support: String?
                if let years = yearsAgo(m.year) {
                    support = composer.map { L("wait.story.premiereComposer \(years) \($0.name)") } ?? L("wait.story.premiereShort \(years)")
                }
                stories.append(WaitStory(sentence: sentence, support: support,
                                         people: composer.map { [.init(name: $0.name, imageURL: $0.posterURL)] } ?? []))
            }
            if let writer, let dop {
                stories.append(WaitStory(sentence: L("wait.story.crew \(writer.name) \(dop.name)"),
                                         support: facts?.tagline.flatMap { $0.isEmpty ? nil : L("wait.story.tagline \($0)") },
                                         people: [.init(name: writer.name, imageURL: writer.posterURL), .init(name: dop.name, imageURL: dop.posterURL)]))
            } else if let f = facts, let tagline = f.tagline, !tagline.isEmpty {
                stories.append(WaitStory(sentence: L("wait.story.taglineOnly \(title) \(tagline)"),
                                         support: f.originalTitle.flatMap { $0 == m.title || $0.isEmpty ? nil : L("wait.story.originalTitle \($0)") }))
            }
            if let picks = try? await client.recommendedMovies(movieId: id), picks.count >= 2 {
                let a = picks[0], b = picks[1]
                let ownedPick = picks.prefix(4).first { owned[$0.id] != nil }
                stories.append(WaitStory(sentence: L("wait.story.alsoWatch \(title) \(a.title) \(b.title)"),
                                         support: ownedPick.map { L("wait.story.alsoOwned \($0.title)") }))
            }
        } else if let s = ctx.series, let id = await seriesTMDBId(s, client: client) {
            if let f = try? await client.tvFacts(tvId: id), let seasons = f.numberOfSeasons, let episodes = f.numberOfEpisodes,
               seasons > 0, let years = yearsAgo(s.year) {
                let sentence = L("wait.story.series \(title) \(Self.seasons(seasons)) \(Self.episodes(episodes)) \(years)")
                let support = s.network.map { L("wait.story.network \($0)") } ?? f.tagline.flatMap { $0.isEmpty ? nil : L("wait.story.tagline \($0)") }
                stories.append(WaitStory(sentence: sentence, support: support))
            }
        }

        stories += await peopleStories(ctx, client: client, owned: owned)
        return stories.shuffled()
    }

    // MARK: - People

    private static func peopleStories(_ ctx: WaitCardContext, client: TMDBClient, owned: [Int: String]) async -> [WaitStory] {
        let people = ctx.cast.filter { ($0.tmdbPersonId ?? 0) > 0 }.prefix(5)
        var stories: [WaitStory] = []
        let today = Calendar.current.dateComponents([.month, .day], from: .now)

        for person in people {
            guard let personId = person.tmdbPersonId else { continue }
            let details = try? await client.personDetails(personId: personId)
            let credits = try? await client.personMovieCredits(personId: personId)
            let portrait = WaitStory.Person(name: person.name, imageURL: details?.profileURL ?? person.imageURL)
            let others = (credits?.cast ?? []).filter { $0.id != ctx.movie?.tmdbId && ($0.voteCount ?? 0) >= 100 }
            let hit = others.max { ($0.voteCount ?? 0) < ($1.voteCount ?? 0) }
            let hitSupport = hit.map { h in
                h.year.map { L("wait.story.knownForYear \(h.title) \($0)") } ?? L("wait.story.knownFor \(h.title)")
            }

            var birthdayToday = false
            if let d = details, d.deathday == nil, let birthday = d.birthday, let born = date(birthday) {
                let parts = Calendar.current.dateComponents([.month, .day], from: born)
                birthdayToday = parts.month == today.month && parts.day == today.day
            }
            if birthdayToday, let age = details?.age {
                let ageText = Self.age(age)
                let sentence = person.role.map { L("wait.story.birthdayRole \(person.name) \($0) \(ageText)") } ?? L("wait.story.birthday \(person.name) \(ageText)")
                stories.append(WaitStory(sentence: sentence, support: hitSupport, people: [portrait]))
            } else if let place = details?.placeOfBirth, !place.isEmpty {
                let sentence = person.role.map { L("wait.story.bornRole \(person.name) \($0) \(place)") } ?? L("wait.story.born \(person.name) \(place)")
                stories.append(WaitStory(sentence: sentence, support: hitSupport, people: [portrait]))
            } else if let hit {
                let sentence = L("wait.story.knownForSentence \(person.name) \(hit.title)")
                stories.append(WaitStory(sentence: sentence, people: [portrait]))
            }

            if !owned.isEmpty,
               let other = others.filter({ owned[$0.id] != nil }).max(by: { ($0.voteCount ?? 0) < ($1.voteCount ?? 0) }),
               let otherTitle = owned[other.id] {
                let watched = MediaServerIndex.shared.isWatched([.tmdb(other.id)])
                stories.append(WaitStory(sentence: L("wait.story.library \(person.name) \(otherTitle)"),
                                         support: L(watched ? "wait.story.watched" : "wait.story.notWatched"),
                                         people: [portrait]))
            }
        }
        return stories
    }

    // MARK: - Pieces

    private static func L(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }

    private static func age(_ n: Int) -> String { L("wait.card.age \(n)") }
    private static func seasons(_ n: Int) -> String { L("wait.frag.seasons \(n)") }
    private static func episodes(_ n: Int) -> String { L("wait.frag.episodes \(n)") }

    private static func yearsAgo(_ year: Int?, now: Date = .now) -> String? {
        guard let year else { return nil }
        let age = Calendar.current.component(.year, from: now) - year
        guard age >= 1 else { return nil }
        return String(localized: "wait.frag.yearsAgo \(age)", bundle: .module)
    }

    private static func runtime(_ minutes: Int?, perEpisode: Bool) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let length = Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return perEpisode ? L("wait.story.episodeRuntime \(length)") : L("wait.story.runtime \(length)")
    }

    private static func seriesTMDBId(_ s: SonarrSeriesDetail, client: TMDBClient) async -> Int? {
        if let id = s.tmdbId, id > 0 { return id }
        guard let tvdb = s.tvdbId, tvdb > 0 else { return nil }
        return try? await client.tvIdFromTVDB(tvdb)
    }

    private static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)
    }
}

// MARK: - Surface

/// The wait screen for a manual search: the poster, large and tilted, beside
/// a "Did you know that…" sentence, on a flat ground in the poster's
/// own colour. Stories come in random order and rotate every few seconds;
/// click the right side to skip ahead, the left to go back. A spinner sits at
/// the foot, so the wait itself is never hidden.
struct WaitStories: View {
    let context: WaitCardContext
    var interval: TimeInterval = 7

    @EnvironmentObject private var configStore: ConfigStore
    @State private var stories: [WaitStory] = []
    @State private var index = 0
    @State private var forward = true
    @State private var tint: Color?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ground
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(alignment: .top, spacing: 18) {
                        poster
                        if !stories.isEmpty {
                            let story = stories[index % stories.count]
                            StoryText(story: story)
                                .id(story.id)
                                .transition(.asymmetric(
                                    insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                    removal: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                    footer
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in
                advance(point.x < proxy.size.width / 3 ? -1 : 1)
            }
        }
        .environment(\.colorScheme, .dark)
        .task {
            stories = WaitStoryProvider.localStories(context, locale: configStore.currentLocale).shuffled()
            async let color = PosterTint.color(for: context.posterURL)
            let remote = await WaitStoryProvider.remoteStories(context, configStore: configStore)
            // The story on screen stays put; everything after it is reshuffled with the new ones.
            let current = stories.isEmpty ? [] : [stories[index % stories.count]]
            let rest = (stories.filter { !current.contains($0) } + remote).shuffled()
            index = 0
            stories = current + rest
            tint = await color
        }
        .task(id: index) {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, stories.count > 1 else { return }
            advance(1)
        }
    }

    private func advance(_ step: Int) {
        guard stories.count > 1 else { return }
        forward = step > 0
        withAnimation(.snappy(duration: 0.4)) {
            index = (index + step + stories.count) % stories.count
        }
    }

    /// The poster's colour, pulled down to a ground that white text sits on.
    private var ground: some View {
        ZStack {
            Color(white: 0.08)
            (tint ?? .clear).opacity(0.55)
            LinearGradient(colors: [.white.opacity(0.06), .clear, .black.opacity(0.25)],
                           startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.6), value: tint)
        .ignoresSafeArea()
    }

    private var poster: some View {
        RemotePoster(url: context.posterURL, apiKey: context.posterApiKey, tier: .card,
                     size: CGSize(width: 112, height: 168), cornerRadius: 8, fallbackSymbol: "film")
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1))
            .rotationEffect(.degrees(-3))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 12)
            .padding(.top, 6)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("wait.releases.heading", bundle: .module)
                .scaledFont(size: 12)
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StoryText: View {
    let story: WaitStory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("wait.story.lead", bundle: .module)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)
                .kerning(0.9)
            Text(markdown(story.sentence))
                .scaledFont(size: 17, weight: .regular)
                .foregroundStyle(.white)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let support = story.support {
                Text(markdown(support))
                    .scaledFont(size: 13)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !story.people.isEmpty {
                HStack(spacing: -10) {
                    ForEach(Array(story.people.prefix(4).enumerated()), id: \.offset) { _, person in
                        RemotePoster(url: person.imageURL, apiKey: nil, tier: .icon,
                                     size: CGSize(width: 34, height: 34), cornerRadius: 17,
                                     fallbackSymbol: "person.fill")
                            .overlay(Circle().strokeBorder(.white.opacity(0.75), lineWidth: 1.5))
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
