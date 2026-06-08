import SwiftUI

/// Picks collage — matches the chat-carousel `SearchResultCard` pattern
/// (poster + title + year/rating) and routes taps through the same
/// `DetailRequest` / `SearchAddRequest` pipeline. DetailView already knows
/// how to show an existing arr entity vs. pulling fresh metadata from
/// TMDB, so we don't repaint that branching here.
///
/// Removal lives in a right-click context menu — the collage stays a
/// single tappable surface like the chat carousel does.
public struct DiscoverMatchedListView: View {
    let items: [DiscoverItem]
    let onRemove: (DiscoverItem) -> Void

    public init(items: [DiscoverItem],
                onRemove: @escaping (DiscoverItem) -> Void) {
        self.items = items
        self.onRemove = onRemove
    }

    public var body: some View {
        if items.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sections, id: \.titleKey) { section in
                        sectionView(titleKey: section.titleKey, items: section.items)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder
    private func sectionView(titleKey: String, items: [DiscoverItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header only disambiguates when there are TWO sections
            // (owned vs. new). With a single section it's redundant noise under
            // the "Your picks" title, so callers pass an empty titleKey to hide it.
            if !titleKey.isEmpty {
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(titleKey), bundle: .module)
                        .scaledFont(size: 11, weight: .semibold)
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "\(items.count)")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ], alignment: .leading, spacing: 14) {
                ForEach(items) { item in
                    PickCard(item: item, onRemove: onRemove)
                }
            }
        }
    }

    /// Group picks by origin into ordered sections. Library items first
    /// (already owned — quickest to watch), then discoveries.
    private struct Section { let titleKey: String; let items: [DiscoverItem] }

    private var sections: [Section] {
        var library: [DiscoverItem] = []
        var discover: [DiscoverItem] = []
        for item in items {
            if item.result.inLibraryArrId != nil || item.originLabel == .library {
                library.append(item)
            } else {
                discover.append(item)
            }
        }
        var out: [Section] = []
        // New finds lead; "In library" groups last as the already-owned footer.
        // Only label the sections when BOTH exist — a lone section needs no
        // header (the page already says "Your picks").
        let bothPresent = !discover.isEmpty && !library.isEmpty
        if !discover.isEmpty { out.append(Section(titleKey: bothPresent ? "Discover" : "",   items: discover)) }
        if !library.isEmpty  { out.append(Section(titleKey: bothPresent ? "In library" : "", items: library)) }
        return out
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.stack")
                .scaledFont(size: 22, weight: .light)
                .foregroundStyle(.tertiary)
            Text("No picks yet — swipe right to collect", bundle: .module)
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - PickCard

/// Mirror of `SearchResultCard` from `RichToolResultView`: poster on top,
/// title underneath, year + rating row. Tap on the card opens the detail
/// surface — owned items route to `DetailRequest` (DetailView reads
/// existing arr metadata); discovery items route to `SearchAddRequest`
/// (the SearchAddPanel overlay handles the add flow).
private struct PickCard: View {
    let item: DiscoverItem
    let onRemove: (DiscoverItem) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // `fill: true` makes the poster expand to its caller-provided
            // frame instead of locking to a fixed 100×150. Without it the
            // poster stayed 100pt wide while the text below filled the
            // whole grid cell (~105–115pt depending on popover width),
            // so the title appeared to "extend past" the poster edge.
            // Now poster + text share the exact same column width.
            Color.clear
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(
                    RemotePoster(
                        url: item.result.posterURL,
                        apiKey: nil,
                        size: CGSize(width: 100, height: 150),
                        cornerRadius: 6,
                        fill: true
                    )
                )
            // Title clamped to one line — at poster-tile widths (~95pt)
            // two-line wrap of a 12pt title regularly bled past the
            // poster edge. Smaller font + single-line truncation keeps
            // text strictly inside the column. Full title is available
            // on hover (the help tooltip) for anything truncated.
            Text(item.result.title)
                .scaledFont(size: 11, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isHovering ? .primary : .secondary)
                .help(Text(verbatim: item.result.title))

            HStack(spacing: 6) {
                if let year = item.result.year {
                    Text(String(year))
                        .scaledFont(size: 10)
                        .foregroundStyle(.secondary)
                }
                if let rating = item.result.rating {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .scaledFont(size: 8)
                        Text(String(format: "%.1f", rating))
                            .scaledFont(size: 10)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
        // `.onTapGesture` on the whole VStack — `Button(.plain)` inside
        // `LazyVGrid` inside `ScrollView` has a known SwiftUI bug on
        // macOS where the hit-test misses on some cells. The tap gesture
        // hits reliably and the title-color accent on hover gives the
        // user a clear "this is clickable" signal.
        .onTapGesture { handleTap() }
        .contextMenu {
            Button(role: .destructive) {
                onRemove(item)
            } label: {
                Label {
                    Text("Remove from picks", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
    }

    /// Owned items → DetailView via DetailRequest (reads existing arr id).
    /// Fresh discovery items → SearchAddPanel via SearchAddRequest.
    /// Same routing as `SearchResultCard` in the chat carousel.
    private func handleTap() {
        if let arrId = item.result.inLibraryArrId {
            DetailRequest.post(
                DetailRequest.syntheticItem(
                    source: item.result.source,
                    entityId: arrId,
                    title: item.result.title,
                    posterURL: item.result.posterURL,
                    posterRequiresAuth: false
                )
            )
        } else {
            SearchAddRequest.post(item.result)
        }
    }
}
