import SwiftUI

// MARK: - Public entry point

public struct RichToolResultView: View {
    let content: ChatRichContent
    let sonarr: ServiceConfig
    let radarr: ServiceConfig
    let lidarr: ServiceConfig

    public init(content: ChatRichContent, sonarr: ServiceConfig, radarr: ServiceConfig, lidarr: ServiceConfig = .empty) {
        self.content = content
        self.sonarr = sonarr
        self.radarr = radarr
        self.lidarr = lidarr
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                switch content {
                case .searchMovieResults(let results):
                    ForEach(results) { r in
                        SearchResultCard(result: r, apiKey: radarr.apiKey)
                    }
                case .searchSeriesResults(let results):
                    ForEach(results) { r in
                        SearchResultCard(result: r, apiKey: sonarr.apiKey)
                    }
                case .searchArtistResults(let results):
                    ForEach(results) { r in
                        SearchResultCard(result: r, apiKey: lidarr.apiKey)
                    }
                case .libraryMovies(let recs):
                    ForEach(Array(recs.enumerated()), id: \.offset) { _, rec in
                        LibraryRecordCard(
                            title: rec.title ?? "(untitled)",
                            year: rec.year,
                            hasFile: rec.hasFile ?? false,
                            images: rec.images,
                            baseURL: radarr.baseURL,
                            apiKey: radarr.apiKey
                        )
                    }
                case .librarySeries(let recs):
                    ForEach(Array(recs.enumerated()), id: \.offset) { _, rec in
                        LibraryRecordCard(
                            title: rec.title ?? "(untitled)",
                            year: rec.year,
                            hasFile: nil,
                            images: rec.images,
                            baseURL: sonarr.baseURL,
                            apiKey: sonarr.apiKey
                        )
                    }
                case .libraryArtists(let recs):
                    ForEach(Array(recs.enumerated()), id: \.offset) { _, rec in
                        LibraryRecordCard(
                            title: rec.artistName ?? "(untitled)",
                            year: nil,
                            hasFile: nil,
                            images: rec.images,
                            baseURL: lidarr.baseURL,
                            apiKey: lidarr.apiKey
                        )
                    }
                case .calendar(let items):
                    ForEach(items) { item in
                        CalendarRowView(item: item, sonarrApiKey: sonarr.apiKey, radarrApiKey: radarr.apiKey, lidarrApiKey: lidarr.apiKey)
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        #if os(iOS)
        .scrollTargetBehavior(.viewAligned)
        #endif
    }
}

// MARK: - Search result card (has poster URL)

private struct SearchResultCard: View {
    let result: SearchResult
    let apiKey: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RemotePoster(
                url: result.posterURL,
                apiKey: apiKey,
                size: CGSize(width: 90, height: 135),
                cornerRadius: 6
            )
            Text(result.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                if let year = result.year {
                    Text(String(year))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let rating = result.rating {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                        Text(String(format: "%.1f", rating))
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 100)
    }
}

// MARK: - Library record card (no poster URL — placeholder)

private struct LibraryRecordCard: View {
    let title: String
    let year: Int?
    /// nil for series (they have season/episode statistics, not single-file).
    /// Bool for movies — true = downloaded, false = missing.
    let hasFile: Bool?
    let images: [ArrImage]?
    let baseURL: String
    let apiKey: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                RemotePoster(
                    url: images?.posterURL(baseURL: baseURL).0,
                    apiKey: apiKey,
                    size: CGSize(width: 90, height: 135),
                    cornerRadius: 6
                )
                if let hasFile {
                    Image(systemName: hasFile ? "checkmark.circle.fill" : "questionmark.circle")
                        .foregroundStyle(hasFile ? .green : .orange)
                        .background(Circle().fill(Color.black.opacity(0.5)).padding(-2))
                        .padding(6)
                }
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            if let year {
                Text(String(year))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 100)
    }
}

// MARK: - Calendar row

private struct CalendarRowView: View {
    let item: UpcomingItem
    let sonarrApiKey: String
    let radarrApiKey: String
    let lidarrApiKey: String

    private var apiKey: String {
        switch item.source {
        case .sonarr: return sonarrApiKey
        case .radarr: return radarrApiKey
        case .lidarr: return lidarrApiKey
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RemotePoster(
                url: item.posterURL,
                apiKey: item.posterRequiresAuth ? apiKey : nil,
                size: CGSize(width: 40, height: 60),
                cornerRadius: 4
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.dateLabel(item.airDate))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 200, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private static func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
