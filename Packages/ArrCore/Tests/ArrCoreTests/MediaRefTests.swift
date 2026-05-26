import XCTest
@testable import ArrCore

final class MediaRefTests: XCTestCase {
    // MARK: - urlString round-trip

    func testTMDBRoundTrip() {
        let ref = MediaRef.tmdb(12345)
        XCTAssertEqual(ref.urlString, "tmdb:12345")
        XCTAssertEqual(MediaRef(urlString: "tmdb:12345"), .tmdb(12345))
    }

    func testTVDBRoundTrip() {
        let ref = MediaRef.tvdb(67890)
        XCTAssertEqual(ref.urlString, "tvdb:67890")
        XCTAssertEqual(MediaRef(urlString: "tvdb:67890"), .tvdb(67890))
    }

    func testIMDBRoundTrip() {
        let ref = MediaRef.imdb("tt0133093")
        XCTAssertEqual(ref.urlString, "imdb:tt0133093")
        XCTAssertEqual(MediaRef(urlString: "imdb:tt0133093"), .imdb("tt0133093"))
    }

    func testMusicBrainzRoundTrip() {
        let ref = MediaRef.musicBrainz("abc-def-ghi")
        XCTAssertEqual(ref.urlString, "mb:abc-def-ghi")
        XCTAssertEqual(MediaRef(urlString: "mb:abc-def-ghi"), .musicBrainz("abc-def-ghi"))
    }

    // MARK: - Parser leniency

    func testIMDBAcceptsBareDigits() {
        // Caller forgets the "tt" prefix — we normalise it.
        XCTAssertEqual(MediaRef(urlString: "imdb:0133093"), .imdb("tt0133093"))
    }

    func testMusicBrainzAcceptsAliases() {
        XCTAssertEqual(MediaRef(urlString: "musicbrainz:guid-123"), .musicBrainz("guid-123"))
        XCTAssertEqual(MediaRef(urlString: "lidarr:guid-123"), .musicBrainz("guid-123"))
    }

    func testCaseInsensitiveScheme() {
        XCTAssertEqual(MediaRef(urlString: "TMDB:42"), .tmdb(42))
        XCTAssertEqual(MediaRef(urlString: "Tvdb:42"), .tvdb(42))
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(MediaRef(urlString: "  tmdb:42  "), .tmdb(42))
    }

    // MARK: - Parser rejection

    func testRejectsMalformed() {
        XCTAssertNil(MediaRef(urlString: ""))
        XCTAssertNil(MediaRef(urlString: "tmdb:"))           // empty payload
        XCTAssertNil(MediaRef(urlString: "tmdb:notanumber")) // non-numeric
        XCTAssertNil(MediaRef(urlString: "tvdb:abc"))
        XCTAssertNil(MediaRef(urlString: "Dune"))            // no colon → plain text
        XCTAssertNil(MediaRef(urlString: "unknown:42"))      // unknown scheme
    }

    func testTextWithColonIsNotARef() {
        // Real-world title — we must NOT mistake this for an id ref.
        XCTAssertNil(MediaRef(urlString: "Q&A: The Movie"))
    }

    // MARK: - compatibleSources

    func testCompatibleSources() {
        XCTAssertEqual(MediaRef.tmdb(1).compatibleSources, [.radarr, .whisparr])
        XCTAssertEqual(MediaRef.tvdb(1).compatibleSources, [.sonarr])
        XCTAssertEqual(MediaRef.musicBrainz("x").compatibleSources, [.lidarr])
        XCTAssertEqual(MediaRef.imdb("tt1").compatibleSources, [.radarr])
    }

    // MARK: - lookupTerm vs urlString distinction

    func testMusicBrainzLookupTermIsBareGUID() {
        // Lidarr's /lookup expects bare GUID, not "mb:<guid>".
        XCTAssertEqual(MediaRef.musicBrainz("guid").lookupTerm, "guid")
        XCTAssertEqual(MediaRef.musicBrainz("guid").urlString, "mb:guid")
    }

    func testOtherSchemesShareLookupAndURLForm() {
        XCTAssertEqual(MediaRef.tmdb(1).lookupTerm, "tmdb:1")
        XCTAssertEqual(MediaRef.tmdb(1).urlString,  "tmdb:1")
        XCTAssertEqual(MediaRef.tvdb(1).lookupTerm, "tvdb:1")
        XCTAssertEqual(MediaRef.imdb("tt1").lookupTerm, "imdb:tt1")
    }

    // MARK: - QueryParser

    func testParseRefForms() {
        if case .ref(.tmdb(42)) = QueryParser.parse("tmdb:42") {} else { XCTFail() }
        if case .ref(.tvdb(99)) = QueryParser.parse("tvdb:99") {} else { XCTFail() }
        if case .ref(.imdb("tt0133093")) = QueryParser.parse("imdb:tt0133093") {} else { XCTFail() }
        if case .ref(.musicBrainz("abc")) = QueryParser.parse("mb:abc") {} else { XCTFail() }
    }

    func testParseTextForms() {
        if case .text("Dune") = QueryParser.parse("Dune") {} else { XCTFail() }
        if case .text("Dune") = QueryParser.parse("  Dune  ") {} else { XCTFail() }
        // Title containing colon stays as text.
        if case .text("Q&A: The Movie") = QueryParser.parse("Q&A: The Movie") {} else { XCTFail() }
    }

    func testParseEmpty() {
        if case .text("") = QueryParser.parse("") {} else { XCTFail() }
        if case .text("") = QueryParser.parse("   ") {} else { XCTFail() }
    }

    // MARK: - SearchInput

    func testSearchInputArrTerm() {
        XCTAssertEqual(SearchInput.text("Dune").arrTerm, "Dune")
        XCTAssertEqual(SearchInput.ref(.tmdb(42)).arrTerm, "tmdb:42")
        XCTAssertEqual(SearchInput.ref(.musicBrainz("guid")).arrTerm, "guid")
    }

    func testSearchInputIsRef() {
        XCTAssertFalse(SearchInput.text("x").isRef)
        XCTAssertTrue(SearchInput.ref(.tmdb(1)).isRef)
    }
}
