import SwiftUI

/// The most common genres as chips, counted over the titles the other filters leave; a genre that would empty the
/// set is greyed out. Shared by the Roulette's filter panel and the Library's filter popover.
struct GenreChipCloud: View {
    @Binding var genre: String?
    /// The whole set: the chip order comes from it, so no chip moves while narrowing.
    let all: [LibraryEntry]
    /// Every filter but the genre.
    let narrowed: (LibraryEntry) -> Bool
    var compact = false
    @Environment(\.locale) private var locale

    var body: some View {
        TooltipFlowLayout(spacing: compact ? 4 : 5) {
            chip(Text("shelf.filter.anyGenre", bundle: .module), count: nil, on: genre == nil) { genre = nil }
            ForEach(genres, id: \.name) { g in
                chip(Text(verbatim: GenreName.localized(g.name, locale: locale)), count: g.count, on: genre == g.name) {
                    genre = g.name
                }
                .disabled(g.count == 0 && genre != g.name)
            }
        }
    }

    private func chip(_ label: Text, count: Int?, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                label
                if let count {
                    Text(count, format: .number).scaledFont(size: compact ? 10 : 10.5).monospacedDigit().opacity(0.5)
                }
            }
            .scaledFont(size: compact ? 11 : 11.5, weight: .medium)
            .foregroundStyle(on ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
            .padding(.horizontal, compact ? 8 : 9)
            .frame(height: compact ? 22 : 24)
            .background(Capsule().fill(on ? Color.primary.opacity(0.92) : Color.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Most common first; a long tail of one-off genres would bury the useful ones.
    private var genres: [(name: String, count: Int)] {
        var order: [String: Int] = [:]
        var counts: [String: Int] = [:]
        for entry in all {
            let kept = narrowed(entry)
            for genre in entry.genres {
                order[genre, default: 0] += 1
                if kept { counts[genre, default: 0] += 1 }
            }
        }
        return order.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(20).map { ($0.key, counts[$0.key] ?? 0) }
    }
}

/// Decades as a bar chart, oldest to newest with the empty ones in between, so it reads as a timeline.
struct DecadeHistogram: View {
    @Binding var decade: Int?
    /// The bar under the pointer, for the section's hint.
    @Binding var hovered: Int?
    let all: [LibraryEntry]
    /// Every filter but the decade.
    let narrowed: (LibraryEntry) -> Bool
    var compact = false

    static func decades(in entries: [LibraryEntry]) -> [Int] {
        let all = entries.compactMap { $0.year.map { $0 / 10 * 10 } }.filter { $0 > 1800 }
        guard let lo = all.min(), let hi = all.max() else { return [] }
        return Array(stride(from: lo, through: hi, by: 10))
    }

    var body: some View {
        var counts: [Int: Int] = [:]
        for entry in all where narrowed(entry) {
            if let year = entry.year { counts[year / 10 * 10, default: 0] += 1 }
        }
        let most = max(1, counts.values.max() ?? 1)
        let tallest: CGFloat = compact ? 28 : 30
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Self.decades(in: all), id: \.self) { d in
                let n = counts[d] ?? 0
                let on = decade == d
                Button { decade = on ? nil : d } label: {
                    VStack(spacing: compact ? 3 : 4) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.primary.opacity(on ? 0.92 : n == 0 ? 0.08 : hovered == d ? 0.5 : 0.24))
                            .frame(height: n == 0 ? 2 : 5 + tallest * CGFloat(n) / CGFloat(most))
                        Text(verbatim: String(d))
                            .scaledFont(size: compact ? 9 : 9.5, weight: on ? .semibold : .regular)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(on ? .primary : .tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(n == 0 && !on)
                .onHover { inside in
                    if inside { hovered = d } else if hovered == d { hovered = nil }
                }
            }
        }
        .frame(height: compact ? 50 : 54)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: decade)
    }
}

/// The decade hint over a histogram: the hovered or picked range, or "all years".
struct DecadeHint: View {
    let decade: Int?

    var body: some View {
        if let decade {
            Text(verbatim: "\(decade)–\(decade + 9)")
        } else {
            Text("shelf.filter.anyYear", bundle: .module)
        }
    }
}
