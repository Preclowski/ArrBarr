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
@Suite struct BrandMarkAssetTests {
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

    @Test func everyBrandServiceAssetExists() throws {
        let available = try Self.imageSets()
        for service in BrandService.allCases {
            if let name = service.assetName {
                #expect(available.contains(name),
                        "\(service.rawValue).assetName is \"\(name)\", which is not in ServiceIcons.xcassets")
            }
            if let mono = service.monoAssetName {
                #expect(available.contains(mono),
                        "\(service.rawValue).monoAssetName is \"\(mono)\", which is not in ServiceIcons.xcassets")
            }
        }
    }

    /// The marks the ratings rows draw in BOTH apps. Spelled out rather than
    /// derived so that deleting one of these assets fails here by name — this
    /// is the set a title page is built around.
    @Test func ratingMarksAreAllPresent() throws {
        let available = try Self.imageSets()
        for name in ["rating-imdb", "rating-tmdb", "rating-rt", "rating-tvdb",
                     "rating-imdb-mono", "rating-tmdb-mono", "rating-tvdb-mono"] {
            #expect(available.contains(name), "\(name) is missing from ServiceIcons.xcassets")
        }
    }

    /// A service that ships no mark must name a real SF Symbol instead —
    /// a bad symbol name is the same silent blank as a bad asset name.
    @Test func fallbackSymbolsAreRealSymbols() {
        for service in BrandService.allCases {
            #if os(macOS)
            let exists = PlatformImage(systemSymbolName: service.fallbackSymbol,
                                       accessibilityDescription: nil) != nil
            #else
            let exists = PlatformImage(systemName: service.fallbackSymbol) != nil
            #endif
            #expect(exists,
                    "\(service.rawValue).fallbackSymbol \"\(service.fallbackSymbol)\" is not an SF Symbol")
        }
    }

    /// Names that arrive as data — a `MediaKit.RatingService` case, a media
    /// server's own name — must land on the right service. "rt" is the one
    /// that is not simply the lowercased case name.
    @Test func lenientLookupCoversTheNamesDataUses() {
        #expect(BrandService(name: "rt") == .rottenTomatoes)
        #expect(BrandService(name: "rottenTomatoes") == .rottenTomatoes)
        #expect(BrandService(name: "Rotten Tomatoes") == .rottenTomatoes)
        #expect(BrandService(name: "IMDb") == .imdb)
        #expect(BrandService(name: "tvdb") == .tvdb)
        #expect(BrandService(name: "Plex") == .plex)
        // Unknown stays unknown: the caller draws its own placeholder rather
        // than being handed a wrong mark.
        #expect(BrandService(name: "netflix") == nil)
    }
}
