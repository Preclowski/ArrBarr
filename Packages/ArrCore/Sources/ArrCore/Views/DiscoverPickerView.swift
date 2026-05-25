import SwiftUI

// MARK: - FlowLayout

struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let (_, totalHeight) = layoutRows(maxWidth: maxWidth, subviews: subviews)
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (rows, _) = layoutRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let rowHeight = row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
            for idx in row {
                let s = subviews[idx].sizeThatFits(.unspecified)
                subviews[idx].place(at: CGPoint(x: x, y: y),
                                    proposal: ProposedViewSize(width: s.width, height: s.height))
                x += s.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func layoutRows(maxWidth: CGFloat, subviews: Subviews) -> (rows: [[Int]], totalHeight: CGFloat) {
        var rows: [[Int]] = [[]]
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let s = sub.sizeThatFits(.unspecified)
            let needed = s.width + (rows[rows.count - 1].isEmpty ? 0 : spacing)
            if rowWidth + needed > maxWidth, !rows[rows.count - 1].isEmpty {
                totalHeight += currentRowHeight + spacing
                rows.append([])
                rowWidth = 0
                currentRowHeight = 0
            }
            rows[rows.count - 1].append(i)
            rowWidth += s.width + (rows[rows.count - 1].count > 1 ? spacing : 0)
            currentRowHeight = max(currentRowHeight, s.height)
        }
        totalHeight += currentRowHeight
        return (rows, totalHeight)
    }
}

// MARK: - DiscoverPickerView

public struct DiscoverPickerView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let llmAvailable: Bool
    let onSubmit: () -> Void

    @State private var freeText: String = ""
    @FocusState private var freeTextFocused: Bool
    @State private var stage: PickerStage = .kind
    @Namespace private var labelNamespace

    public init(viewModel: DiscoverViewModel,
                llmAvailable: Bool,
                onSubmit: @escaping () -> Void) {
        self.viewModel = viewModel
        self.llmAvailable = llmAvailable
        self.onSubmit = onSubmit
    }

    // MARK: - Stage model

    private enum PickerStage {
        case kind
        case filters
    }

    // MARK: - Tag descriptor

    private struct PickerTag: Identifiable, Hashable {
        let id: String
        let label: String
        let icon: String?
        let category: PickerCategory

        static func == (l: Self, r: Self) -> Bool { l.id == r.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    private enum PickerCategory { case kind, genre, decade, rating, runtime }

    // MARK: - Tag catalog

    private static let kindTags: [PickerTag] = [
        PickerTag(id: "kind.movie", label: "Movies", icon: "film",  category: .kind),
        PickerTag(id: "kind.show",  label: "Shows",  icon: "tv",    category: .kind),
    ]

    private func filterTags() -> [PickerTag] {
        var out: [PickerTag] = []

        let genreSpec: [(DiscoverGenre, String)] = [
            (.action,         "bolt"),
            (.adventure,      "map"),
            (.animation,      "paintbrush"),
            (.comedy,         "face.smiling"),
            (.crime,          "lock"),
            (.documentary,    "doc.text"),
            (.drama,          "theatermasks"),
            (.family,         "figure.2.and.child.holdinghands"),
            (.fantasy,        "sparkle"),
            (.history,        "book.closed"),
            (.horror,         "drop"),
            (.music,          "music.note"),
            (.mystery,        "questionmark"),
            (.romance,        "heart"),
            (.scienceFiction, "atom"),
            (.thriller,       "exclamationmark.triangle"),
            (.war,            "shield"),
            (.western,        "sun.haze"),
        ]
        for (g, icon) in genreSpec {
            out.append(PickerTag(id: "genre.\(g.rawValue)", label: g.displayName,
                                 icon: icon, category: .genre))
        }

        for d in [DiscoverDecade.eighties, .nineties, .twoThousands,
                  .twoThousandTens, .twoThousandTwenties] {
            out.append(PickerTag(id: "decade.\(d.rawValue)", label: d.rawValue,
                                 icon: "calendar", category: .decade))
        }

        out.append(PickerTag(id: "rating.highlyRated", label: "Highly rated",
                             icon: "star.fill", category: .rating))
        out.append(PickerTag(id: "rating.cultFavorite", label: "Cult favorite",
                             icon: "flame", category: .rating))

        if viewModel.mediaSelection != .show {
            out.append(PickerTag(id: "runtime.short", label: "Short",
                                 icon: "hare", category: .runtime))
            out.append(PickerTag(id: "runtime.epic",  label: "Epic",
                                 icon: "hourglass", category: .runtime))
        }

        return out
    }

    // MARK: - isPicked / toggle

    private func isPicked(_ tag: PickerTag) -> Bool {
        switch tag.category {
        case .kind:
            switch tag.id {
            case "kind.movie": return viewModel.mediaSelection == .movie && stage == .filters
            case "kind.show":  return viewModel.mediaSelection == .show  && stage == .filters
            default: return false
            }
        case .genre:
            return DiscoverGenre.allCases.contains {
                "genre.\($0.rawValue)" == tag.id && viewModel.filter.genres.contains($0)
            }
        case .decade:
            return "decade.\(viewModel.filter.decade.rawValue)" == tag.id
        case .rating:
            return "rating.\(viewModel.filter.rating.rawValue)" == tag.id
        case .runtime:
            return "runtime.\(viewModel.filter.runtime.rawValue)" == tag.id
        }
    }

    private func toggle(_ tag: PickerTag) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
            switch tag.category {
            case .kind:
                switch tag.id {
                case "kind.movie":
                    if viewModel.mediaSelection == .movie && stage == .filters {
                        stage = .kind
                    } else {
                        viewModel.mediaSelection = .movie
                        stage = .filters
                    }
                    viewModel.mediaSelectionChanged()
                case "kind.show":
                    if viewModel.mediaSelection == .show && stage == .filters {
                        stage = .kind
                    } else {
                        viewModel.mediaSelection = .show
                        stage = .filters
                    }
                    viewModel.mediaSelectionChanged()
                default: break
                }
            case .genre:
                if let g = DiscoverGenre.allCases.first(where: { "genre.\($0.rawValue)" == tag.id }) {
                    if viewModel.filter.genres.contains(g) { viewModel.filter.genres.remove(g) }
                    else { viewModel.filter.genres.insert(g) }
                    viewModel.userChangedFilter()
                }
            case .decade:
                if let d = DiscoverDecade.allCases.first(where: { "decade.\($0.rawValue)" == tag.id }) {
                    viewModel.filter.decade = (viewModel.filter.decade == d) ? .any : d
                    viewModel.userChangedFilter()
                }
            case .rating:
                if let r = DiscoverRatingTier.allCases.first(where: { "rating.\($0.rawValue)" == tag.id }) {
                    viewModel.filter.rating = (viewModel.filter.rating == r) ? .any : r
                    viewModel.userChangedFilter()
                }
            case .runtime:
                if let rt = DiscoverRuntime.allCases.first(where: { "runtime.\($0.rawValue)" == tag.id }) {
                    viewModel.filter.runtime = (viewModel.filter.runtime == rt) ? .any : rt
                    viewModel.userChangedFilter()
                }
            }
        }
    }

    // MARK: - Tint

    private func tint(for tag: PickerTag) -> Color {
        switch tag.category {
        case .kind:    return .blue
        case .genre:
            // Group genres by mood family so color carries meaning.
            let intense:     Set<DiscoverGenre> = [.action, .crime, .war, .thriller, .horror]
            let warm:        Set<DiscoverGenre> = [.comedy, .family, .animation, .music]
            let serious:     Set<DiscoverGenre> = [.drama, .romance, .history, .documentary]
            let imaginative: Set<DiscoverGenre> = [.scienceFiction, .fantasy, .mystery, .adventure, .western, .tvMovie]
            // Resolve which DiscoverGenre this tag.id refers to.
            guard let g = DiscoverGenre.allCases.first(where: { "genre.\($0.rawValue)" == tag.id })
            else { return .blue }
            if intense.contains(g)     { return .red }
            if warm.contains(g)        { return .orange }
            if serious.contains(g)     { return .blue }
            if imaginative.contains(g) { return .purple }
            return .blue
        case .decade:  return .blue
        case .rating:  return .green
        case .runtime: return .purple
        }
    }

    // MARK: - Partitioning

    private var availableTagsForCurrentStage: [PickerTag] {
        switch stage {
        case .kind:
            return Self.kindTags.filter { !isPicked($0) }
        case .filters:
            return filterTags().filter { !isPicked($0) }
        }
    }

    private var selectedTagsForCurrentStage: [PickerTag] {
        switch stage {
        case .kind:
            return []
        case .filters:
            let kind = Self.kindTags.first(where: { isPicked($0) })
            let filters = filterTags().filter { isPicked($0) }
            return (kind.map { [$0] } ?? []) + filters
        }
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    selectedRow
                    Divider().padding(.horizontal, 12)
                    availableRow
                    moodStarters
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if llmAvailable { composer.padding(.horizontal, 10).padding(.bottom, 10) }
            else { discoverButtonFallback }
        }
    }

    // MARK: - Mood starters

    @ViewBuilder
    private var moodStarters: some View {
        if llmAvailable
           && stage == .filters
           && freeText.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("MOOD STARTERS", bundle: .module)
                    .scaledFont(size: 9, weight: .semibold)
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                FlowLayout(spacing: 6) {
                    ForEach(Self.starterPrompts, id: \.self) { prompt in
                        Button {
                            freeText = String(localized: String.LocalizationValue(prompt),
                                              bundle: .module)
                            // Don't auto-commit — let the user inspect / edit first.
                            // Their next action is hitting send.
                            freeTextFocused = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .scaledFont(size: 10, weight: .semibold)
                                Text(LocalizedStringKey(prompt), bundle: .module)
                                    .scaledFont(size: 11, weight: .medium)
                            }
                            .foregroundStyle(.purple.opacity(0.85))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.ultraThinMaterial))
                            .overlay(Capsule().stroke(Color.purple.opacity(0.3), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
    }

    private static let starterPrompts: [String] = [
        "Saturday night with friends",
        "Long solo flight",
        "Cozy Sunday afternoon"
    ]

    // MARK: - Selected row

    private var selectedRow: some View {
        let tags = selectedTagsForCurrentStage
        return Group {
            if tags.isEmpty {
                Text("Pick a media kind to start:", bundle: .module)
                    .scaledFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(tags) { tag in
                        pillView(tag, picked: true)
                            .matchedGeometryEffect(id: tag.id, in: labelNamespace)
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    // MARK: - Available row

    private var availableRow: some View {
        let tags = availableTagsForCurrentStage
        return VStack(alignment: .leading, spacing: 10) {
            if stage == .kind {
                // Stage .kind has just 2 pills; no header needed.
                FlowLayout(spacing: 6) {
                    ForEach(tags) { tag in
                        pillView(tag, picked: false)
                            .matchedGeometryEffect(id: tag.id, in: labelNamespace)
                            .transition(.opacity)
                    }
                }
            } else {
                ForEach(categoriesOrdered, id: \.self) { category in
                    let group = tags.filter { $0.category == category }
                    if !group.isEmpty {
                        categoryHeader(category)
                        FlowLayout(spacing: 6) {
                            ForEach(group) { tag in
                                pillView(tag, picked: false)
                                    .matchedGeometryEffect(id: tag.id, in: labelNamespace)
                                    .transition(.opacity)
                            }
                        }
                    }
                }
            }
        }
    }

    private var categoriesOrdered: [PickerCategory] {
        [.genre, .decade, .rating, .runtime]
    }

    @ViewBuilder
    private func categoryHeader(_ cat: PickerCategory) -> some View {
        let label: LocalizedStringKey = {
            switch cat {
            case .genre:   return "GENRE"
            case .decade:  return "DECADE"
            case .rating:  return "VIBE"
            case .runtime: return "LENGTH"
            case .kind:    return ""
            }
        }()
        Text(label, bundle: .module)
            .scaledFont(size: 9, weight: .semibold)
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Pill view

    @ViewBuilder
    private func pillView(_ tag: PickerTag, picked: Bool) -> some View {
        let color = tint(for: tag)
        Button { toggle(tag) } label: {
            HStack(spacing: 4) {
                if let icon = tag.icon {
                    Image(systemName: icon)
                        .scaledFont(size: 10, weight: .semibold)
                }
                Text(LocalizedStringKey(tag.label), bundle: .module)
                    .scaledFont(size: 12, weight: .semibold)
            }
            .foregroundStyle(picked ? Color.white : color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(picked ? color : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(color.opacity(picked ? 0 : 0.85), lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Composer

    private var composerPlaceholder: LocalizedStringKey {
        let pickedFilters = selectedTagsForCurrentStage.filter { $0.category != .kind }.count
        if pickedFilters == 0 {
            return "What are you in the mood for?"
        } else {
            return "Optional vibe — or hit ↵ to discover"
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("",
                      text: $freeText,
                      prompt: Text(composerPlaceholder, bundle: .module),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .focused($freeTextFocused)
                .lineLimit(1...4)
                .scaledFont(size: 13)
                .onSubmit {
                    if canCommit { commit() }
                }
            Button {
                commit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .scaledFont(size: 22)
                    .foregroundStyle(
                        canCommit
                            ? Color.accentColor
                            : Color.secondary
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canCommit)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassyFloatingBar()
    }

    // MARK: - Fallback Discover button (no LLM)

    private var discoverButtonFallback: some View {
        Button {
            commit()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .scaledFont(size: 12, weight: .semibold)
                Text("Discover", bundle: .module)
                    .scaledFont(size: 13, weight: .semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
        }
        .modifier(GlassProminentButtonStyle())
        .disabled(!canCommit)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Commit logic

    private var canCommit: Bool {
        stage == .filters || !freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commit() {
        let free = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.moodText = free
        if !free.isEmpty && llmAvailable {
            viewModel.mediaSelection = .auto
        }
        viewModel.userSubmittedMood()
        freeTextFocused = false
        onSubmit()
    }
}
