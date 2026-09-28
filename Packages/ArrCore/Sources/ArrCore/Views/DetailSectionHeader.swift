import SwiftUI

/// The one section header for detail surfaces. Owns only the title + count pair;
/// callers needing extra chrome wrap it in their own HStack.
struct DetailSectionHeader: View {
    private enum Counter {
        case none
        case count(Int)
        /// "5/10" downloaded-of-total; green when complete.
        case progress(have: Int, total: Int)
    }

    private let title: Text
    private let counter: Counter

    init(_ key: LocalizedStringKey, count: Int? = nil) {
        self.title = Text(key, bundle: .module)
        self.counter = count.map { .count($0) } ?? .none
    }

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
                // Not `.secondary`: the popover's vibrant text makes it read half-transparent.
                // The count keeps the lower level.
                .foregroundStyle(.primary)
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
