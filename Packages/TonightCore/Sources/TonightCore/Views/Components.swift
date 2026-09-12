import SwiftUI
import AppKit
import SwiftData
import ArrCore

// MARK: - Remote image

/// AsyncImage with a stable placeholder. Relies on URLCache (bumped at app
/// startup) — TMDB images are immutable, so plain HTTP caching is enough.
/// Decoded artwork, shared by every `RemoteImage`. `URLCache` spares the
/// network but not the decode, and `AsyncImage` drops to its placeholder for
/// a frame whenever its URL changes — which is what made the Quiz deck flash
/// the card underneath when the top card left. NSCache is thread-safe, so
/// this lives outside the main actor and can be primed from anywhere.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, NSImage>()

    private init() { cache.countLimit = 400 }

    func image(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func store(_ image: NSImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }

    /// Decode ahead of time, so a picture about to be shown is already in the
    /// cache when it appears. The Quiz primes the cards below the top one.
    func prefetch(_ url: URL?) {
        guard let url, image(for: url) == nil else { return }
        Task.detached(priority: .utility) { [self] in
            guard let image = await Self.download(url) else { return }
            store(image, for: url)
        }
    }

    static func download(_ url: URL) async -> NSImage? {
        var request = URLRequest(url: url)
        // TMDB art is immutable: whatever the shared cache holds is good.
        request.cachePolicy = .returnCacheDataElseLoad
        // A poster served by the user's own Plex/Jellyfin needs their token.
        // It travels in a header, never in the URL — the URL is cached and
        // persisted, and a rotated token in it would poison both.
        for (field, value) in MediaServerPosterAccess.shared.headers(for: url) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return NSImage(data: data)
    }
}

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    /// The grey block that stands in for a poster while it loads. Wrong for
    /// artwork on transparency (a clear logo), where nothing is the right
    /// placeholder.
    var showsPlaceholder = true

    @State private var loaded: NSImage?

    /// Already decoded: rendered on this very pass, with no blank frame.
    private var cached: NSImage? { url.flatMap { ImageCache.shared.image(for: $0) } }

    var body: some View {
        Group {
            if let image = cached ?? loaded {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    // Swap hard. Under an enclosing animation (the Quiz deck
                    // moving on) SwiftUI crossfades a changed image by
                    // default, which blended the departing poster into the
                    // new one — the blink.
                    .contentTransition(.identity)
            } else if showsPlaceholder {
                Rectangle().fill(.quaternary)
            } else {
                Color.clear
            }
        }
        // No implicit animation on the swap: a picture already in the cache
        // must appear at once. Animating it crossfaded the old poster into
        // the new one — the blink when the Quiz deck moved on. Only a fresh
        // download fades in, from where it is set.
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url, cached == nil else { return }
        loaded = nil
        guard let image = await ImageCache.download(url), !Task.isCancelled else { return }
        ImageCache.shared.store(image, for: url)
        withAnimation(.easeOut(duration: 0.18)) { loaded = image }
    }
}

/// A backdrop banner cropped from the TOP rather than the middle — faces and
/// titles live in a backdrop's upper half, and a centred crop cut them off.
/// The image is laid out at its full filled height and the box clips the
/// bottom; cropping inside `RemoteImage` instead left heros blank whenever
/// the inner layout measured zero.
struct HeroBanner: View {
    let url: URL?
    let height: CGFloat

    var body: some View {
        // The image is laid out into a box a third taller than the visible
        // one and then clipped from the top, so the crop favours the upper
        // part of the frame. No GeometryReader: measuring the row from
        // inside it returned zero in the paging carousel and those slides
        // came up blank.
        RemoteImage(url: url)
            // minWidth: 0 is load-bearing. An aspect-fill image in a frame
            // this tall reports a minimum width of height x its ratio, and
            // that minimum travelled all the way up to the window, which
            // then refused to be narrowed. The banner takes whatever width
            // it is given and crops.
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: height * 1.3)
            .frame(height: height, alignment: .top)
            .clipped()
    }
}

// MARK: - Poster card

public struct PosterCard: View {
    let item: MediaItem
    var width: CGFloat = 150
    /// Wide 16:9 backdrop card instead of the tall 2:3 poster.
    var wide: Bool = false
    /// The collection this card sits in — the detail page browses through
    /// it with previous/next.
    var siblings: [MediaItem]? = nil
    /// Selection mode: non-nil replaces navigation with a select toggle.
    var selected: Bool? = nil
    var onSelect: (() -> Void)? = nil
    /// One extra line under the title — the person page puts the role there.
    var subtitle: String? = nil

    @State private var hovering = false
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var externalLibrary: ExternalLibraryStore

    public init(item: MediaItem, width: CGFloat = 150) {
        self.item = item
        self.width = width
    }

    init(item: MediaItem, width: CGFloat = 150, wide: Bool = false,
         siblings: [MediaItem]? = nil,
         selected: Bool? = nil, onSelect: (() -> Void)? = nil,
         subtitle: String? = nil) {
        self.item = item
        self.width = width
        self.wide = wide
        self.siblings = siblings
        self.selected = selected
        self.onSelect = onSelect
        self.subtitle = subtitle
    }

    public var body: some View {
        if let onSelect {
            Button(action: onSelect) { card }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
        } else {
            NavigationLink(value: selectionValue) { card }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .contextMenu {
                    WatchedToggle(item: item)
                    AddToListMenu(item: item)
                }
        }
    }

    private var selectionValue: TitleSelection {
        if let siblings, let index = siblings.firstIndex(where: { $0.id == item.id }) {
            return TitleSelection(items: siblings, index: index)
        }
        return TitleSelection(items: [item], index: 0)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 7) {
            RemoteImage(url: wide ? (item.displayCardBackdropURL ?? item.displayPosterURL)
                                  : item.displayPosterURL)
                .frame(width: width, height: wide ? width * 9 / 16 : width * 1.5)
                .overlay(alignment: .bottomTrailing) {
                    if isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .shadow(color: .black.opacity(0.6), radius: 3)
                            .padding(7)
                    }
                }
                .overlay {
                    if selected == true {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.blue.opacity(0.22))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let selected {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, selected ? .blue : .black.opacity(0.4))
                            .shadow(color: .black.opacity(0.5), radius: 3)
                            .padding(7)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected == true ? AnyShapeStyle(.blue) : AnyShapeStyle(.white.opacity(0.10)),
                                      lineWidth: selected == true ? 2 : 1)
                )
                .shadow(color: .black.opacity(hovering ? 0.35 : 0.18),
                        radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
                .scaleEffect(hovering ? 1.045 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hovering)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Scores are always written with their service's mark —
                // the caption gets the same control as everything else.
                ScoreStrip(scores: ServiceScore.row(tmdb: item.rating, votes: item.voteCount),
                           style: .inline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: width, alignment: .leading)
        }
    }

    private var isWatched: Bool {
        if Library.existingTitle(for: item, in: context)?.watchedAt != nil { return true }
        return externalLibrary.isWatched(item)
    }
}

// MARK: - Shelf

/// A horizontal Apple-TV-style shelf: title + scrolling row of cards, with
/// paging chevrons floating in at the edges on hover.
///
/// The row is generic in what it holds — posters on Home, the Discover
/// tiles — because the paging is the shelf's whole substance and every
/// screen that grew a row of its own used to copy it: the leading-anchored
/// scroll position, the "how many whole cards fit" arithmetic, the hover
/// chevrons.
struct CardShelf<Item: Identifiable, Card: View, Destination: Hashable>: View
where Item.ID: Hashable {
    let title: String
    let items: [Item]
    /// One card's width — what a chevron click pages by, together with the
    /// 16pt gutter between them.
    let cardWidth: CGFloat
    /// Where the heading leads: the whole category as a page of its own. A
    /// row without one draws a plain title.
    var destination: Destination? = nil
    @ViewBuilder let card: (Item) -> Card

    @State private var hovering = false
    @State private var hoveringTitle = false
    @State private var leading: Item.ID?
    @State private var rowWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading
                .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        card(item)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 28)
                .padding(.vertical, 10) // room for hover lift shadow
            }
            .scrollClipDisabled()
            // A shelf opens on its first card. Without this it inherits the
            // page's anchor, and `.top` — x = 0.5 — opened a row that already
            // had all its cards centred, four tiles in.
            .defaultScrollAnchor(.leading)
            .scrollPosition(id: $leading, anchor: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            .overlay(alignment: .leading) {
                if hovering && currentIndex > 0 {
                    PagingChevron(direction: .previous) { page(by: -1) }
                        .padding(.leading, 2)
                }
            }
            .overlay(alignment: .trailing) {
                if hovering && currentIndex + pageSize < items.count {
                    PagingChevron(direction: .next) { page(by: 1) }
                        .padding(.trailing, 2)
                }
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    /// The heading is the way into the whole category, the way a shelf title
    /// is on Apple TV: the chevron says there is more behind it, and a row
    /// can be scrolled through or opened whole.
    @ViewBuilder
    private var heading: some View {
        if let destination {
            NavigationLink(value: destination) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .opacity(hovering || hoveringTitle ? 1 : 0.55)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { hoveringTitle = $0 }
        } else {
            Text(title)
                .font(.title3.weight(.semibold))
        }
    }

    /// How many whole cards fit in view — one chevron click pages by that.
    private var pageSize: Int {
        max(1, Int((rowWidth - 56) / (cardWidth + 16)))
    }

    private var currentIndex: Int {
        leading.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
    }

    private func page(by delta: Int) {
        guard !items.isEmpty else { return }
        let target = min(max(0, currentIndex + delta * pageSize), items.count - 1)
        withAnimation(.easeOut(duration: 0.35)) { leading = items[target].id }
    }
}

extension CardShelf where Destination == Int {
    /// A shelf whose heading leads nowhere — the title is plain text.
    init(title: String, items: [Item], cardWidth: CGFloat,
         @ViewBuilder card: @escaping (Item) -> Card) {
        self.init(title: title, items: items, cardWidth: cardWidth,
                  destination: nil, card: card)
    }
}

/// The shelf of titles: `CardShelf` with poster cards in it.
struct Shelf: View {
    let title: String
    let items: [MediaItem]
    /// Wide shelves show 16:9 backdrop cards instead of posters.
    var wide: Bool = false

    private var cardWidth: CGFloat { wide ? 300 : 150 }

    var body: some View {
        CardShelf(title: title, items: items, cardWidth: cardWidth) { item in
            PosterCard(item: item, width: cardWidth, wide: wide, siblings: items)
        }
    }
}

// MARK: - Grid

struct PosterGrid: View {
    let items: [MediaItem]
    /// The cut and the density come from the collection's View menu; a shelf
    /// or a person page that has no menu takes the defaults.
    var style: PosterStyle = .classic
    var size: CardSize = .medium
    var onReachEnd: (() -> Void)? = nil
    /// Selection mode: when non-nil, cards toggle membership in the set
    /// instead of navigating.
    var selection: Binding<Set<String>>? = nil
    /// `MediaItem.id` → a line under the title (the person page's roles).
    var subtitles: [String: String] = [:]

    private var width: CGFloat { size.width(style) }

    /// The grid breathes between the chosen width and a quarter more, so a
    /// window that lands between two column counts stretches the cards
    /// instead of leaving a gutter down the trailing edge.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: width, maximum: width * 1.27),
                  spacing: 18, alignment: .top)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
            ForEach(items) { item in
                if let selection {
                    PosterCard(item: item, width: width, wide: style == .wide,
                               selected: selection.wrappedValue.contains(item.id),
                               onSelect: {
                        if selection.wrappedValue.contains(item.id) {
                            selection.wrappedValue.remove(item.id)
                        } else {
                            selection.wrappedValue.insert(item.id)
                        }
                    })
                } else {
                    PosterCard(item: item, width: width, wide: style == .wide,
                               siblings: items,
                               subtitle: subtitles[item.id])
                        .onAppear {
                            if item.id == items.last?.id { onReachEnd?() }
                        }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }
}

// MARK: - States

struct QuietMessage: View {
    let systemImage: String
    let title: String
    let subtitle: String?
    var action: (title: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A title opened FROM a collection — the detail page keeps the whole
/// collection so previous/next can browse through it.
public struct TitleSelection: Hashable, Sendable {
    public let items: [MediaItem]
    public let index: Int

    public init(items: [MediaItem], index: Int) {
        self.items = items
        self.index = index
    }
}

/// Programmatic navigation to a title — injected by RootView so deep views
/// (like the Quiz poster) can push without owning the navigation path.
public struct OpenTitleAction {
    let run: (TitleSelection) -> Void

    public init(run: @escaping (TitleSelection) -> Void) { self.run = run }
    public func callAsFunction(_ selection: TitleSelection) { run(selection) }
}

private struct OpenTitleKey: EnvironmentKey {
    /// There is no path to push onto here, so this can only report itself: a
    /// page that ends up with the default has not been handed RootView's
    /// action (see `RootView.page(_:)`), and every table row and card in it is
    /// a dead click. Silent, that reads as "the table is broken".
    static let defaultValue = OpenTitleAction { selection in
        let title = selection.items.first?.title ?? "—"
        print("[TonightBarr] openTitle is not wired up on this page — \(title) went nowhere.")
    }
}

public extension EnvironmentValues {
    var openTitle: OpenTitleAction {
        get { self[OpenTitleKey.self] }
        set { self[OpenTitleKey.self] = newValue }
    }
}

/// Deal a whole collection into the Quiz — injected by RootView, which is the
/// only place that owns both the Quiz session and the sidebar. A library page
/// hands over exactly what it is showing, in the order it shows it; the deck
/// replaces the random feed until the user asks for a new one.
public struct OpenInQuizAction {
    let run: ([MediaItem], String) -> Void

    public init(run: @escaping ([MediaItem], String) -> Void) { self.run = run }
    public func callAsFunction(_ items: [MediaItem], named name: String) {
        run(items, name)
    }
}

private struct OpenInQuizKey: EnvironmentKey {
    /// Same rule as `openTitle`: a page that ends up with the default was
    /// never handed RootView's action, and its Quiz button is a dead click.
    static let defaultValue = OpenInQuizAction { items, name in
        print("[TonightBarr] openInQuiz is not wired up on this page — \(items.count) titles from \(name) went nowhere.")
    }
}

public extension EnvironmentValues {
    var openInQuiz: OpenInQuizAction {
        get { self[OpenInQuizKey.self] }
        set { self[OpenInQuizKey.self] = newValue }
    }
}
