import SwiftUI

/// One line worth reading while a long wait runs (indexer search, quiz deck).
nonisolated struct WaitFact: Hashable, Sendable {
    let text: String
}

/// Lines for the Quiz wait screens, from the local media-server snapshot.
enum WaitFacts {
    /// The viewer's own recent watching, from the media-server snapshot.
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
}

/// Cycles through `facts`, one line at a time, with a soft cross-fade. Draws
/// nothing when there is nothing to say, so callers can pass an empty list.
struct WaitFactTicker: View {
    let facts: [WaitFact]
    var interval: TimeInterval = 4
    var foreground: Color? = nil

    @State private var index = 0

    var body: some View {
        if !facts.isEmpty {
            Text(verbatim: facts[index % facts.count].text)
                .scaledFont(size: 12)
                .foregroundStyle(foreground ?? Color.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .id(index)
                .transition(.opacity)
                .frame(maxWidth: .infinity)
                .task(id: facts) {
                    guard facts.count > 1 else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(interval))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.35)) { index += 1 }
                    }
                }
        }
    }
}
