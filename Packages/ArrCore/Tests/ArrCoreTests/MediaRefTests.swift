import Testing
import Foundation
@testable import ArrCore

@Suite("MediaRef")
struct MediaRefTests {
    // MARK: - urlString round-trip

    @Test("A TMDB ref round-trips through urlString")
    func tmdbRoundTrip() {
        let ref = MediaRef.tmdb(12345)
        #expect(ref.urlString == "tmdb:12345")
        #expect(MediaRef(urlString: "tmdb:12345") == .tmdb(12345))
    }

    @Test("A TVDB ref round-trips through urlString")
    func tvdbRoundTrip() {
        let ref = MediaRef.tvdb(67890)
        #expect(ref.urlString == "tvdb:67890")
        #expect(MediaRef(urlString: "tvdb:67890") == .tvdb(67890))
    }

    @Test("An IMDB ref round-trips through urlString")
    func imdbRoundTrip() {
        let ref = MediaRef.imdb("tt0133093")
        #expect(ref.urlString == "imdb:tt0133093")
        #expect(MediaRef(urlString: "imdb:tt0133093") == .imdb("tt0133093"))
    }

    @Test("A MusicBrainz ref round-trips through the mb: form")
    func musicBrainzRoundTrip() {
        let ref = MediaRef.musicBrainz("abc-def-ghi")
        #expect(ref.urlString == "mb:abc-def-ghi")
        #expect(MediaRef(urlString: "mb:abc-def-ghi") == .musicBrainz("abc-def-ghi"))
    }

    // MARK: - Parser leniency

    @Test("An IMDB id without the tt prefix is normalised")
    func imdbAcceptsBareDigits() {
        // Caller forgets the "tt" prefix — we normalise it.
        #expect(MediaRef(urlString: "imdb:0133093") == .imdb("tt0133093"))
    }

    @Test("MusicBrainz accepts the musicbrainz: and lidarr: aliases")
    func musicBrainzAcceptsAliases() {
        #expect(MediaRef(urlString: "musicbrainz:guid-123") == .musicBrainz("guid-123"))
        #expect(MediaRef(urlString: "lidarr:guid-123") == .musicBrainz("guid-123"))
    }

    @Test("The scheme is matched case-insensitively")
    func caseInsensitiveScheme() {
        #expect(MediaRef(urlString: "TMDB:42") == .tmdb(42))
        #expect(MediaRef(urlString: "Tvdb:42") == .tvdb(42))
    }

    @Test("Surrounding whitespace is trimmed before parsing")
    func trimsWhitespace() {
        #expect(MediaRef(urlString: "  tmdb:42  ") == .tmdb(42))
    }

    // MARK: - Parser rejection

    @Test("Malformed and unknown-scheme input parses to nil", arguments: [
        "",
        "tmdb:",            // empty payload
        "tmdb:notanumber",  // non-numeric
        "tvdb:abc",
        "Dune",             // no colon → plain text
        "unknown:42",       // unknown scheme
    ])
    func rejectsMalformed(input: String) {
        #expect(MediaRef(urlString: input) == nil)
    }

    @Test("A title that happens to contain a colon is not a ref")
    func textWithColonIsNotARef() {
        // Real-world title — we must NOT mistake this for an id ref.
        #expect(MediaRef(urlString: "Q&A: The Movie") == nil)
    }

    // MARK: - compatibleSources

    @Test("Each scheme maps to the arrs that can resolve it")
    func compatibleSources() {
        #expect(MediaRef.tmdb(1).compatibleSources == [.radarr, .whisparr])
        #expect(MediaRef.tvdb(1).compatibleSources == [.sonarr])
        #expect(MediaRef.musicBrainz("x").compatibleSources == [.lidarr])
        #expect(MediaRef.imdb("tt1").compatibleSources == [.radarr])
    }

    // MARK: - lookupTerm vs urlString distinction

    @Test("MusicBrainz looks up by bare GUID but keeps the mb: prefix in its URL form")
    func musicBrainzLookupTermIsBareGUID() {
        // Lidarr's /lookup expects bare GUID, not "mb:<guid>".
        #expect(MediaRef.musicBrainz("guid").lookupTerm == "guid")
        #expect(MediaRef.musicBrainz("guid").urlString == "mb:guid")
    }

    @Test("Every other scheme shares one form for lookup and URL")
    func otherSchemesShareLookupAndURLForm() {
        #expect(MediaRef.tmdb(1).lookupTerm == "tmdb:1")
        #expect(MediaRef.tmdb(1).urlString == "tmdb:1")
        #expect(MediaRef.tvdb(1).lookupTerm == "tvdb:1")
        #expect(MediaRef.imdb("tt1").lookupTerm == "imdb:tt1")
    }

    // MARK: - QueryParser

    @Test("QueryParser recognises every ref form")
    func parseRefForms() {
        #expect(QueryParser.parse("tmdb:42") == .ref(.tmdb(42)))
        #expect(QueryParser.parse("tvdb:99") == .ref(.tvdb(99)))
        #expect(QueryParser.parse("imdb:tt0133093") == .ref(.imdb("tt0133093")))
        #expect(QueryParser.parse("mb:abc") == .ref(.musicBrainz("abc")))
    }

    @Test("QueryParser passes plain text through, trimmed")
    func parseTextForms() {
        #expect(QueryParser.parse("Dune") == .text("Dune"))
        #expect(QueryParser.parse("  Dune  ") == .text("Dune"))
        // Title containing colon stays as text.
        #expect(QueryParser.parse("Q&A: The Movie") == .text("Q&A: The Movie"))
    }

    @Test("An empty or blank query parses to empty text")
    func parseEmpty() {
        #expect(QueryParser.parse("") == .text(""))
        #expect(QueryParser.parse("   ") == .text(""))
    }

    // MARK: - SearchInput

    @Test("arrTerm hands the arr the term it actually understands")
    func searchInputArrTerm() {
        #expect(SearchInput.text("Dune").arrTerm == "Dune")
        #expect(SearchInput.ref(.tmdb(42)).arrTerm == "tmdb:42")
        #expect(SearchInput.ref(.musicBrainz("guid")).arrTerm == "guid")
    }

    @Test("isRef distinguishes a ref query from a text query")
    func searchInputIsRef() {
        #expect(!SearchInput.text("x").isRef)
        #expect(SearchInput.ref(.tmdb(1)).isRef)
    }
}
