import Testing
import Foundation
@testable import ArrCore

/// Only the fields the ranker reads — title, rating, votes, source and the
/// foreign id that `mediaRef` is built from. Everything else is inert here.
private func result(
    _ title: String,
    id: Int = 1,
    foreignId: String = "1",
    year: Int? = nil,
    rating: Double? = nil,
    votes: Int? = nil,
    source: QueueItem.Source = .radarr,
    inLibraryArrId: Int? = nil,
    imdbId: String? = nil,
    sourceRank: Int = 0
) -> SearchResult {
    SearchResult(
        externalId: id, foreignId: foreignId, title: title, subtitle: nil,
        year: year, rating: rating, votes: votes,
        imdb: nil, rottenTomatoes: nil, metacritic: nil,
        overview: nil, runtime: nil, genres: [], network: nil,
        certification: nil, posterURL: nil, source: source,
        inLibraryArrId: inLibraryArrId,
        imdbId: imdbId, sourceRank: sourceRank
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
        #expect(sorted.map(\.externalId) == [3, 4, 2, 1])
    }

    /// Nothing to rank by means nothing to reorder — the caller's own order
    /// (usually the arr's) is left alone rather than shuffled arbitrarily.
    @Test("An empty query leaves the caller's order untouched")
    func emptyQueryPreservesOrder() {
        let results = [result("Zed", id: 1), result("Alpha", id: 2)]
        #expect(SearchRelevance.sortedByRelevance(results, input: .text("   ")).map(\.externalId) == [1, 2])
    }

    @Test("The legacy string entry point matches the input-typed one")
    func legacyQueryOverload() {
        let results = [result("Foo Bar Baz", id: 1), result("Foo", id: 2)]
        #expect(SearchRelevance.sortedByRelevance(results, query: "foo").map(\.externalId)
                == SearchRelevance.sortedByRelevance(results, input: .text("foo")).map(\.externalId))
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

@Suite("SearchRelevance IMDB refs")
struct SearchRelevanceIMDBRefTests {
    /// The regression that shipped: `SearchResult.mediaRef` is TMDB-keyed for
    /// Radarr, so comparing it against `.imdb(_)` was always false and EVERY
    /// row got filtered out — `imdb:tt21958136` rendered an empty screen no
    /// matter what Radarr returned. Matching runs off the record's own
    /// `imdbId` now.
    @Test("An IMDB ref matches on the record's imdbId, not on mediaRef")
    func imdbRefMatchesOnImdbId() {
        let movie = result("Some Film", id: 999, source: .radarr, imdbId: "tt21958136")
        #expect(SearchRelevance.rank(movie, against: .ref(.imdb("tt21958136"))) >= 100_000)
    }

    @Test("An IMDB ref survives the sort instead of being filtered away")
    func imdbRefSurvivesSorting() {
        let wanted = result("Wanted", id: 999, source: .radarr, imdbId: "tt21958136")
        let other = result("Unrelated", id: 1000, source: .radarr, imdbId: "tt0000001")

        let sorted = SearchRelevance.sortedByRelevance([other, wanted], input: .ref(.imdb("tt21958136")))
        #expect(sorted.map(\.title) == ["Wanted"])
    }

    /// Sonarr answers `imdb:` lookups too, and its records carry the id — a
    /// series must be reachable by IMDB id, not just a movie.
    @Test("A Sonarr record matches an IMDB ref as readily as a Radarr one")
    func imdbRefWorksForSeries() {
        let show = result("Some Show", id: 42, source: .sonarr, imdbId: "tt0903747")
        #expect(SearchRelevance.rank(show, against: .ref(.imdb("tt0903747"))) >= 100_000)
        #expect(MediaRef.imdb("tt1").compatibleSources.contains(.sonarr))
    }

    /// Case is not identity here — IMDB ids are conventionally lowercase but
    /// a pasted "TT0903747" means the same record.
    @Test("IMDB id matching ignores case")
    func imdbRefIsCaseInsensitive() {
        let show = result("Some Show", id: 42, source: .radarr, imdbId: "tt0903747")
        #expect(SearchRelevance.rank(show, against: .ref(.imdb("TT0903747"))) >= 100_000)
    }

    /// A server that doesn't understand `imdb:` does a literal title search
    /// and hands back junk. When the batch proves the field IS available —
    /// some other row carries one — a row without it is genuinely not the
    /// record asked for.
    @Test("A record with no imdbId loses to one that matches")
    func missingImdbIdIsNotAMatch() {
        let noId = result("Whatever", id: 7, source: .radarr)
        let real = result("Wanted", id: 8, source: .radarr, imdbId: "tt0903747")
        #expect(SearchRelevance.rank(noId, against: .ref(.imdb("tt0903747"))) == 0)

        let sorted = SearchRelevance.sortedByRelevance([noId, real], input: .ref(.imdb("tt0903747")))
        #expect(sorted.map(\.title) == ["Wanted"])
    }

    /// …but when NOTHING in the batch carries an IMDB id, the field isn't
    /// available from this source at all, and dropping everything would
    /// reproduce the empty screen the whole fix exists to prevent. The arr
    /// only returned these rows for an `imdb:` term — trust it.
    @Test("A batch with no IMDB ids at all is trusted rather than emptied")
    func absentFieldFallsBackToTrustingTheArr() {
        let a = result("Resolved By The Arr", id: 7, rating: 8.0, source: .radarr)
        let b = result("Also Returned", id: 8, source: .radarr)

        let sorted = SearchRelevance.sortedByRelevance([b, a], input: .ref(.imdb("tt0903747")))
        #expect(sorted.map(\.title) == ["Resolved By The Arr", "Also Returned"])
    }
}

@Suite("SearchRelevance punctuation folding")
struct SearchRelevancePunctuationTests {
    /// Punctuation becomes a separator, so hyphenated and colon-carrying
    /// titles are reachable by typing the plain words.
    @Test("Punctuation folds to spaces")
    func punctuationFolds() {
        #expect(SearchRelevance.normalize("Spider-Man: No Way Home") == "spider man no way home")
        #expect(SearchRelevance.normalize("WALL·E") == "wall e")
        #expect(SearchRelevance.normalize("Mission: Impossible") == "mission impossible")
    }

    @Test("A punctuation-free query still reaches a punctuated title")
    func queryReachesPunctuatedTitle() {
        let spidey = result("Spider-Man")
        #expect(SearchRelevance.rank(spidey, against: .text("spider man")) >= 10_000)
    }
}

@Suite("SearchRelevance multi-word coverage")
struct SearchRelevanceCoverageTests {
    /// Word order used to matter completely: anything but a prefix or a
    /// literal substring scored zero, so "bunny big" found nothing.
    @Test("Every query word matching wins regardless of order")
    func fullCoverageIsOrderIndependent() {
        let bunny = result("Big Buck Bunny")
        let scrambled = SearchRelevance.score(bunny, normalizedQuery: "bunny big")
        #expect(scrambled > 3_000)
        #expect(scrambled < 5_000)
    }

    /// Coverage is weighted by characters, so dropping a stopword costs far
    /// less than dropping the word that carries the query.
    @Test("Partial coverage is weighted by how much of the query landed")
    func partialCoverageIsWeighted() {
        let title = result("The Matrix Reloaded")
        let mostlyMatched = SearchRelevance.score(title, normalizedQuery: "matrix reloaded xyz")
        let barelyMatched = SearchRelevance.score(title, normalizedQuery: "the abcdef ghijkl")
        #expect(mostlyMatched > barelyMatched)
        #expect(barelyMatched > 0)
    }

    /// Single-word queries deliberately keep the original bands — the
    /// coverage question is the same one the token-prefix band already
    /// answers, and relabelling it would move every existing result.
    @Test("Single-word queries keep the original token-prefix band")
    func singleWordBandsUnchanged() {
        #expect(SearchRelevance.score(result("Big Buck"), normalizedQuery: "buck") == 2_000 - 8)
    }

    /// Coverage must not outrank a genuine prefix match.
    @Test("Coverage can't beat a title-prefix match")
    func coverageStaysUnderPrefix() {
        let prefix = SearchRelevance.score(result("Big Buck Bunny"), normalizedQuery: "big buck")
        let covered = SearchRelevance.score(result("Bunny And The Big Buck"), normalizedQuery: "big buck")
        #expect(prefix > covered)
    }
}

@Suite("SearchRelevance ranking modifiers")
struct SearchRelevanceModifierTests {
    /// Typing the name of something you own usually means "take me to it".
    @Test("An owned record edges out an equally-good stranger")
    func libraryBoost() {
        let owned = result("Foo One", inLibraryArrId: 5)
        let stranger = result("Foo Two")
        #expect(SearchRelevance.rank(owned, against: .text("foo"))
                > SearchRelevance.rank(stranger, against: .text("foo")))
    }

    /// A year in the query is a deliberate disambiguator between same-titled
    /// records, and it has to outweigh both quality and ownership.
    @Test("A typed year lifts the matching record")
    func yearBonus() {
        let newer = result("Dune Part Two", year: 2024)
        let older = result("Dune", year: 2021, rating: 8.0, votes: 20_000)

        let sorted = SearchRelevance.sortedByRelevance([older, newer], input: .text("dune 2024"))
        #expect(sorted.map(\.title) == ["Dune Part Two", "Dune"])
    }

    /// …but a bare year stays a search for the FILM. Stripping it would turn
    /// "1917" into an empty query with a year filter attached, which is the
    /// ambiguity that kept year parsing out of `QueryParser` in the first place.
    @Test("A bare year is still a title search")
    func bareYearIsNotStripped() {
        #expect(SearchRelevance.splitYear("1917").year == nil)
        #expect(SearchRelevance.splitYear("1917").query == "1917")
        #expect(SearchRelevance.score(result("1917"), normalizedQuery: "1917") == 10_000)
    }

    @Test("A year is only taken out when other words remain")
    func yearSplitKeepsTheRest() {
        let split = SearchRelevance.splitYear("dune 2024")
        #expect(split.query == "dune")
        #expect(split.year == 2024)
    }

    /// The arr's own ordering encodes upstream popularity. It used to be
    /// discarded outright, because the ranker re-sorted on a continuous score
    /// that essentially never ties.
    @Test("The arr's own ordering breaks ties between equal matches")
    func upstreamRankBreaksTies() {
        let popular = result("Foo Bar", id: 1, sourceRank: 0)
        let obscure = result("Foo Baz", id: 2, sourceRank: 30)

        let sorted = SearchRelevance.sortedByRelevance([obscure, popular], input: .text("foo"))
        #expect(sorted.map(\.externalId) == [1, 2])
    }

    /// Upstream position is a nudge, not a verdict — it must never drag a
    /// better title match below a worse one.
    @Test("Upstream position can't override a better match")
    func upstreamStaysInsideItsBand() {
        let exactButDeep = result("Foo", id: 1, sourceRank: 999)
        let prefixButFirst = result("Foo Bar Baz", id: 2, sourceRank: 0)

        let sorted = SearchRelevance.sortedByRelevance([prefixButFirst, exactButDeep], input: .text("foo"))
        #expect(sorted.map(\.externalId) == [1, 2])
    }
}

@Suite("SearchRelevance year disambiguation")
struct SearchRelevanceYearTests {
    /// A leading number is part of the title, not a filter. Scanning the
    /// whole query for a year would read this as "a space odyssey, 2001",
    /// and the mismatch penalty would then bury the 1968 film it names.
    @Test("A leading year stays part of the title")
    func leadingYearIsNotAFilter() {
        let split = SearchRelevance.splitYear("2001 a space odyssey")
        #expect(split.year == nil)
        #expect(split.query == "2001 a space odyssey")

        let odyssey = result("2001 A Space Odyssey", year: 1968)
        #expect(SearchRelevance.rank(odyssey, against: .text("2001 a space odyssey")) >= 10_000)
    }

    /// The upper bound on plausible years is what protects titles that end
    /// in a far-future number.
    @Test("A trailing number too far in the future is title, not year")
    func farFutureNumberIsTitle() {
        #expect(SearchRelevance.splitYear("blade runner 2049").year == nil)

        let bladeRunner = result("Blade Runner 2049", year: 2017)
        #expect(SearchRelevance.rank(bladeRunner, against: .text("blade runner 2049")) >= 10_000)
    }

    /// The whole point of the penalty: an explicit year has to be able to
    /// beat an exact title match on the wrong record, which no in-band
    /// nudge could ever do.
    @Test("An explicit year beats an exact title match from another year")
    func explicitYearBeatsWrongYearExactMatch() {
        let wanted = result("Dune Part Two", year: 2024)
        let exactWrongYear = result("Dune", year: 2021, rating: 8.0, votes: 20_000)

        let sorted = SearchRelevance.sortedByRelevance([exactWrongYear, wanted], input: .text("dune 2024"))
        #expect(sorted.map(\.title) == ["Dune Part Two", "Dune"])
    }

    /// A record the source never dated shouldn't be punished for it.
    @Test("A record with no year is untouched by a year query")
    func undatedRecordsAreNotPenalised() {
        let undated = result("Dune Companion")
        let wrongYear = result("Dune", year: 2021)

        let sorted = SearchRelevance.sortedByRelevance([wrongYear, undated], input: .text("dune 2024"))
        #expect(sorted.map(\.title) == ["Dune Companion", "Dune"])
    }
}

@Suite("Demo search id lookups")
struct DemoSearchRefTests {
    /// Demo mode filtered its pool by plain substring against the RAW term,
    /// so `imdb:ttN` matched nothing and demo silently contradicted the real
    /// behaviour it exists to demonstrate.
    @Test("An IMDB ref resolves against the demo pool")
    func demoResolvesIMDBRef() throws {
        let pool = DemoMocks.radarrSearchPool
        let target = try #require(pool.first { $0.imdbId != nil })
        let imdbId = try #require(target.imdbId)

        let hits = DemoMocks.searchResults(for: "imdb:\(imdbId)", source: .radarr)
        #expect(hits.map(\.externalId) == [target.externalId])

        // …and survives the ranker's ref filter, which is the step that used
        // to throw the record away even when the lookup found it.
        let sorted = SearchRelevance.sortedByRelevance(hits, input: QueryParser.parse("imdb:\(imdbId)"))
        #expect(sorted.map(\.externalId) == [target.externalId])
    }

    @Test("A TMDB ref resolves against the demo pool")
    func demoResolvesTMDBRef() throws {
        let target = try #require(DemoMocks.radarrSearchPool.first)
        let hits = DemoMocks.searchResults(for: "tmdb:\(target.externalId)", source: .radarr)
        #expect(hits.map(\.externalId) == [target.externalId])
    }

    /// Every demo record carries an id so both id schemes are exercisable.
    @Test("Demo pools carry IMDB ids")
    func demoPoolsCarryIMDBIds() {
        #expect(DemoMocks.radarrSearchPool.allSatisfy { $0.imdbId != nil })
        #expect(DemoMocks.sonarrSearchPool.allSatisfy { $0.imdbId != nil })
    }
}
