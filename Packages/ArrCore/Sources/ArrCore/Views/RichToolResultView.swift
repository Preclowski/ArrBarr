import SwiftUI

// MARK: - Public entry point

public struct RichToolResultView: View {
    let content: ChatRichContent
    let sonarr: ServiceConfig
    let radarr: ServiceConfig

    public init(content: ChatRichContent, sonarr: ServiceConfig, radarr: ServiceConfig) {
        self.content = content
        self.sonarr = sonarr
        self.radarr = radarr
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                switch content {
                case .searchMovieResults(let results):
                    ForEach(results) { r in
                        SearchResultCard(result: r, apiKey: radarr.apiKey)
                    }
                case .searchSeriesResults(let results):
                    ForEach(results) { r in
                        SearchResultCard(result: r, apiKey: sonarr.apiKey)
                    }
                case .libraryMovies(let recs):
                    ForEach(Array(recs.enumerated()), id: \.offset) { _, rec in
                        LibraryRecordCard(
                            title: rec.title ?? "(untitled)",
                            year: rec.year,
                            hasFile: rec.hasFile ?? false
                        )
                    }
                case .librarySeries(let recs):
                    ForEach(Array(recs.enumerated()), id: \.offset) { _, rec in
                        LibraryRecordCard(
                            title: rec.title ?? "(untitled)",
                            year: rec.year,
                            hasFile: false
                        )
                    }
                case .calendar(let items):
                    ForEach(items) { item in
                        CalendarRowView(item: item)
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
        .frame(minHeight: 180)
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
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
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
    let hasFile: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 90, height: 135)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                Image(systemName: hasFile ? "checkmark.circle.fill" : "questionmark.circle")
                    .foregroundStyle(hasFile ? .green : .orange)
                    .padding(6)
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
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

    var body: some View {
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
        .frame(width: 140, alignment: .leading)
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
