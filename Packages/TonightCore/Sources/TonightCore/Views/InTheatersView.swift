import SwiftUI

/// The theatrical repertoire for the user's streaming region: what is on
/// screens right now, and what opens next — grouped by release month, with
/// the exact date under every poster.
struct InTheatersView: View {
    @EnvironmentObject private var config: TonightConfig

    enum Window: String, CaseIterable, Identifiable {
        case nowPlaying, comingSoon
        var id: String { rawValue }
        var title: String {
            switch self {
            case .nowPlaying: return String(localized: "Now Playing", bundle: .module)
            case .comingSoon: return String(localized: "Coming Soon", bundle: .module)
            }
        }
    }

    @State private var window: Window = .nowPlaying
    @State private var nowPlaying: [TMDBService.TheatricalItem] = []
    @State private var upcoming: [TMDBService.TheatricalItem] = []
    @State private var loading = true
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18, alignment: .top)]

    var body: some View {
        Group {
            if let error, shown.isEmpty {
                QuietMessage(systemImage: "wifi.slash",
                             title: String(localized: "Can't reach TMDB", bundle: .module),
                             subtitle: error,
                             action: (String(localized: "Retry", bundle: .module),
                                      { Task { await load() } }))
            } else if loading && shown.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { windowPicker }
        .task(id: "\(config.tmdbApiKey.hashValue)-\(config.watchRegion)") { await load() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(months, id: \.key) { month in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(month.title)
                                .font(.title3.weight(.semibold))
                            Text(String(format: String(localized: "%d titles", bundle: .module),
                                        month.entries.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 28)

                        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                            ForEach(month.entries) { entry in
                                VStack(alignment: .leading, spacing: 5) {
                                    PosterCard(item: entry.item, width: 150,
                                               siblings: shown.map(\.item))
                                    if let date = entry.releaseDate {
                                        Label {
                                            Text(date, format: .dateTime.day().month(.abbreviated))
                                        } icon: {
                                            Image(systemName: "calendar")
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 28)
                    }
                }
            }
            .padding(.top, 18)
            .padding(.bottom, 40)
        }
        .overlay {
            if shown.isEmpty && !loading {
                QuietMessage(systemImage: "popcorn",
                             title: String(localized: "Nothing scheduled", bundle: .module),
                             subtitle: String(localized: "TMDB lists no releases for your region right now.", bundle: .module))
            }
        }
    }

    private var windowPicker: some View {
        HStack {
            Picker(selection: $window) {
                ForEach(Window.allCases) { window in
                    Text(window.title).tag(window)
                }
            } label: { EmptyView() }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            Spacer()
            Text(config.watchRegion)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 28)
        .padding(.top, pageChromeTop)
        .padding(.bottom, 10)
        .background(.bar)
        .zIndex(1)
    }

    // MARK: - Shaping

    private var shown: [TMDBService.TheatricalItem] {
        window == .nowPlaying ? nowPlaying : upcoming
    }

    private struct Month: Identifiable {
        let key: String
        let title: String
        let entries: [TMDBService.TheatricalItem]
        var id: String { key }
    }

    /// Released titles read newest-first, upcoming ones soonest-first —
    /// both start from "closest to today".
    private var months: [Month] {
        let calendar = Calendar.current
        var groups: [String: [TMDBService.TheatricalItem]] = [:]
        var order: [String] = []
        let sorted = shown.sorted { a, b in
            let x = a.releaseDate ?? .distantPast
            let y = b.releaseDate ?? .distantPast
            return window == .nowPlaying ? x > y : x < y
        }
        for entry in sorted {
            guard let date = entry.releaseDate else { continue }
            let comps = calendar.dateComponents([.year, .month], from: date)
            let key = "\(comps.year ?? 0)-\(comps.month ?? 0)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(entry)
        }
        return order.compactMap { key in
            guard let entries = groups[key], let date = entries.first?.releaseDate else { return nil }
            return Month(key: key,
                         title: date.formatted(.dateTime.month(.wide).year()).capitalized,
                         entries: entries)
        }
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        defer { loading = false }
        error = nil
        let tmdb = TMDBService(apiKey: config.tmdbApiKey, region: config.watchRegion)
        do {
            async let playing1 = tmdb.theatrical(.nowPlaying, page: 1)
            async let playing2 = tmdb.theatrical(.nowPlaying, page: 2)
            async let soon1 = tmdb.theatrical(.upcoming, page: 1)
            async let soon2 = tmdb.theatrical(.upcoming, page: 2)
            let (p1, p2, s1, s2) = try await (playing1, playing2, soon1, soon2)
            let today = Calendar.current.startOfDay(for: .now)
            // TMDB's two windows overlap around today — split them on the
            // actual date so a title never shows up in both.
            let playing = dedup(p1 + p2 + s1 + s2).filter { ($0.releaseDate ?? .distantPast) <= today }
            let soon = dedup(s1 + s2 + p1 + p2).filter { ($0.releaseDate ?? .distantPast) > today }
            nowPlaying = playing
            upcoming = soon
        } catch {
            self.error = shortDescription(of: error)
        }
    }

    private func dedup(_ entries: [TMDBService.TheatricalItem]) -> [TMDBService.TheatricalItem] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.id).inserted }
    }
}
