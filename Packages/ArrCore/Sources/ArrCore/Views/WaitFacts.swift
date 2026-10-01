import SwiftUI

/// One line worth reading while a long wait runs (indexer search, quiz deck).
nonisolated struct WaitFact: Hashable, Sendable {
    let text: String
}

/// Lines for the Quiz wait screens, from the local media-server snapshot.
enum WaitFacts {
    static func watching(index: MediaServerIndex = .shared, now: Date = .now) -> [WaitFact] {
        let history = index.recentlyWatched()
        guard !history.isEmpty else { return [] }
        var facts: [WaitFact] = []
        let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
        let recent = history.filter { ($0.watchedAt ?? .distantPast) >= cutoff }
        if !recent.isEmpty {
            facts.append(WaitFact(text: String(localized: "wait.quiz.finishedRecently \(recent.count)", bundle: .module)))
        }
        if let last = history.first {
            facts.append(WaitFact(text: String(localized: "wait.quiz.lastFinished \(last.title)", bundle: .module)))
        }
        return facts
    }

    /// From the arr library, so a quiz without a media server still has something to read.
    static func library(configStore: ConfigStore) async -> [WaitFact] {
        var facts: [WaitFact] = []
        if configStore.radarr.isConfigured {
            let movies = await LibraryIndex.shared.movies(config: configStore.radarr, revalidate: false)
            if !movies.isEmpty {
                facts.append(WaitFact(text: String(localized: "wait.quiz.libraryMovies \(movies.count)", bundle: .module)))
            }
            let dated = movies.compactMap { m in m.year.flatMap { $0 > 1800 ? (m.title, $0) : nil } }
            if let oldest = dated.min(by: { $0.1 < $1.1 }) {
                facts.append(WaitFact(text: String(localized: "wait.quiz.oldestMovie \(oldest.0) \(String(oldest.1))", bundle: .module)))
            }
        }
        if configStore.sonarr.isConfigured {
            let series = await LibraryIndex.shared.series(config: configStore.sonarr, revalidate: false)
            if !series.isEmpty {
                facts.append(WaitFact(text: String(localized: "wait.quiz.librarySeries \(series.count)", bundle: .module)))
            }
        }
        return facts
    }
}
