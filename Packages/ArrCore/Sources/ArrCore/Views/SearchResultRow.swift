import SwiftUI

public struct SearchResultRow: View {
    let result: SearchResult
    let onTap: () -> Void

    @EnvironmentObject var configStore: ConfigStore

    public var body: some View {
        PosterMetadataRow(
            posterURL: result.posterURL,
            posterAPIKey: nil,
            posterSize: CGSize(width: 26, height: 38),
            posterBlurred: configStore.shouldBlurPoster(for: result.source),
            title: titleWithYear,
            metadataSegments: metadataSegments,
            onTap: onTap
        ) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    /// "Title (1994)" — same idea as MediaHeaderCard. The year is just a
    /// year, so it joins the title rather than burning a metadata segment.
    private var titleWithYear: String {
        if let year = result.year {
            return "\(result.title) (\(year))"
        }
        return result.title
    }

    /// Second-line metadata. Arr's lookup endpoint hands us all of these in
    /// the same response that fetched the row, so showing them costs zero
    /// extra requests: subtitle (Sonarr "X seasons" / Lidarr disambiguation)
    /// → IMDb → RT → Metacritic → ★ (TMDB, when IMDb is missing) → runtime
    /// → certification. Filter to what's populated.
    private var metadataSegments: [String] {
        [
            result.subtitle.flatMap { $0.isEmpty ? nil : $0 },
            result.imdb.map { String(format: "IMDb %.1f", $0) },
            result.rottenTomatoes.map { "RT \(Int($0))%" },
            result.metacritic.map { "MC \(Int($0))" },
            result.imdb == nil ? result.rating.map { String(format: "★%.1f", $0) } : nil,
            result.runtime.flatMap { $0 > 0 ? "\($0) min" : nil },
            result.certification.flatMap { $0.isEmpty ? nil : $0 },
        ].compactMap { $0 }
    }
}
