import Testing
import AppKit
@testable import ArrCore

/// A misspelled `Image("rating-imbd")` builds cleanly and draws nothing, so the
/// names are checked against the compiled catalog.
@Suite struct RatingMarkAssetTests {
    @Test func ratingMarksAreAllPresent() {
        for name in ["rating-imdb", "rating-tmdb", "rating-rt", "rating-tvdb"] {
            #expect(Bundle.module.image(forResource: name) != nil, "\(name) is missing from ServiceIcons.xcassets")
        }
    }
}
