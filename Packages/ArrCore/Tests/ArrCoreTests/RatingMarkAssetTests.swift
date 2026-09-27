import Testing
import Foundation
@testable import ArrCore

/// Asset names are the one kind of reference the compiler cannot check: a
/// misspelled `Image("rating-imbd")` builds cleanly and draws NOTHING — no
/// crash, no log, just a gap where a logo should be. On top of that, `swift
/// build` does not compile asset catalogs at all, so nothing under `swift test`
/// can render one and notice.
///
/// This checks the catalog on disk instead of the rendered image, which works
/// in both build systems: SwiftPM copies `ServiceIcons.xcassets` into the
/// bundle verbatim, and every image set is a directory named after the asset.
/// That is enough to catch the whole class of bug — a name that no longer
/// resolves.
@Suite struct RatingMarkAssetTests {
    private static func imageSets() throws -> Set<String> {
        let catalog = try #require(
            Bundle.module.url(forResource: "ServiceIcons", withExtension: "xcassets"),
            "ServiceIcons.xcassets is missing from the bundle entirely")
        let entries = try FileManager.default.contentsOfDirectory(
            at: catalog, includingPropertiesForKeys: nil)
        return Set(entries
            .filter { $0.pathExtension == "imageset" }
            .map { $0.deletingPathExtension().lastPathComponent })
    }

    /// The marks the ratings rows draw. Spelled out rather than
    /// derived so that deleting one of these assets fails here by name — this
    /// is the set a title page is built around.
    @Test func ratingMarksAreAllPresent() throws {
        let available = try Self.imageSets()
        for name in ["rating-imdb", "rating-tmdb", "rating-rt", "rating-tvdb"] {
            #expect(available.contains(name), "\(name) is missing from ServiceIcons.xcassets")
        }
    }
}
