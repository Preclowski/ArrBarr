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
    private let title: Text
    private let count: Int?

    /// Localized catalog key (the usual case).
    init(_ key: LocalizedStringKey, count: Int? = nil) {
        self.title = Text(key, bundle: .module)
        self.count = count
    }

    /// Verbatim server-side value (Lidarr's "EP" / "Single" release types).
    init(verbatim: String, count: Int? = nil) {
        self.title = Text(verbatim: verbatim)
        self.count = count
    }

    var body: some View {
        HStack(spacing: 6) {
            title
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
            if let count {
                Text(verbatim: "\(count)")
                    .scaledFont(size: 11)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
