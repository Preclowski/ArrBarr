import SwiftUI

/// Seasons and episodes of a series: the season picker plus the episode
/// list for whichever season is chosen. Episodes are fetched per season —
/// opening a show must not pull ten seasons of stills.
struct SeasonsSection: View {
    let show: MediaItem
    let seasons: [TitleDetails.SeasonSummary]

    @EnvironmentObject private var config: TonightConfig
    @State private var selected: Int
    @State private var season: SeasonDetails?
    @State private var error: String?
    @State private var expanded: Set<Int> = []

    init(show: MediaItem, seasons: [TitleDetails.SeasonSummary]) {
        self.show = show
        self.seasons = seasons
        // Open on the first real season; specials are a detour, never the
        // way into a show.
        _selected = State(initialValue: seasons.first { $0.seasonNumber > 0 }?.seasonNumber
            ?? seasons.first?.seasonNumber ?? 1)
    }

    private var current: TitleDetails.SeasonSummary? {
        seasons.first { $0.seasonNumber == selected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let overview = current?.overview ?? season?.overview, !overview.isEmpty {
                Text(overview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .frame(maxWidth: 760, alignment: .leading)
            }
            episodes
        }
        .padding(.horizontal, 28)
        .task(id: "\(show.tmdbId)-\(selected)") { await load() }
    }

    // MARK: - Picker

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Seasons", bundle: .module)
                .font(.title3.weight(.semibold))
            Menu {
                ForEach(seasons) { season in
                    Button {
                        selected = season.seasonNumber
                    } label: {
                        if season.seasonNumber == selected {
                            Label(seasonLabel(season), systemImage: "checkmark")
                        } else {
                            Text(seasonLabel(season))
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(current.map(seasonLabel) ?? "")
                        .font(.callout.weight(.medium))
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.hidden)
            .fixedSize()

            if let count = current?.episodeCount, count > 0 {
                Text(String(format: String(localized: "%d episodes", bundle: .module), count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let year = current?.year {
                Text(verbatim: "· \(year)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func seasonLabel(_ season: TitleDetails.SeasonSummary) -> String {
        // TMDB names real seasons "Season 3" already and specials
        // "Specials"; fall back only when it names one nothing at all.
        season.name.isEmpty
            ? String(format: String(localized: "Season %d", bundle: .module), season.seasonNumber)
            : season.name
    }

    // MARK: - Episodes

    @ViewBuilder
    private var episodes: some View {
        if let season {
            if season.episodes.isEmpty {
                Text("No episodes listed for this season yet.", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(season.episodes.enumerated()), id: \.element.id) { offset, episode in
                        if offset > 0 { Divider().opacity(0.5) }
                        row(episode)
                    }
                }
                .frame(maxWidth: 980, alignment: .leading)
            }
        } else if let error {
            QuietMessage(systemImage: "wifi.slash",
                         title: String(localized: "Can't load season", bundle: .module),
                         subtitle: error,
                         action: (String(localized: "Retry", bundle: .module),
                                  { Task { await load() } }))
        } else {
            ProgressView()
                .controlSize(.small)
                .padding(.vertical, 20)
        }
    }

    private func row(_ episode: SeasonDetails.Episode) -> some View {
        let isExpanded = expanded.contains(episode.id)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if isExpanded { expanded.remove(episode.id) } else { expanded.insert(episode.id) }
            }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                still(episode)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "\(episode.episodeNumber). \(episode.name)")
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let rating = episode.rating {
                            ScoreStrip(scores: ServiceScore.row(tmdb: rating), style: .inline)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    metaLine(episode)
                    if let overview = episode.overview {
                        Text(overview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .lineLimit(isExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }

    /// The frame grab, with the episode code over it — and a placeholder
    /// that keeps the row's rhythm when an episode has no still yet.
    private func still(_ episode: SeasonDetails.Episode) -> some View {
        RemoteImage(url: episode.stillURL)
            .frame(width: 172, height: 97)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                Text(verbatim: episode.code)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(6)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
    }

    private func metaLine(_ episode: SeasonDetails.Episode) -> some View {
        var parts: [String] = []
        if let date = episode.airDateValue {
            parts.append(date.formatted(.dateTime.day().month(.abbreviated).year()))
        }
        if let runtime = episode.runtimeMinutes {
            parts.append(Duration.seconds(runtime * 60)
                .formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        }
        return HStack(spacing: 8) {
            if !parts.isEmpty {
                Text(verbatim: parts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if episode.isUpcoming {
                Text("Upcoming", bundle: .module)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.18), in: Capsule())
            }
        }
    }

    private func load() async {
        error = nil
        season = nil
        expanded = []
        let tmdb = TMDBService(apiKey: config.tmdbApiKey, region: config.watchRegion)
        do {
            season = try await tmdb.season(showId: show.tmdbId, seasonNumber: selected)
        } catch {
            self.error = shortDescription(of: error)
        }
    }
}
