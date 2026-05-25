import SwiftUI

public struct DiscoverPickerView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let llmAvailable: Bool
    let onSubmit: () -> Void

    @State private var freeText: String = ""
    @FocusState private var freeTextFocused: Bool

    public init(viewModel: DiscoverViewModel,
                llmAvailable: Bool,
                onSubmit: @escaping () -> Void) {
        self.viewModel = viewModel
        self.llmAvailable = llmAvailable
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    kindSelector
                    Spacer().frame(height: 2)
                    pillCloud
                    if llmAvailable {
                        orWriteLabel
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            if llmAvailable {
                composer
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            } else {
                discoverButtonFallback
            }
        }
    }

    // MARK: - Kind selector

    private var kindSelector: some View {
        HStack(spacing: 4) {
            ForEach(DiscoverMediaSelection.allCases) { kind in
                Button {
                    if viewModel.mediaSelection != kind {
                        viewModel.mediaSelection = kind
                        viewModel.mediaSelectionChanged()
                    }
                } label: {
                    Text(LocalizedStringKey(kind.displayName), bundle: .module)
                        .scaledFont(size: 11,
                                    weight: viewModel.mediaSelection == kind ? .semibold : .medium)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(
                            viewModel.mediaSelection == kind
                                ? Color.accentColor.opacity(0.20)
                                : Color.primary.opacity(0.06)))
                        .foregroundStyle(viewModel.mediaSelection == kind
                                         ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pill cloud

    /// Flow-layout cloud of mood + genre pills. Built with `FlowLayout`
    /// (defined below) since SwiftUI's HStack can't wrap.
    private var pillCloud: some View {
        FlowLayout(spacing: 6) {
            ForEach(Self.moodPills, id: \.label) { pill in
                pillButton(pill)
            }
        }
    }

    private func pillButton(_ pill: MoodPill) -> some View {
        let isPicked: Bool = {
            switch pill.kind {
            case .mood:
                return viewModel.pickedMoods.contains(pill.label)
            case .genre(let g):
                return viewModel.filter.genres.contains(g)
            }
        }()
        return Button {
            togglePill(pill)
        } label: {
            Text(LocalizedStringKey(pill.label), bundle: .module)
                .scaledFont(size: 12, weight: isPicked ? .semibold : .medium)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isPicked
                        ? Color.accentColor.opacity(0.20)
                        : Color.primary.opacity(0.07))
                )
                .overlay(
                    Capsule().stroke(isPicked
                        ? Color.accentColor.opacity(0.6)
                        : .clear, lineWidth: 1)
                )
                .foregroundStyle(isPicked ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    private func togglePill(_ pill: MoodPill) {
        switch pill.kind {
        case .mood:
            if viewModel.pickedMoods.contains(pill.label) {
                viewModel.pickedMoods.remove(pill.label)
            } else {
                viewModel.pickedMoods.insert(pill.label)
            }
        case .genre(let g):
            if viewModel.filter.genres.contains(g) {
                viewModel.filter.genres.remove(g)
            } else {
                viewModel.filter.genres.insert(g)
            }
            viewModel.userChangedFilter()
        }
    }

    // MARK: - "Or write" label

    private var orWriteLabel: some View {
        Text("Or describe what you want:", bundle: .module)
            .scaledFont(size: 11)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    // MARK: - Composer (pinned to bottom when LLM available)

    /// Chat-style composer. NO left icon — match ChatView's inputBar
    /// exactly (TextField + send arrow only). Send is enabled when either
    /// free text OR pills are non-empty.
    private var composer: some View {
        HStack(spacing: 8) {
            TextField("",
                      text: $freeText,
                      prompt: Text("What are you in the mood for?", bundle: .module),
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
        !freeText.trimmingCharacters(in: .whitespaces).isEmpty
            || !viewModel.pickedMoods.isEmpty
            || !viewModel.filter.genres.isEmpty
    }

    /// Compose final moodText from picked pills + free text, kick off
    /// the parent's onSubmit.
    private func commit() {
        let pills = viewModel.pickedMoods.sorted().joined(separator: ", ")
        let free = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined: String
        switch (pills.isEmpty, free.isEmpty) {
        case (true, true):   combined = ""
        case (false, true):  combined = pills
        case (true, false):  combined = free
        case (false, false): combined = "\(pills). \(free)"
        }
        viewModel.moodText = combined
        viewModel.userSubmittedMood()
        freeTextFocused = false
        onSubmit()
    }

    // MARK: - Pill catalog

    private enum PillKind {
        case mood
        case genre(DiscoverGenre)
    }

    private struct MoodPill {
        let label: String       // also the localization key
        let kind: PillKind
    }

    /// Curated mix: mood adjectives first, then popular genres. Order
    /// matters — it's the order pills lay out in the cloud.
    private static let moodPills: [MoodPill] = [
        .init(label: "Cozy",            kind: .mood),
        .init(label: "Dark",            kind: .mood),
        .init(label: "Feel-good",       kind: .mood),
        .init(label: "Mind-bending",    kind: .mood),
        .init(label: "Epic",            kind: .mood),
        .init(label: "Nostalgic",       kind: .mood),
        .init(label: "Quirky",          kind: .mood),
        .init(label: "Slow burn",       kind: .mood),
        .init(label: "Suspenseful",     kind: .mood),
        .init(label: "Tear-jerker",     kind: .mood),
        .init(label: "Romantic",        kind: .mood),
        .init(label: "True story",      kind: .mood),
        .init(label: "Comedy",          kind: .genre(.comedy)),
        .init(label: "Thriller",        kind: .genre(.thriller)),
        .init(label: "Horror",          kind: .genre(.horror)),
        .init(label: "Action",          kind: .genre(.action)),
        .init(label: "Drama",           kind: .genre(.drama)),
        .init(label: "Science Fiction", kind: .genre(.scienceFiction)),
        .init(label: "Animation",       kind: .genre(.animation)),
        .init(label: "Documentary",     kind: .genre(.documentary)),
        .init(label: "Fantasy",         kind: .genre(.fantasy)),
    ]
}

// MARK: - FlowLayout

/// Simple flow layout: lays out children left-to-right, wrapping to a
/// new line when the next child would overflow. SwiftUI's `HStack`
/// can't wrap; `Layout` protocol gives us the primitive cheaply.
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
            for idx in row {
                let s = subviews[idx].sizeThatFits(.unspecified)
                subviews[idx].place(at: CGPoint(x: x, y: y),
                                    proposal: ProposedViewSize(width: s.width, height: s.height))
                x += s.width + spacing
            }
            let rowHeight = row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
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
