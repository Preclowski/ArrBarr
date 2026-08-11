import SwiftUI

/// THE section header for detail surfaces — Cast, Seasons, Tracks, the
/// artist view's Album / EP / Single groups. One class so the voice can't
/// drift again: sentence case, 11pt semibold `.secondary`, optional item
/// count in `.tertiary` (the Upcoming tab's Today / Tomorrow treatment,
/// which the artist view established as the canonical style).
///
/// Callers that need extra chrome (the artist view's collapse chevron,
/// a trailing Spacer + accessory) wrap this in their own HStack — the
/// component owns only the title + count pair.
struct DetailSectionHeader: View {
    private enum Counter {
        case none
        case count(Int)
        /// "5/10" downloaded-of-total — the SeasonRow vocabulary lifted to
        /// the section level. Green when complete, tertiary otherwise.
        case progress(have: Int, total: Int)
    }

    private let title: Text
    private let counter: Counter

    /// Localized catalog key (the usual case).
    init(_ key: LocalizedStringKey, count: Int? = nil) {
        self.title = Text(key, bundle: .module)
        self.counter = count.map { .count($0) } ?? .none
    }

    /// Downloaded-of-total variant ("Episodes 5/10", "Tracks 8/12").
    init(_ key: LocalizedStringKey, have: Int, total: Int) {
        self.title = Text(key, bundle: .module)
        self.counter = .progress(have: have, total: total)
    }

    /// Verbatim server-side value (Lidarr's "EP" / "Single" release types).
    init(verbatim: String, count: Int? = nil) {
        self.title = Text(verbatim: verbatim)
        self.counter = count.map { .count($0) } ?? .none
    }

    var body: some View {
        HStack(spacing: 6) {
            title
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
            switch counter {
            case .none:
                EmptyView()
            case .count(let n):
                Text(verbatim: "\(n)")
                    .scaledFont(size: 11)
                    .foregroundStyle(.tertiary)
            case .progress(let have, let total):
                Text(verbatim: "\(have)/\(total)")
                    .scaledFont(size: 11, monospacedDigit: true)
                    .foregroundStyle(total > 0 && have >= total ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
            }
        }
    }
}
