import os
import SwiftUI
import MediaKit

/// One "Did you know that…" shown while the indexers answer a manual search.
nonisolated struct WaitStory: Identifiable, Hashable, Sendable {
    struct Person: Hashable, Sendable {
        let name: String
        let imageURL: URL?
        /// The character played; nil for crew, whose card has no "as …" line.
        var role: String? = nil
        /// Present → the face opens the person card on hover.
        var tmdbPersonId: Int? = nil

        init(name: String, imageURL: URL?, role: String? = nil, tmdbPersonId: Int? = nil) {
            self.name = name; self.imageURL = imageURL; self.role = role; self.tmdbPersonId = tmdbPersonId
        }

        init(_ member: CastMember, asCrew: Bool = false) {
            self.init(name: member.name, imageURL: member.imageURL,
                      role: asCrew ? nil : member.role, tmdbPersonId: member.tmdbPersonId)
        }
    }
    let sentence: String
    var people: [Person] = []
    var id: String { sentence }
}

/// Values the pushing detail screen already holds; the provider only adds cache-first TMDB reads.
struct WaitCardContext {
    var movie: ArrMovie? = nil
    var series: ArrSeries? = nil
    var album: ArrAlbum? = nil
    var seriesYear: Int? = nil
    var cast: [CastMember] = []
    var directors: [CastMember] = []
    var posterURL: URL? = nil
    /// The arr's key when `posterURL` points at the arr itself.
    var posterApiKey: String? = nil

    var poster: WaitPoster { WaitPoster(url: posterURL, apiKey: posterApiKey) }

    var title: String {
        movie?.title ?? series?.title ?? album?.title ?? ""
    }
    var year: Int? {
        movie?.year ?? series?.year ?? album?.releaseDate.flatMap { Int($0.prefix(4)) } ?? seriesYear
    }
}

/// A missing fact means a missing story, never an error or a blank.
enum WaitStoryProvider {
    /// Stories that need no network, ready on first render.
    static func localStories(_ ctx: WaitCardContext) -> [WaitStory] {
        var stories: [WaitStory] = []
        let title = ctx.title
        guard !title.isEmpty else { return [] }
        if let years = yearsAgo(ctx.year) {
            let by = ctx.movie?.studio ?? ctx.series?.network ?? ctx.album?.artist?.artistName
            let sentence = by.map { L("wait.story.premiereBy \(title) \(years) \($0)") } ?? L("wait.story.premiere \(title) \(years)")
            stories.append(WaitStory(sentence: sentence))
        }
        let faces = ctx.cast.filter { $0.imageURL != nil }.prefix(3)
        if faces.count >= 2, let director = ctx.directors.first {
            let names = faces.map { "**\($0.name)**" }.joined(separator: ", ")
            stories.append(WaitStory(sentence: L("wait.story.directedStarring \(director.name) \(names)"),
                                     people: [.init(director, asCrew: true)] + faces.map { .init($0) }))
        }
        return stories
    }

    static func remoteStories(_ ctx: WaitCardContext, configStore: ConfigStore) async -> [WaitStory] {
        guard !configStore.tmdbApiKey.isEmpty, !ctx.title.isEmpty else { return [] }
        let client = configStore.tmdbClient
        // TMDB's text in the app's language; a tagline it has no translation for comes back empty and drops out.
        let language = configStore.currentLocale.identifier(.bcp47)
        var stories: [WaitStory] = []
        let title = ctx.title

        var owned: [Int: String] = [:]
        if ctx.movie != nil, configStore.radarr.isConfigured {
            let library = await LibraryIndex.shared.movies(config: configStore.radarr, revalidate: false)
            owned = Dictionary(library.compactMap { r in r.tmdbId.map { ($0, r.title) } }, uniquingKeysWith: { a, _ in a })
        }

        if let m = ctx.movie, let id = m.tmdbId, id > 0 {
            let facts = await Logger.extras.attempt("wait facts") { try await client.movieDetails(movieId: id, language: language) }
            let crew = (await Logger.extras.attempt("wait crew") { try await client.movieCredits(movieId: id) })?.crew ?? []
            let writer = crew.first { $0.job == "Screenplay" || $0.job == "Writer" }
            let dop = crew.first { $0.job == "Director of Photography" }

            if let f = facts, let budget = f.budget, let revenue = f.revenue, budget > 0, revenue > 0 {
                let money = Decimal.FormatStyle.Currency(code: "USD").notation(.compactName).precision(.significantDigits(2...3))
                stories.append(WaitStory(sentence: L("wait.story.money \(title) \(Decimal(budget).formatted(money)) \(Decimal(revenue).formatted(money))")))
            }
            if let writer, let dop {
                stories.append(WaitStory(sentence: L("wait.story.crew \(writer.name) \(dop.name)"),
                                         people: [.init(name: writer.name, imageURL: writer.profileURL), .init(name: dop.name, imageURL: dop.profileURL)]))
            } else if let f = facts, let tagline = f.tagline, !tagline.isEmpty {
                stories.append(WaitStory(sentence: L("wait.story.taglineOnly \(title) \(tagline)")))
            }
            if let picks = await Logger.extras.attempt("wait recommendations", { try await client.recommendedMovies(movieId: id, language: language) }), picks.count >= 2 {
                let a = picks[0], b = picks[1]
                stories.append(WaitStory(sentence: L("wait.story.alsoWatch \(title) \(a.title) \(b.title)")))
            }
        } else if let s = ctx.series, let id = await client.seriesId(tmdbId: s.tmdbId, tvdbId: s.tvdbId) {
            if let f = await Logger.extras.attempt("wait series facts", { try await client.tvDetails(tvId: id, language: language) }), let seasons = f.numberOfSeasons, let episodes = f.numberOfEpisodes,
               seasons > 0, let years = yearsAgo(s.year) {
                stories.append(WaitStory(sentence: L("wait.story.series \(title) \(Self.seasons(seasons)) \(Self.episodes(episodes)) \(years)")))
            }
        }

        stories += await peopleStories(ctx, client: client, owned: owned, language: language)
        return stories.shuffled()
    }

    // MARK: - People

    private static func peopleStories(_ ctx: WaitCardContext, client: TMDBClient, owned: [Int: String], language: String) async -> [WaitStory] {
        let people = ctx.cast.filter { ($0.tmdbPersonId ?? 0) > 0 }.prefix(5)
        var stories: [WaitStory] = []
        let today = Calendar.current.dateComponents([.month, .day], from: .now)

        for person in people {
            guard let personId = person.tmdbPersonId else { continue }
            let details = await Logger.extras.attempt("wait person") { try await client.personDetails(personId: personId) }
            let credits = await Logger.extras.attempt("wait person credits") { try await client.personMovieCredits(personId: personId, language: language) }
            let portrait = WaitStory.Person(name: person.name, imageURL: details?.profileURL ?? person.imageURL,
                                            role: person.role, tmdbPersonId: personId)
            let others = (credits?.cast ?? []).filter { $0.id != ctx.movie?.tmdbId && ($0.voteCount ?? 0) >= 100 }
            let hit = others.max { ($0.voteCount ?? 0) < ($1.voteCount ?? 0) }

            var birthdayToday = false
            if let d = details, d.deathday == nil, let birthday = d.birthday, let born = date(birthday) {
                let parts = Calendar.current.dateComponents([.month, .day], from: born)
                birthdayToday = parts.month == today.month && parts.day == today.day
            }
            if birthdayToday, let age = details?.age {
                let ageText = Self.age(age)
                let sentence = person.role.map { L("wait.story.birthdayRole \(person.name) \($0) \(ageText)") } ?? L("wait.story.birthday \(person.name) \(ageText)")
                stories.append(WaitStory(sentence: sentence, people: [portrait]))
            } else if let place = details?.placeOfBirth, !place.isEmpty {
                let sentence = person.role.map { L("wait.story.bornRole \(person.name) \($0) \(place)") } ?? L("wait.story.born \(person.name) \(place)")
                stories.append(WaitStory(sentence: sentence, people: [portrait]))
            } else if let hit {
                let sentence = L("wait.story.knownForSentence \(person.name) \(hit.title)")
                stories.append(WaitStory(sentence: sentence, people: [portrait]))
            }

            if !owned.isEmpty,
               let other = others.filter({ owned[$0.id] != nil }).max(by: { ($0.voteCount ?? 0) < ($1.voteCount ?? 0) }),
               let otherTitle = owned[other.id] {
                stories.append(WaitStory(sentence: L("wait.story.library \(person.name) \(otherTitle)"),
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

    private static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)
    }
}

// MARK: - Surface

/// The wait screen for a manual search: the title's cover at the centre of the fan, a "Did you know" under it.
struct WaitStories: View {
    let context: WaitCardContext

    @EnvironmentObject private var configStore: ConfigStore
    @State private var stories: [WaitStory] = []

    var body: some View {
        WaitStage(covers: [context.poster], stories: stories) {
            LoadingStateView(label: "wait.releases.heading")
        }
        .task {
            stories = WaitStoryProvider.localStories(context).shuffled()
            let remote = await WaitStoryProvider.remoteStories(context, configStore: configStore)
            stories = (stories + remote).shuffled()
        }
    }
}
