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
                case .discoverSession(let mood, let posterURLs):
                    DiscoverSessionCard(mood: mood,
                                        posterURLs: posterURLs,
                                        isResumable: isResumable)
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

private struct DiscoverSessionCard: View {
    let mood: String
    let posterURLs: [URL]
    let isResumable: Bool

    // All three cards at the same size — peek is achieved by offset only,
    // not scaling. The user wanted the stack to read as full-size cards
    // overlapping, not a fan of shrinking cards.
    private let cardWidth: CGFloat = 76
    private var cardHeight: CGFloat { cardWidth * 1.5 }   // 2:3 poster aspect

    // Offsets are generous enough that the corner of each back card is
    // visible past the front. Bigger offset = clearer "stack" reading.
    private let middleOffset: CGSize = CGSize(width: 14, height: 10)
    private let backOffset:   CGSize = CGSize(width: 28, height: 20)

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
        HStack(alignment: .top, spacing: 14) {
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
            if isResumable {
                Button {
                    NotificationCenter.default.post(
                        name: .arrBarrOpenDiscoverQuiz,
                        object: nil,
                        userInfo: ["openPicks": true]
                    )
                } label: {
                    Image(systemName: "list.star")
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(Text("Open your picks", bundle: .module))
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var stackVisual: some View {
        ZStack(alignment: .topLeading) {
            // Render back → middle → front so the front lands on top.
            cardLayer(posterURL: posterURLs.dropFirst(2).first,
                      offset: backOffset, opacity: 0.5)
            cardLayer(posterURL: posterURLs.dropFirst(1).first,
                      offset: middleOffset, opacity: 0.75)
            cardLayer(posterURL: posterURLs.first,
                      offset: .zero, opacity: 1.0, showBadge: true)
        }
        // Reserve enough room so the bottom-right corner of the back card
        // isn't clipped: cardWidth + backOffset.width / cardHeight + backOffset.height.
        .frame(width: cardWidth + backOffset.width,
               height: cardHeight + backOffset.height,
               alignment: .topLeading)
    }

    private func cardLayer(posterURL: URL?,
                           offset: CGSize,
                           opacity: Double,
                           showBadge: Bool = false) -> some View {
        ZStack {
            if let posterURL {
                RemotePoster(
                    url: posterURL,
                    apiKey: nil,
                    size: CGSize(width: cardWidth, height: cardHeight),
                    cornerRadius: 8
                )
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
                    )
                    .frame(width: cardWidth, height: cardHeight)
            }
            if showBadge {
                Image(systemName: isResumable
                      ? "rectangle.stack.fill.badge.play"
                      : "rectangle.stack.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .padding(6)
                    .frame(width: cardWidth, height: cardHeight, alignment: .bottomTrailing)
            }
        }
        .offset(x: offset.width, y: offset.height)
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
