import Testing
import Foundation
@testable import ArrCore

/// Only the fields the ranker reads — title, rating, votes, source and the
/// foreign id that `mediaRef` is built from. Everything else is inert here.
private func result(
    _ title: String,
    id: Int = 1,
    foreignId: String = "1",
    rating: Double? = nil,
    votes: Int? = nil,
    source: QueueItem.Source = .radarr
) -> SearchResult {
    SearchResult(
        id: id, foreignId: foreignId, title: title, subtitle: nil,
        year: nil, rating: rating, votes: votes,
        imdb: nil, rottenTomatoes: nil, metacritic: nil,
        overview: nil, runtime: nil, genres: [], network: nil,
        certification: nil, posterURL: nil, source: source
    )
}

@Suite("SearchRelevance normalisation")
struct SearchRelevanceNormalisationTests {
    /// Case, diacritics and surrounding whitespace all fold away, so
    /// "Pożeracz" is reachable by typing "pozeracz" — the same rule the
    /// queue filter already used.
    @Test("Normalising folds case, strips diacritics and trims")
    func folding() {
        #expect(SearchRelevance.normalize("  PoŻeracz  ") == "pozeracz")
        #expect(SearchRelevance.normalize("Blade Runner") == "blade runner")
    }

    @Test("An already-normalised string comes back unchanged")
    func idempotent() {
        let once = SearchRelevance.normalize("dune part two")
        #expect(SearchRelevance.normalize(once) == once)
    }

    @Test("A diacritic-carrying query still scores as an exact match")
    func diacriticQueryMatchesPlainTitle() {
        #expect(SearchRelevance.rank(result("Pozeracz"), against: .text("PoŻeracz")) == 10_000)
    }
}

@Suite("SearchRelevance scoring tiers")
struct SearchRelevanceScoringTests {
    @Test("An exact title match takes the top tier")
    func exactMatch() {
        #expect(SearchRelevance.score(result("Audi"), normalizedQuery: "audi") == 10_000)
    }

    /// Inside the prefix band the shorter title wins: typing "Audi" should
    /// surface "Audio" before "Audiobooks".
    @Test("A title prefix match scores below exact, shorter titles first")
    func prefixBand() {
        let shorter = SearchRelevance.score(result("Audio"), normalizedQuery: "audi")
        let longer = SearchRelevance.score(result("Audiobooks"), normalizedQuery: "audi")

        #expect(shorter == 5_000 - 5)
        #expect(longer == 5_000 - 10)
        #expect(shorter > longer)
    }

    /// A word boundary beats a mid-word hit: "Buck" should find "Big Buck"
    /// above anything that merely contains the letters.
    @Test("A token prefix match scores below a title prefix and above a substring")
    func tokenPrefixBand() {
        #expect(SearchRelevance.score(result("Big Buck"), normalizedQuery: "buck") == 2_000 - 8)
    }

    /// Earlier in the title is a better hit, so the penalty grows with the
    /// match position rather than being flat across the band.
    @Test("A substring match scores by how early it appears")
    func substringBand() {
        let early = SearchRelevance.score(result("Saudi Arabia"), normalizedQuery: "audi")
        let late = SearchRelevance.score(result("The Saudi Post"), normalizedQuery: "audi")

        #expect(early == 1_000 - 1)
        #expect(late == 1_000 - 5)
        #expect(early > late)
    }

    @Test("A title with no hit at all scores zero")
    func noMatch() {
        #expect(SearchRelevance.score(result("Blade Runner"), normalizedQuery: "audi") == 0)
    }

    /// The scorer is only ever called with a pre-normalised query, and an
    /// empty one means "no query" — every result is equally (ir)relevant.
    @Test("An empty query scores zero for everything")
    func emptyQuery() {
        #expect(SearchRelevance.score(result("Audi"), normalizedQuery: "") == 0)
    }

    /// The bands are what the whole design rests on, so assert the ordering
    /// itself and not just the individual numbers.
    @Test("The four tiers stay strictly ordered for one query")
    func bandsAreOrdered() {
        let scores = ["Audi", "Audition", "Big Audi Show", "Saudi Arabia", "Blade Runner"]
            .map { SearchRelevance.score(result($0), normalizedQuery: "audi") }

        #expect(scores == scores.sorted(by: >))
        #expect(scores.first == 10_000)
        #expect(scores.last == 0)
    }
}

@Suite("SearchRelevance Bayesian quality")
struct SearchRelevanceQualityTests {
    /// The case the shrinkage exists for: a 9.9 backed by five votes is not
    /// evidence of a 9.9 film, so it gets pulled most of the way to the
    /// global mean.
    @Test("A high rating with few votes is pulled toward the global mean")
    func highRatingLowVotes() {
        let q = SearchRelevance.bayesianQuality(result("x", rating: 9.9, votes: 5))
        #expect(abs(q - 6.534) < 0.01)
    }

    @Test("A high rating with many votes barely moves")
    func highRatingManyVotes() {
        let q = SearchRelevance.bayesianQuality(result("x", rating: 8.0, votes: 20_000))
        #expect(abs(q - 7.963) < 0.01)
    }

    /// The asymmetry: shrinking *upward* used to rescue unrated junk to ~6.5
    /// and let an obscure same-titled short ride into second place. Ratings
    /// at or below the mean are left exactly alone.
    @Test("A low rating is never lifted toward the mean")
    func lowRatingsAreLeftAlone() {
        // Below the mean, at the mean, and low-with-few-votes — the shape
        // that used to get rescued to ~6.5.
        for (rating, votes) in [(0.0, 5), (5.5, 20_000), (6.5, 1_000)] {
            #expect(SearchRelevance.bayesianQuality(result("x", rating: rating, votes: votes)) == rating)
        }
    }

    /// Sonarr / Lidarr / Whisparr don't surface vote counts — their scores
    /// are already aggregated upstream, so they skip the shrinkage entirely
    /// rather than being penalised for the missing field.
    @Test("A source with no vote count keeps its raw rating")
    func missingVotesFallsBackToRawRating() {
        for votes: Int? in [nil, 0] {
            #expect(SearchRelevance.bayesianQuality(result("x", rating: 9.9, votes: votes)) == 9.9)
        }
    }

    @Test("An unrated result contributes no quality at all")
    func unrated() {
        #expect(SearchRelevance.bayesianQuality(result("x")) == 0)
    }
}

@Suite("SearchRelevance ranking and sorting")
struct SearchRelevanceRankingTests {
    /// Two titles of the same length in the same band — the only thing left
    /// to separate them is how good they are.
    @Test("Quality breaks ties inside a band")
    func qualityBreaksTies() {
        let better = result("Foo One", rating: 8.0, votes: 20_000)
        let worse = result("Foo Two", rating: 5.0)

        #expect(SearchRelevance.score(better, normalizedQuery: "foo")
                == SearchRelevance.score(worse, normalizedQuery: "foo"))
        #expect(SearchRelevance.rank(better, normalizedQuery: "foo")
                > SearchRelevance.rank(worse, normalizedQuery: "foo"))
    }

    /// The quality weight is capped well below the 1 000-point step between
    /// tiers, so no rating can promote a weaker kind of match.
    @Test("A perfect rating can't lift a lower band above a higher one")
    func bandsSurviveQuality() {
        let weakMatchGreatFilm = result("Best Foo Ever", rating: 10.0, votes: 20_000)
        let strongMatchUnrated = result("Foo Bar")

        #expect(SearchRelevance.rank(strongMatchUnrated, normalizedQuery: "foo")
                > SearchRelevance.rank(weakMatchGreatFilm, normalizedQuery: "foo"))
    }

    /// The regression this scorer was written for: ordering used to be
    /// alphabetical-by-source, so a marginal Radarr hit always sat above a
    /// perfect Sonarr one.
    @Test("The best match wins regardless of which arr returned it")
    func crossSourceOrdering() {
        let marginalRadarr = result("Foo Bar Baz", id: 1, source: .radarr)
        let exactSonarr = result("Foo", id: 2, source: .sonarr)

        let sorted = SearchRelevance.sortedByRelevance([marginalRadarr, exactSonarr], input: .text("Foo"))
        #expect(sorted.map(\.title) == ["Foo", "Foo Bar Baz"])
    }

    @Test("Results come back in tier order across all four bands")
    func fullOrdering() {
        let results = [
            result("Saudi Arabia", id: 1),
            result("Big Audi Show", id: 2),
            result("Audi", id: 3),
            result("Audition", id: 4),
        ]
        let sorted = SearchRelevance.sortedByRelevance(results, input: .text("audi"))
        #expect(sorted.map(\.id) == [3, 4, 2, 1])
    }

    /// Nothing to rank by means nothing to reorder — the caller's own order
    /// (usually the arr's) is left alone rather than shuffled arbitrarily.
    @Test("An empty query leaves the caller's order untouched")
    func emptyQueryPreservesOrder() {
        let results = [result("Zed", id: 1), result("Alpha", id: 2)]
        #expect(SearchRelevance.sortedByRelevance(results, input: .text("   ")).map(\.id) == [1, 2])
    }

    @Test("The legacy string entry point matches the input-typed one")
    func legacyQueryOverload() {
        let results = [result("Foo Bar Baz", id: 1), result("Foo", id: 2)]
        #expect(SearchRelevance.sortedByRelevance(results, query: "foo").map(\.id)
                == SearchRelevance.sortedByRelevance(results, input: .text("foo")).map(\.id))
    }
}

@Suite("SearchRelevance ref inputs")
struct SearchRelevanceRefTests {
    /// An id lookup has no fuzzy middle ground: the record either is the one
    /// asked for or it isn't, whatever its title happens to say.
    @Test("A ref query matches on id and ignores the title entirely")
    func refIgnoresTitle() {
        let match = result("Nothing Like The Query", id: 42, source: .radarr)
        #expect(SearchRelevance.rank(match, against: .ref(.tmdb(42))) == 100_000)
    }

    /// Same number, different scheme — a TVDB 42 is not a TMDB 42, and
    /// letting the ids collide would open the wrong record.
    @Test("An id from a different scheme is not a match")
    func refSchemeMustAgree() {
        let sonarrResult = result("Some Show", id: 42, source: .sonarr)
        #expect(SearchRelevance.rank(sonarrResult, against: .ref(.tmdb(42))) == 0)
        #expect(SearchRelevance.rank(sonarrResult, against: .ref(.tvdb(42))) == 100_000)
    }

    /// Lidarr's identity is a MusicBrainz string, so its ref matching runs
    /// off `foreignId` rather than the numeric id.
    @Test("A Lidarr ref matches on the MusicBrainz id")
    func refMatchesMusicBrainzId() {
        let artist = result("Example Artist", id: 7, foreignId: "mbid-1", source: .lidarr)
        #expect(SearchRelevance.rank(artist, against: .ref(.musicBrainz("mbid-1"))) == 100_000)
        #expect(SearchRelevance.rank(artist, against: .ref(.musicBrainz("mbid-2"))) == 0)
    }

    /// A ref match sits above every text tier, so a record the user asked
    /// for by id can never be pushed down by a better-rated title match.
    @Test("A ref match outranks the best possible text match")
    func refOutranksText() {
        let byRef = result("Anything", id: 42, source: .radarr)
        let perfectText = result("Audi", rating: 10.0, votes: 20_000)

        #expect(SearchRelevance.rank(byRef, against: .ref(.tmdb(42)))
                > SearchRelevance.rank(perfectText, normalizedQuery: "audi"))
    }

    /// Sorting a ref query also *filters*: rows from other sources that came
    /// back in the same flatMap would otherwise show up as unrelated noise
    /// under the one record that was asked for.
    @Test("Sorting a ref query drops everything that isn't that record")
    func refSortingFilters() {
        let wanted = result("Wanted", id: 42, source: .radarr)
        let otherMovie = result("Unrelated", id: 43, source: .radarr)
        let otherShow = result("Unrelated Show", id: 42, source: .sonarr)

        let sorted = SearchRelevance.sortedByRelevance(
            [otherMovie, otherShow, wanted], input: .ref(.tmdb(42))
        )
        #expect(sorted.map(\.title) == ["Wanted"])
    }

    /// Two records claiming the same ref shouldn't happen, but parsing edges
    /// exist — quality still decides so the order is at least deterministic.
    @Test("Duplicate refs break the tie on quality")
    func duplicateRefsBreakOnQuality() {
        let better = result("Dupe A", id: 42, rating: 8.0, votes: 20_000)
        let worse = result("Dupe B", id: 42, rating: 5.0)

        let sorted = SearchRelevance.sortedByRelevance([worse, better], input: .ref(.tmdb(42)))
        #expect(sorted.map(\.title) == ["Dupe A", "Dupe B"])
    }
}
