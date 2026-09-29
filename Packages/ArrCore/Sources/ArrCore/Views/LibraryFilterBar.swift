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
    @Binding var source: QueueItem.Source
    @Binding var statusFilter: StatusFilter
    @Binding var sort: SortMode
    @Binding var sortDescending: Bool
    @Binding var viewModeRaw: String

    private var viewMode: ViewMode { ViewMode(rawValue: viewModeRaw) ?? .grid }

    var body: some View {
        HStack(spacing: 6) {
            if sources.count > 1 {
                sourceMenu
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1, height: 14)
            }
            // Localized labels ("Niemonitorowane") overflow 400 pt and would wrap inside the capsules.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(StatusFilter.allCases, id: \.self) { filter in
                        statusChip(filter)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            Spacer(minLength: 4)
            viewModeToggle
            sortMenu
        }
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

    private func statusChip(_ filter: StatusFilter) -> some View {
        let selected = statusFilter == filter
        let count = counts[filter] ?? 0
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { statusFilter = filter }
        } label: {
            HStack(spacing: 3) {
                Text(LocalizedStringKey(filter.labelKey), bundle: .module)
                    .scaledFont(size: LibraryChrome.label, weight: selected ? .semibold : .medium)
                    .lineLimit(1)
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .scaledFont(size: LibraryChrome.label, weight: .regular)
                        .monospacedDigit()
                        // `.secondary`, not `opacity`: over glass a faded label blends with the backdrop.
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, LibraryChrome.chipHPad)
            .padding(.vertical, LibraryChrome.chipVPad)
            // Flat, not glass: the filter row is a control strip, not floating chrome.
            .background {
                if selected { Capsule().fill(Color.primary.opacity(0.14)) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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

    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            ForEach(SortMode.available(for: source), id: \.self) { mode in
                Button {
                    if sort == mode {
                        sortDescending.toggle()
                    } else {
                        sort = mode
                    }
                } label: {
                    Label {
                        mode.label
                    } icon: {
                        Image(systemName: sort == mode
                              ? (sortDescending ? "arrow.down" : "arrow.up")
                              : mode.symbolName)
                    }
                    // Inside a `Menu` the inherited label style can come out title-only and drop the glyph.
                    .labelStyle(.titleAndIcon)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .scaledFont(size: LibraryChrome.glyph, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: LibraryChrome.tapTarget, height: LibraryChrome.tapTarget)
                .contentShape(Rectangle())
        }
        // `.button` + `.plain`, not `.borderlessButton`, which re-renders the label at its own size and colour.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("library.sort.help", bundle: .module))
        .accessibilityLabel(Text("library.sort.help", bundle: .module))
    }
}
