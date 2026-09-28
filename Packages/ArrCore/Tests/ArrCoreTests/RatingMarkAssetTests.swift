import Testing
import AppKit
@testable import ArrCore

/// A misspelled `Image("rating-imbd")` builds cleanly and draws nothing. Xcode 27's SwiftPM
/// compiles the catalog into Assets.car, CI's Xcode 26 copies it verbatim; either shape counts.
@Suite struct RatingMarkAssetTests {
    @Test func ratingMarksAreAllPresent() {
        let copiedCatalog = Bundle.module.url(forResource: "ServiceIcons", withExtension: "xcassets")
        for name in ["rating-imdb", "rating-tmdb", "rating-rt", "rating-tvdb"] {
            let compiled = Bundle.module.image(forResource: name) != nil
            let copied = copiedCatalog.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(name).imageset").path)
            } ?? false
            #expect(compiled || copied, "\(name) is missing from ServiceIcons.xcassets")
        }
    }
}
