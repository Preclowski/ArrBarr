import Testing
import Foundation
import SwiftData
import ArrCore
@testable import TonightCore

@Suite struct DiscoverFilterTests {
    @Test func defaultFilterIsDefault() {
        #expect(DiscoverFilter(type: .movie).isDefault)
    }

    @Test func queryItemsMapFields() {
        var filter = DiscoverFilter(type: .movie)
        filter.genreIds = [878]
        filter.startYear = 1990
        filter.endYear = 1999
        filter.minRating = 7.5
        filter.maxRuntime = 120
        filter.sort = .rating
        let items = filter.queryItems(region: "PL")
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        #expect(value("with_genres") == "878")
        #expect(value("primary_release_date.gte") == "1990-01-01")
        #expect(value("primary_release_date.lte") == "1999-12-31")
        #expect(value("vote_average.gte") == "7.5")
        #expect(value("with_runtime.lte") == "120")
        #expect(value("sort_by") == "vote_average.desc")
        #expect(value("watch_region") == "PL")
    }

    @Test func tvUsesAirDateKeys() {
        var filter = DiscoverFilter(type: .tv)
        filter.startYear = 2020
        let items = filter.queryItems(region: "US")
        #expect(items.contains { $0.name == "first_air_date.gte" && $0.value == "2020-01-01" })
    }
}

@Suite struct FilterPresetTests {
    /// A decade page starts pinned to its years, and Reset puts them back
    /// instead of turning the page into all of TMDB.
    @Test func resetKeepsThePin() {
        let preset = FilterPreset(years: 1980...1989)
        var filter = preset.applied(to: DiscoverFilter(type: .movie))
        #expect(filter.startYear == 1980 && filter.endYear == 1989)

        filter.minRating = 7
        filter.libraryPresence = .owned
        filter.sort = .rating
        let reset = preset.applied(to: filter)
        #expect(reset.startYear == 1980 && reset.endYear == 1989)
        #expect(reset.minRating == nil)
        // Neither the scope nor the sort is a filter.
        #expect(reset.libraryPresence == .owned)
        #expect(reset.sort == .rating)
    }

    /// The badge counts what the user switched on, never the page's own pin.
    @Test func pinDoesNotCountAsAFilter() {
        let genre = FilterPreset(genreIds: [37])
        var filter = genre.applied(to: DiscoverFilter(type: .movie))
        #expect(filter.activeCount == 1)
        #expect(genre.userCount(in: filter) == 0)

        filter.minVotes = 500
        #expect(genre.userCount(in: filter) == 1)

        // A genre the user added on top counts, pin or no pin.
        filter.genreIds.insert(18)
        #expect(genre.userCount(in: filter) == 2)
    }

    @Test func yearsAreOwnedOnlyWhenTheyAreThePinnedOnes() {
        let preset = FilterPreset(years: 1990...1999)
        var filter = preset.applied(to: DiscoverFilter(type: .movie))
        #expect(preset.ownsYears(of: filter))
        filter.endYear = 1995
        #expect(!preset.ownsYears(of: filter))
        #expect(preset.userCount(in: filter) == 1)
    }
}

@Suite struct DecadesTests {
    @Test func decadesRunNewestFirstBackTo1950() {
        let all = Decades.all
        #expect(all.first!.start > all.last!.start)
        #expect(all.last?.start == 1950)
        #expect(all.first!.years.count == 10)
        #expect(Decade(start: 1980).displayName == "1980s")
    }
}

@Suite struct RawSummaryTests {
    @Test func decodesMovieRow() throws {
        let json = """
        {"id": 603, "title": "The Matrix", "release_date": "1999-03-30",
         "poster_path": "/p.jpg", "backdrop_path": "/b.jpg",
         "vote_average": 8.2, "vote_count": 26000, "genre_ids": [878, 28]}
        """.data(using: .utf8)!
        let raw = try JSONDecoder().decode(TMDBService.RawSummary.self, from: json)
        let item = try #require(raw.item(defaultType: .movie))
        #expect(item.tmdbId == 603)
        #expect(item.type == .movie)
        #expect(item.year == 1999)
        #expect(item.backdropPath == "/b.jpg")
    }

    @Test func multiSearchSkipsPeopleAndTagsTV() throws {
        let json = """
        {"results": [
          {"id": 1, "media_type": "person", "name": "Someone"},
          {"id": 1396, "media_type": "tv", "name": "Breaking Bad", "first_air_date": "2008-01-20"}
        ]}
        """.data(using: .utf8)!
        let page = try JSONDecoder().decode(TMDBService.Page.self, from: json)
        let items = page.results.compactMap { $0.item(defaultType: .movie) }
        #expect(items.count == 1)
        #expect(items[0].type == .tv)
        #expect(items[0].title == "Breaking Bad")
        #expect(items[0].year == 2008)
    }
}

@Suite struct LibraryTests {
    @MainActor
    @Test func listMembershipAndWatchedLifecycle() throws {
        let container = try Library.makeContainer(inMemory: true)
        let context = container.mainContext
        let item = MediaItem(tmdbId: 603, type: .movie, title: "The Matrix", year: 1999,
                             posterPath: nil, backdropPath: nil, rating: 8.2,
                             voteCount: nil, overview: nil)

        let saved = Library.savedTitle(for: item, in: context)
        #expect(Library.savedTitle(for: item, in: context) === saved) // de-duped

        let list = WatchList(name: "Tonight")
        context.insert(list)
        saved.lists.append(list)
        try context.save()
        #expect(list.titles.count == 1)

        // Removing from the only list with no watched date prunes the row.
        saved.lists.removeAll()
        Library.pruneIfOrphaned(saved, in: context)
        try context.save()
        #expect(Library.existingTitle(for: item, in: context) == nil)

        // Watched alone keeps the row alive.
        let again = Library.savedTitle(for: item, in: context)
        again.watchedAt = .now
        Library.pruneIfOrphaned(again, in: context)
        try context.save()
        #expect(Library.existingTitle(for: item, in: context) != nil)
    }
}

@Suite struct ArrBarrImportTests {
    /// The point of `ArrBarrProfile`: TonightBarr no longer knows ArrBarr's
    /// storage format. It reads the plist as opaque values and lets ArrCore's
    /// own decoders interpret them, so a change to that format breaks in one
    /// place — ArrCore — instead of silently reading "not configured" here.
    @Test func readsArrBarrProfileThroughArrCore() throws {
        let radarr = ServiceConfig(enabled: true, baseURL: "http://nas.local:7878",
                                   apiKey: "", username: "", password: "")
        let dict: [String: Any] = [
            "ArrBarr.config.radarr": try JSONEncoder().encode(radarr),
            "ArrBarr.secret.radarr.apiKey": "radarr-key",
            "ArrBarr.secret.tmdb.apiKey": "abc123",
            // Not ours, and it must not travel with the rest.
            "SomeOtherApp.key": "nope",
        ]
        let url = try Self.writePlist(dict)
        defer { try? FileManager.default.removeItem(at: url) }

        let values = try #require(ArrBarrProfile.read(from: url))
        #expect(values["SomeOtherApp.key"] == nil)
        // The API key lives under a sibling secret entry, not inside the config
        // blob — assembling the two is exactly what used to be duplicated here.
        let service = try #require(ArrBarrProfile.service(.radarr, in: values))
        #expect(service.baseURL.absoluteString == "http://nas.local:7878")
        #expect(service.apiKey == "radarr-key")
        #expect(ArrBarrProfile.tmdbAPIKey(in: values) == "abc123")
        // A service ArrBarr never configured reads as absent, not as empty.
        #expect(ArrBarrProfile.service(.sonarr, in: values) == nil)
    }

    /// No ArrBarr on this machine is a normal state, not a failure.
    @Test func missingFileIsNotAnError() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "nope.plist")
        #expect(ArrBarrProfile.read(from: missing) == nil)
        #expect(ArrBarrProfile.tmdbAPIKey(in: [:]) == nil)
        #expect(ArrBarrProfile.service(.radarr, in: [:]) == nil)
    }

    /// An arr with a URL but no key is NOT usable — every call would fail
    /// authentication. `ConfigStore` draws that line the same way.
    @Test func configWithoutKeyIsNotConfigured() throws {
        let radarr = ServiceConfig(enabled: true, baseURL: "http://nas.local:7878",
                                   apiKey: "", username: "", password: "")
        let url = try Self.writePlist(["ArrBarr.config.radarr": try JSONEncoder().encode(radarr)])
        defer { try? FileManager.default.removeItem(at: url) }
        let values = try #require(ArrBarrProfile.read(from: url))
        #expect(ArrBarrProfile.service(.radarr, in: values) == nil)
    }

    /// Secrets must never end up anywhere but this process's memory. A
    /// `UserDefaults` suite would persist them; the registration domain would
    /// hand them to every other `UserDefaults` in the process.
    @Test func readingLeavesNothingBehind() throws {
        let url = try Self.writePlist(["ArrBarr.secret.tmdb.apiKey": "abc123"])
        defer { try? FileManager.default.removeItem(at: url) }
        _ = ArrBarrProfile.read(from: url)
        #expect(UserDefaults.standard.string(forKey: "ArrBarr.secret.tmdb.apiKey") == nil)
    }

    private static func writePlist(_ dict: [String: Any]) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "tonightbarr-test-\(UUID().uuidString).plist")
        try data.write(to: url)
        return url
    }
}

@Suite struct TitleDetailsTests {
    private func details(_ json: String, type: MediaType = .movie) throws -> TitleDetails {
        let raw = try JSONDecoder().decode(RawDetails.self, from: Data(json.utf8))
        let base = MediaItem(tmdbId: 1, type: type, title: "T", year: 2000,
                             posterPath: nil, backdropPath: nil,
                             rating: nil, voteCount: nil, overview: nil)
        return TitleDetails(raw: raw, base: base, region: "PL")
    }

    @Test func takesProductionCountries() throws {
        let d = try details("""
        {"id": 1,
         "production_countries": [{"iso_3166_1": "US"}, {"iso_3166_1": "GB"}],
         "origin_country": ["CA"]}
        """)
        #expect(d.countryCodes == ["US", "GB"])
    }

    /// A show with no production country still says where it aired from.
    @Test func fallsBackToOriginCountry() throws {
        let d = try details("""
        {"id": 1, "production_countries": [], "origin_country": ["PL"]}
        """, type: .tv)
        #expect(d.countryCodes == ["PL"])
    }

    /// A co-production of six is a fact for the credits, not for a hero.
    @Test func heroShowsAtMostTwoCountries() throws {
        let d = try details("""
        {"id": 1,
         "production_countries": [{"iso_3166_1": "US"}, {"iso_3166_1": "GB"},
                                  {"iso_3166_1": "FR"}]}
        """)
        #expect(d.countryNames.count == 2)
    }
}
