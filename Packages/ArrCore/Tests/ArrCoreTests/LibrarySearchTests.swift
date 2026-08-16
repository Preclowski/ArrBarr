import Testing
import Foundation
@testable import ArrCore

@Suite("Title matching")
struct TitleMatchTests {

    @Test("Normalization folds accents, punctuation and a leading article")
    func normalizationFolds() {
        #expect(TitleMatch.normalize("Amélie") == "amelie")
        #expect(TitleMatch.normalize("WALL·E") == "wall e")
        #expect(TitleMatch.normalize("The Godfather") == "godfather")
        // A one-token title that IS an article keeps it — otherwise it
        // normalizes to nothing and matches everything.
        #expect(TitleMatch.normalize("The") == "the")
    }

    @Test("The ways a person actually types a title they own all match")
    func humanTypingMatches() {
        let title = TitleMatch.normalize("The Godfather")
        for typed in ["godfather", "The Godfather", "godfathr", "GODFATHER"] {
            #expect(TitleMatch.score(query: TitleMatch.normalize(typed), title: title) != nil,
                    "'\(typed)' should match")
        }
        #expect(TitleMatch.score(query: TitleMatch.normalize("goodfellas"), title: title) == nil)
    }

    @Test("Token prefixes match, so a half-remembered title still lands")
    func tokenPrefixMatches() {
        let title = TitleMatch.normalize("The Matrix Reloaded")
        #expect(TitleMatch.score(query: TitleMatch.normalize("matrix reload"), title: title) != nil)
    }

    @Test("Edit distance abandons early instead of matching anything")
    func editDistanceIsBounded() {
        #expect(TitleMatch.editDistance("dune", "dune", limit: 2) == 0)
        #expect(TitleMatch.editDistance("dune", "duna", limit: 2) == 1)
        #expect(TitleMatch.editDistance("dune", "casablanca", limit: 2) > 2)
    }

    @Test("A year decides between remakes")
    func yearDisambiguatesRemakes() {
        let candidates = [("Dune", 1984), ("Dune", 2021)]
        let hit = TitleMatch.best(query: "Dune", year: 2021, candidates: candidates,
                                  title: { $0.0 }, year: { $0.1 })
        #expect(hit?.1 == 2021)
        let older = TitleMatch.best(query: "Dune", year: 1984, candidates: candidates,
                                    title: { $0.0 }, year: { $0.1 })
        #expect(older?.1 == 1984)
    }
}

@Suite("Library filtering")
struct LibraryFilterTests {

    private func movie(_ title: String, _ year: Int, _ genres: [String],
                       rating: Double? = 7.0) -> RadarrLibraryRecord {
        RadarrLibraryRecord(
            id: abs(title.hashValue % 10_000), tmdbId: nil, title: title, year: year,
            hasFile: true, titleSlug: nil, monitored: true, images: nil,
            genres: genres, runtime: 100, overview: nil,
            ratings: rating.map {
                RadarrLookupRatings(tmdb: RadarrLookupRatingValue(value: $0, votes: 1000),
                                    imdb: nil, metacritic: nil, rottenTomatoes: nil)
            },
            certification: nil, studio: nil, sizeOnDisk: nil
        )
    }

    /// The prompt this whole design was stress-tested against: "romantic, not a
    /// drama, essence of the 90s". Genre + decade is what the model cannot
    /// derive on its own; "not a drama" and "atmospheric" it decides itself
    /// from the rows, which is why both stay out of the filter.
    @Test("Genre and a decade narrow the shelf; the taste call stays with the model")
    func genreAndDecadeNarrow() {
        let library = [
            movie("Before Sunrise", 1995, ["Drama", "Romance"]),
            movie("Chungking Express", 1994, ["Drama", "Romance", "Comedy"]),
            movie("Heat", 1995, ["Action", "Crime"]),
            movie("Amélie", 2001, ["Comedy", "Romance"]),
        ]
        let query = LibraryQuery(genre: "romance", startYear: 1990, endYear: 1999)
        let hits = LibraryFilter.apply(library, query: query) { _ in false }
        #expect(hits.map(\.filterTitle).sorted() == ["Before Sunrise", "Chungking Express"])
    }

    @Test("unwatched drops what the media server says was seen")
    func unwatchedFilters() {
        let library = [movie("Heat", 1995, ["Crime"]), movie("Casino", 1995, ["Crime"])]
        let hits = LibraryFilter.apply(library, query: LibraryQuery(unwatchedOnly: true)) {
            $0.filterTitle == "Heat"
        }
        #expect(hits.map(\.filterTitle) == ["Casino"])
    }

    @Test("A title query survives accents and typos")
    func titleQueryIsForgiving() {
        let library = [movie("Amélie", 2001, ["Comedy"]), movie("Heat", 1995, ["Crime"])]
        let hits = LibraryFilter.apply(library, query: LibraryQuery(title: "amelie")) { _ in false }
        #expect(hits.map(\.filterTitle) == ["Amélie"])
    }

    @Test("A miss comes back with the nearest titles, never with silence")
    func missReturnsNearest() {
        let library = [movie("Interstellar", 2014, ["Sci-Fi"]), movie("Heat", 1995, ["Crime"])]
        let hits = LibraryFilter.apply(library, query: LibraryQuery(title: "interstelar 2")) { _ in false }
        let nearest = LibraryFilter.nearest(to: "interstelar 2", in: library)
        #expect(hits.isEmpty || hits.first?.filterTitle == "Interstellar")
        #expect(nearest.first?.filterTitle == "Interstellar")
    }

    @Test("An unfiltered call samples the library instead of taking the first N")
    func unfilteredCallSamples() {
        let library = (1...500).map { movie("Film \($0)", 2000, ["Drama"], rating: Double($0 % 10)) }
        let sample = LibraryFilter.sample(library, count: 40)
        #expect(sample.count == 40)
        #expect(Set(sample.map(\.filterTitle)).count == 40, "a sample must not repeat a title")
        #expect(LibraryQuery().isUnfiltered)
        #expect(!LibraryQuery(genre: "romance").isUnfiltered)
    }

    /// The bug this guards against was invisible in a unit test and obvious in
    /// use: a rating-weighted sample handed back nearly the same forty films
    /// every time, the agent read that as the user's taste, and every
    /// recommendation afterwards came from that one corner of the shelf.
    @Test("Two draws differ, and highly-rated titles hold no monopoly")
    func samplingIsUniformAcrossDraws() {
        // Half the shelf is acclaimed, half is not — the shape that made the
        // old weighting collapse onto one cluster.
        let acclaimed = (1...100).map { movie("Acclaimed \($0)", 2000, ["Drama"], rating: 8.6) }
        let ordinary = (1...100).map { movie("Ordinary \($0)", 2000, ["Drama"], rating: 5.4) }
        let library = acclaimed + ordinary

        let first = Set(LibraryFilter.sample(library, count: 40).map(\.filterTitle))
        let second = Set(LibraryFilter.sample(library, count: 40).map(\.filterTitle))
        #expect(first != second, "two draws from 200 titles must not be identical")

        // With a uniform draw, 40 of 200 half-ordinary titles yields ordinary
        // ones with overwhelming probability; the old weighting yielded none.
        let ordinaryShare = LibraryFilter.sample(library, count: 40)
            .filter { $0.filterTitle.hasPrefix("Ordinary") }.count
        #expect(ordinaryShare > 0, "the sample must not be a rating leaderboard")
    }

    @Test("A facet-filtered list leads with the best rated, so 'what tonight' needs no second call")
    func facetFilteredResultsAreRatingSorted() {
        let library = [
            movie("Mediocre", 1995, ["Crime"], rating: 5.1),
            movie("Great", 1995, ["Crime"], rating: 8.4),
            movie("Fine", 1995, ["Crime"], rating: 6.9),
        ]
        let hits = LibraryFilter.apply(library, query: LibraryQuery(genre: "crime")) { _ in false }
        #expect(hits.map(\.filterTitle) == ["Great", "Fine", "Mediocre"])
    }

    @Test("A title query still ranks by match quality, not by rating")
    func titleQueriesKeepMatchOrder() {
        let library = [
            movie("Heat Wave", 2010, ["Drama"], rating: 9.5),
            movie("Heat", 1995, ["Crime"], rating: 8.0),
        ]
        let hits = LibraryFilter.apply(library, query: LibraryQuery(title: "heat")) { _ in false }
        #expect(hits.first?.filterTitle == "Heat", "the exact match leads regardless of rating")
    }
}

@Suite("check_titles arguments")
struct CheckTitlesArgumentTests {

    @Test("Both a bare string with a trailing year and a {title, year} object parse")
    func parsesBothForms() {
        let args = JSONValue.object([
            "titles": .array([
                .string("Dune 2021"),
                .string("Chungking Express"),
                .object(["title": .string("Severance"), "year": .number(2022)]),
                .string("   "),
            ]),
        ])
        let parsed = LocalToolBackend.titleQueries(args)
        #expect(parsed.count == 3, "the blank entry is dropped, not fatal")
        #expect(parsed[0].title == "Dune")
        #expect(parsed[0].year == 2021)
        #expect(parsed[1].title == "Chungking Express")
        #expect(parsed[1].year == nil)
        #expect(parsed[2].title == "Severance")
        #expect(parsed[2].year == 2022)
    }

    @Test("A missing titles array is an empty list, not a crash")
    func missingArrayIsEmpty() {
        #expect(LocalToolBackend.titleQueries(.object([:])).isEmpty)
        #expect(LocalToolBackend.titleQueries(.string("nope")).isEmpty)
    }
}
