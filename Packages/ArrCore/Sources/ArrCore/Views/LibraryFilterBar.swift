import SwiftUI

/// On touch the popover-sized chrome gives 20pt hit areas (half Apple's 44pt minimum),
/// so every value is forked here rather than `#if`-ed at each call site.
private enum LibraryChrome {
    #if os(iOS)
    static let label: CGFloat = 13
    static let chevron: CGFloat = 10
    static let chipHPad: CGFloat = 12
    static let chipVPad: CGFloat = 8
    static let glyph: CGFloat = 15
    static let tapTarget: CGFloat = 44
    static let brandIcon: CGFloat = 13
    #else
    static let label: CGFloat = 11
    static let chevron: CGFloat = 8
    static let chipHPad: CGFloat = 8
    static let chipVPad: CGFloat = 3
    static let glyph: CGFloat = 11
    static let tapTarget: CGFloat = 20
    static let brandIcon: CGFloat = 10
    #endif
}

// MARK: - Filter bar

/// A separate struct, not a computed property: it lives in the grid's safe area, and as a
/// computed property it re-ran on every scroll frame. `counts` arrives precomputed for the same reason.
struct LibraryFilterBar: View {
    let sources: [QueueItem.Source]
    let counts: [StatusFilter: Int]
    /// The whole library of the source, for the popover's genres and decades.
    let entries: [LibraryEntry]
    let watchStateKnown: Bool
    @Binding var source: QueueItem.Source
    @Binding var statusFilter: StatusFilter
    @Binding var narrowing: LibraryNarrowing
    @Binding var sort: SortMode
    @Binding var sortDescending: Bool
    @Binding var viewModeRaw: String
    @State private var showsFilters = false
    @Environment(\.locale) private var locale

    private var viewMode: ViewMode { ViewMode(rawValue: viewModeRaw) ?? .grid }
    private var isNarrowed: Bool { statusFilter != .all || narrowing.isActive }

    var body: some View {
        HStack(spacing: 6) {
            if sources.count > 1 {
                sourceMenu
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1, height: 14)
            }
            // What's narrowed, each removable on its own; several can overflow 400 pt.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(tokens, id: \.kind) { token in
                        tokenChip(token)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            Spacer(minLength: 4)
            viewModeToggle
            filterButton
        }
        .animation(.easeOut(duration: 0.15), value: tokens.map(\.kind))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var sourceMenu: some View {
        Menu {
            // A `Picker`, not hand-built rows: brand marks don't draw inside menu rows,
            // and AppKit then owns the selection checkmark.
            Picker(selection: $source) {
                ForEach(sources, id: \.self) { s in
                    Text(verbatim: s.displayName).tag(s)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                // Only menu rows drop artwork; the trigger chip is an ordinary view.
                ServiceIcon(source: source, size: LibraryChrome.brandIcon)
                Text(verbatim: source.displayName)
                    .scaledFont(size: LibraryChrome.label, weight: .semibold)
                Image(systemName: "chevron.down")
                    .scaledFont(size: LibraryChrome.chevron, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, LibraryChrome.chipHPad)
            .padding(.vertical, LibraryChrome.chipVPad)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.30), lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("library.source.help", bundle: .module))
    }

    /// The glyph shows the layout you'd switch to, like Finder.
    private var viewModeToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                viewModeRaw = (viewMode == .grid ? ViewMode.list : .grid).rawValue
            }
        } label: {
            Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                .scaledFont(size: LibraryChrome.glyph, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: LibraryChrome.tapTarget, height: LibraryChrome.tapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(viewMode == .grid ? "library.view.list" : "library.view.grid", bundle: .module))
        .accessibilityLabel(Text(viewMode == .grid ? "library.view.list" : "library.view.grid", bundle: .module))
    }

    // MARK: - Narrowing

    private enum TokenKind: Hashable { case status, genre, decade, unwatched }
    private struct Token { let kind: TokenKind; let label: Text }

    private var tokens: [Token] {
        var out: [Token] = []
        if statusFilter != .all { out.append(Token(kind: .status, label: Text(LocalizedStringKey(statusFilter.labelKey), bundle: .module))) }
        if let genre = narrowing.genre { out.append(Token(kind: .genre, label: Text(verbatim: GenreName.localized(genre, locale: locale)))) }
        if let decade = narrowing.decade { out.append(Token(kind: .decade, label: Text(verbatim: "\(decade)–\(decade + 9)"))) }
        if narrowing.unwatchedOnly { out.append(Token(kind: .unwatched, label: Text("shelf.filter.unwatched", bundle: .module))) }
        return out
    }

    private func tokenChip(_ token: Token) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                switch token.kind {
                case .status: statusFilter = .all
                case .genre: narrowing.genre = nil
                case .decade: narrowing.decade = nil
                case .unwatched: narrowing.unwatchedOnly = false
                }
            }
        } label: {
            HStack(spacing: 4) {
                token.label
                    .scaledFont(size: LibraryChrome.label, weight: .semibold)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .scaledFont(size: LibraryChrome.chevron, weight: .bold)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .padding(.leading, LibraryChrome.chipHPad)
            .padding(.trailing, LibraryChrome.chipHPad - 2)
            .padding(.vertical, LibraryChrome.chipVPad)
            // Flat, not glass: the filter row is a control strip, not floating chrome.
            .background(Capsule().fill(Color.primary.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }

    private var filterButton: some View {
        Button { showsFilters.toggle() } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .scaledFont(size: LibraryChrome.glyph, weight: .medium)
                .foregroundStyle(showsFilters || isNarrowed ? .primary : .secondary)
                .frame(width: LibraryChrome.tapTarget, height: LibraryChrome.tapTarget)
                .background {
                    if showsFilters { RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.14)) }
                }
                .overlay(alignment: .topTrailing) {
                    if isNarrowed {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 1, y: -1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("common.filter.button", bundle: .module))
        .accessibilityLabel(Text("common.filter.button", bundle: .module))
        .popover(isPresented: $showsFilters, arrowEdge: .bottom) {
            LibraryFilterPanel(source: source, counts: counts, entries: entries, watchStateKnown: watchStateKnown,
                               statusFilter: $statusFilter, narrowing: $narrowing,
                               sort: $sort, sortDescending: $sortDescending)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #endif
        }
    }
}

/// Status, order, genre, decade and watch state in one place, laid out like the Roulette's filter panel.
struct LibraryFilterPanel: View {
    let source: QueueItem.Source
    let counts: [StatusFilter: Int]
    let entries: [LibraryEntry]
    let watchStateKnown: Bool
    @Binding var statusFilter: StatusFilter
    @Binding var narrowing: LibraryNarrowing
    @Binding var sort: SortMode
    @Binding var sortDescending: Bool
    @State private var hoveredSort: SortMode?
    @State private var hoveredDecade: Int?

    private var isNarrowed: Bool { statusFilter != .all || narrowing.isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfPanelSection(title: "Status") {
                ShelfSegments(items: StatusFilter.allCases, selected: statusFilter, height: 22,
                              action: { statusFilter = $0 }) { filter, on in
                    HStack(spacing: 4) {
                        Text(LocalizedStringKey(filter.labelKey), bundle: .module)
                            .lineLimit(1)
                        Text(counts[filter] ?? 0, format: .number)
                            .scaledFont(size: 10)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    .scaledFont(size: 11, weight: on ? .semibold : .medium)
                    .padding(.horizontal, 4)
                }
            }
            ShelfPanelSection(title: "shelf.filter.sort") {
                HStack(spacing: 3) {
                    (hoveredSort ?? sort).label
                    if hoveredSort == nil { Image(systemName: sortDescending ? "arrow.down" : "arrow.up").scaledFont(size: 9, weight: .bold) }
                }
            } content: {
                ShelfSegments(items: SortMode.available(for: source), selected: sort, height: 24, action: { mode in
                    if sort == mode { sortDescending.toggle() } else { sort = mode }
                }, onHover: { hoveredSort = $0 }) { mode, on in
                    HStack(spacing: 2) {
                        Image(systemName: mode.symbolName)
                        if on { Image(systemName: sortDescending ? "arrow.down" : "arrow.up").scaledFont(size: 8.5, weight: .bold) }
                    }
                    .scaledFont(size: 11.5, weight: .semibold)
                }
            }
            ShelfPanelSection(title: "shelf.filter.genre") {
                GenreChipCloud(genre: $narrowing.genre, all: entries, narrowed: {
                    statusFilter.includes($0) && narrowing.matches($0, ignoring: .genre)
                }, compact: true)
            }
            if !DecadeHistogram.decades(in: entries).isEmpty {
                ShelfPanelSection(title: "shelf.filter.years") {
                    DecadeHint(decade: hoveredDecade ?? narrowing.decade)
                } content: {
                    DecadeHistogram(decade: $narrowing.decade, hovered: $hoveredDecade, all: entries, narrowed: {
                        statusFilter.includes($0) && narrowing.matches($0, ignoring: .decade)
                    }, compact: true)
                }
            }
            Divider()
            HStack {
                if watchStateKnown {
                    Toggle(isOn: $narrowing.unwatchedOnly) { Text("shelf.filter.unwatched", bundle: .module) }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                Spacer(minLength: 8)
                Button {
                    statusFilter = .all
                    narrowing = LibraryNarrowing()
                } label: {
                    Text("queue.clearFilter.button", bundle: .module)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .opacity(isNarrowed ? 1 : 0)
                .allowsHitTesting(isNarrowed)
            }
            .scaledFont(size: 11.5, weight: .medium)
            .padding(.horizontal, 2)
        }
        .padding(12)
        .frame(width: 324)
        .animation(.easeOut(duration: 0.15), value: narrowing)
        .animation(.easeOut(duration: 0.15), value: statusFilter)
    }
}
