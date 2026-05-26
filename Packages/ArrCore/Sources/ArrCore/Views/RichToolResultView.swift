import SwiftUI

// MARK: - Public entry point

public struct RichToolResultView: View {
    let content: ChatRichContent
    let sonarr: ServiceConfig
    let radarr: ServiceConfig
    let lidarr: ServiceConfig
    let whisparr: ServiceConfig
    let blurWhisparr: Bool
    let isResumable: Bool

    @State private var visibleCount: Int = Self.pageSize
    private static let pageSize = 10

    public init(content: ChatRichContent, sonarr: ServiceConfig, radarr: ServiceConfig,
                lidarr: ServiceConfig = .empty, whisparr: ServiceConfig = .empty,
                blurWhisparr: Bool = true, isResumable: Bool = false) {
        self.content = content
        self.sonarr = sonarr
        self.radarr = radarr
        self.lidarr = lidarr
        self.whisparr = whisparr
        self.blurWhisparr = blurWhisparr
        self.isResumable = isResumable
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
                case .discoverSession(let mood):
                    DiscoverSessionCard(mood: mood, isResumable: isResumable)
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

    private var isOwned: Bool { result.inLibraryArrId != nil }

    var body: some View {
        Button(action: handleTap) {
            cardContent
        }
        .buttonStyle(.plain)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                PosterBlurContainer(blurred: blurred, cornerRadius: 6) {
                    RemotePoster(
                        url: result.posterURL,
                        apiKey: apiKey,
                        size: CGSize(width: 90, height: 135),
                        cornerRadius: 6
                    )
                }
                if isOwned {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .background(Circle().fill(Color.black.opacity(0.5)).padding(-2))
                        .padding(6)
                }
            }
            Text(result.title)
                .scaledFont(size: 12, weight: .semibold)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                if let year = result.year {
                    Text(String(year))
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                if let rating = result.rating {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .scaledFont(size: 9)
                        Text(String(format: "%.1f", rating))
                            .scaledFont(size: 10)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 100)
    }

    /// Owned results route to DetailView; missing ones go through the add
    /// flow. The owned check uses `inLibraryArrId` set by the TMDB handlers
    /// when they cross-reference results against the arr library. Missing
    /// items now route to the full `SearchAddPanel` overlay so the user gets
    /// the same hero card + form they'd see if they'd reached the result via
    /// the `+` search flow — SearchAddPanel is the single source of truth.
    private func handleTap() {
        if let arrId = result.inLibraryArrId {
            DetailRequest.post(
                DetailRequest.syntheticItem(
                    source: result.source,
                    entityId: arrId,
                    title: result.title,
                    posterURL: result.posterURL,
                    posterRequiresAuth: false
                )
            )
            return
        }
        SearchAddRequest.post(result)
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
                .scaledFont(size: 12, weight: .semibold)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let year {
                Text(String(year))
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 100)
    }
}

// MARK: - Discover session resume card

// MARK: - Discover session resume card

private struct DiscoverSessionCard: View {
    let mood: String
    let isResumable: Bool

    @EnvironmentObject private var discoverViewModel: DiscoverViewModel

    private let frontWidth: CGFloat = 64
    private var frontHeight: CGFloat { frontWidth * 1.5 }

    var body: some View {
        Group {
            if isResumable {
                Button(action: tap) { content }
                    .buttonStyle(.plain)
            } else {
                content.opacity(0.55)
            }
        }
        .padding(.vertical, 4)
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 12) {
            stackVisual
            VStack(alignment: .leading, spacing: 4) {
                Text(isResumable ? "Resume Discover" : "Discover session",
                     bundle: .module)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(.primary)
                Text(verbatim: "\u{201C}\(truncatedMood)\u{201D}")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 280, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Up to three posters (current + next 2 in queue). Empty when the
    /// session is non-resumable — older cards keep their silhouette.
    private var posters: [URL?] {
        guard isResumable else { return [] }
        var out: [URL?] = []
        if let current = discoverViewModel.current { out.append(current.result.posterURL) }
        for item in discoverViewModel.queue.prefix(3 - out.count) {
            out.append(item.result.posterURL)
        }
        return out
    }

    private var stackVisual: some View {
        ZStack(alignment: .topLeading) {
            // Back peek
            cardLayer(posterURL: posters.dropFirst(2).first ?? nil,
                      scale: 0.90, offsetX: 18, offsetY: 14, opacity: 0.5)
            // Middle peek
            cardLayer(posterURL: posters.dropFirst(1).first ?? nil,
                      scale: 0.95, offsetX: 9, offsetY: 7, opacity: 0.75)
            // Front
            cardLayer(posterURL: posters.first ?? nil,
                      scale: 1.0, offsetX: 0, offsetY: 0, opacity: 1.0,
                      showBadge: true)
        }
        .frame(width: frontWidth + 22, height: frontHeight + 18, alignment: .topLeading)
    }

    private func cardLayer(posterURL: URL?,
                           scale: CGFloat,
                           offsetX: CGFloat,
                           offsetY: CGFloat,
                           opacity: Double,
                           showBadge: Bool = false) -> some View {
        ZStack {
            if let posterURL {
                RemotePoster(
                    url: posterURL,
                    apiKey: nil,
                    size: CGSize(width: frontWidth, height: frontHeight),
                    cornerRadius: 6
                )
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
                    )
                    .frame(width: frontWidth, height: frontHeight)
            }
            if showBadge {
                Image(systemName: isResumable
                      ? "rectangle.stack.fill.badge.play"
                      : "rectangle.stack.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Circle().fill(Color.black.opacity(0.5)))
                    .padding(4)
                    .frame(width: frontWidth, height: frontHeight, alignment: .bottomTrailing)
            }
        }
        .scaleEffect(scale, anchor: .topLeading)
        .offset(x: offsetX, y: offsetY)
        .opacity(opacity)
    }

    private var truncatedMood: String {
        let trimmed = mood.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "\u{2026}" : trimmed
    }

    private func tap() {
        NotificationCenter.default.post(
            name: .arrBarrOpenDiscoverQuiz,
            object: nil,
            userInfo: ["resume": true]
        )
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
                    source: item.source,
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
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .scaledFont(size: 12, weight: .semibold)
                    .lineLimit(2)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .scaledFont(size: 11)
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

    private static func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
