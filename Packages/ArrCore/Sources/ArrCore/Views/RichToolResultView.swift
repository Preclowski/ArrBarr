import SwiftUI

// MARK: - Public entry point

public struct RichToolResultView: View {
    let content: ChatRichContent
    let sonarr: ServiceConfig
    let radarr: ServiceConfig
    let lidarr: ServiceConfig
    let whisparr: ServiceConfig
    let blurWhisparr: Bool

    @State private var visibleCount: Int = Self.pageSize
    private static let pageSize = 10

    public init(content: ChatRichContent, sonarr: ServiceConfig, radarr: ServiceConfig,
                lidarr: ServiceConfig = .empty, whisparr: ServiceConfig = .empty,
                blurWhisparr: Bool = true) {
        self.content = content
        self.sonarr = sonarr
        self.radarr = radarr
        self.lidarr = lidarr
        self.whisparr = whisparr
        self.blurWhisparr = blurWhisparr
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                switch content {
                case .searchMovieResults(let results):
                    let visible = Array(results.prefix(visibleCount))
                    ForEach(visible) { r in
                        SearchResultCard(result: r, apiKey: radarr.apiKey)
                    }
                    if visible.count < results.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, results.count)
                        }
                    }
                case .searchSeriesResults(let results):
                    let visible = Array(results.prefix(visibleCount))
                    ForEach(visible) { r in
                        SearchResultCard(result: r, apiKey: sonarr.apiKey)
                    }
                    if visible.count < results.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, results.count)
                        }
                    }
                case .searchArtistResults(let results):
                    let visible = Array(results.prefix(visibleCount))
                    ForEach(visible) { r in
                        SearchResultCard(result: r, apiKey: lidarr.apiKey)
                    }
                    if visible.count < results.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, results.count)
                        }
                    }
                case .searchSceneResults(let results):
                    let visible = Array(results.prefix(visibleCount))
                    ForEach(visible) { r in
                        SearchResultCard(result: r, apiKey: whisparr.apiKey, blurred: blurWhisparr)
                    }
                    if visible.count < results.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, results.count)
                        }
                    }
                case .libraryMovies(let recs):
                    let visible = Array(recs.prefix(visibleCount))
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, rec in
                        LibraryRecordCard(
                            title: rec.title ?? "(untitled)",
                            year: rec.year,
                            hasFile: rec.hasFile ?? false,
                            images: rec.images,
                            baseURL: radarr.baseURL,
                            apiKey: radarr.apiKey,
                            source: .radarr,
                            entityId: rec.id
                        )
                    }
                    if visible.count < recs.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, recs.count)
                        }
                    }
                case .librarySeries(let recs):
                    let visible = Array(recs.prefix(visibleCount))
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, rec in
                        LibraryRecordCard(
                            title: rec.title ?? "(untitled)",
                            year: rec.year,
                            hasFile: nil,
                            images: rec.images,
                            baseURL: sonarr.baseURL,
                            apiKey: sonarr.apiKey,
                            source: .sonarr,
                            entityId: rec.id
                        )
                    }
                    if visible.count < recs.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, recs.count)
                        }
                    }
                case .libraryArtists(let recs):
                    let visible = Array(recs.prefix(visibleCount))
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, rec in
                        LibraryRecordCard(
                            title: rec.artistName ?? "(untitled)",
                            year: nil,
                            hasFile: nil,
                            images: rec.images,
                            baseURL: lidarr.baseURL,
                            apiKey: lidarr.apiKey,
                            source: .lidarr,
                            entityId: rec.id
                        )
                    }
                case .libraryScenes(let recs):
                    let visible = Array(recs.prefix(visibleCount))
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, rec in
                        LibraryRecordCard(
                            title: rec.title ?? "(untitled)",
                            year: rec.year,
                            hasFile: rec.hasFile ?? false,
                            images: rec.images,
                            baseURL: whisparr.baseURL,
                            apiKey: whisparr.apiKey,
                            source: .whisparr,
                            entityId: rec.id,
                            blurred: blurWhisparr
                        )
                    }
                    if visible.count < recs.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, recs.count)
                        }
                    }
                case .calendar(let items):
                    let visible = Array(items.prefix(visibleCount))
                    ForEach(visible) { item in
                        CalendarRowView(item: item, sonarrApiKey: sonarr.apiKey, radarrApiKey: radarr.apiKey,
                                        lidarrApiKey: lidarr.apiKey, whisparrApiKey: whisparr.apiKey,
                                        blurWhisparr: blurWhisparr)
                    }
                    if visible.count < items.count {
                        LoadMoreSentinel {
                            visibleCount = min(visibleCount + Self.pageSize, items.count)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: content) { _, _ in visibleCount = Self.pageSize }
        #if os(iOS)
        .scrollTargetBehavior(.viewAligned)
        #endif
    }
}

// MARK: - Load-more sentinel

private struct LoadMoreSentinel: View {
    let onAppear: () -> Void
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: 100, height: 180, alignment: .center)
            .task { onAppear() }
    }
}

// MARK: - Search result card (has poster URL)

private struct SearchResultCard: View {
    let result: SearchResult
    let apiKey: String
    var blurred: Bool = false

    var body: some View {
        Button(action: requestAdd) {
            cardContent
        }
        .buttonStyle(.plain)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            PosterBlurContainer(blurred: blurred, cornerRadius: 6) {
                RemotePoster(
                    url: result.posterURL,
                    apiKey: apiKey,
                    size: CGSize(width: 90, height: 135),
                    cornerRadius: 6
                )
            }
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

    private func requestAdd() {
        let intent = String(localized: "Add \(result.title)", bundle: .module)
        switch result.source {
        case .sonarr:
            AddRequest.post(
                toolName: "sonarr_add_series",
                draftArgs: .object(["tvdbId": .number(Double(result.id))]),
                userIntent: intent
            )
        case .radarr:
            AddRequest.post(
                toolName: "radarr_add_movie",
                draftArgs: .object(["tmdbId": .number(Double(result.id))]),
                userIntent: intent
            )
        case .lidarr:
            AddRequest.post(
                toolName: "lidarr_add_artist",
                draftArgs: .object(["foreignArtistId": .string(result.foreignId)]),
                userIntent: intent
            )
        case .whisparr:
            AddRequest.post(
                toolName: "whisparr_add_scene",
                draftArgs: .object(["foreignId": .string(result.foreignId)]),
                userIntent: intent
            )
        }
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
    let source: QueueItem.Source
    let entityId: Int?
    var blurred: Bool = false

    var body: some View {
        Button {
            guard let entityId else { return }
            let url = images?.posterURL(baseURL: baseURL).0
            DetailRequest.post(
                DetailRequest.syntheticItem(
                    source: source,
                    entityId: entityId,
                    title: title,
                    posterURL: url
                )
            )
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
        .disabled(entityId == nil)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                PosterBlurContainer(blurred: blurred, cornerRadius: 6) {
                    RemotePoster(
                        url: images?.posterURL(baseURL: baseURL).0,
                        apiKey: apiKey,
                        size: CGSize(width: 90, height: 135),
                        cornerRadius: 6
                    )
                }
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
    var whisparrApiKey: String = ""
    var blurWhisparr: Bool = false

    private var effectivelyBlurred: Bool {
        item.source == .whisparr && blurWhisparr
    }

    private var apiKey: String {
        switch item.source {
        case .sonarr: return sonarrApiKey
        case .radarr: return radarrApiKey
        case .lidarr: return lidarrApiKey
        case .whisparr: return whisparrApiKey
        }
    }

    var body: some View {
        Button {
            guard let entityId = item.entityId else { return }
            DetailRequest.post(
                DetailRequest.syntheticItem(
                    source: queueSource,
                    entityId: entityId,
                    title: item.title,
                    posterURL: item.posterURL,
                    posterRequiresAuth: item.posterRequiresAuth
                )
            )
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
        .disabled(item.entityId == nil)
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 8) {
            PosterBlurContainer(blurred: effectivelyBlurred, cornerRadius: 4) {
                RemotePoster(
                    url: item.posterURL,
                    apiKey: item.posterRequiresAuth ? apiKey : nil,
                    size: CGSize(width: 40, height: 60),
                    cornerRadius: 4
                )
            }
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
        .contentShape(Rectangle())
    }

    private var queueSource: QueueItem.Source {
        switch item.source {
        case .radarr: return .radarr
        case .sonarr: return .sonarr
        case .lidarr: return .lidarr
        case .whisparr: return .whisparr
        }
    }

    private static func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
