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
                VStack(spacing: 0) {
                    composer
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                    aiKindHint
                        .padding(.bottom, 10)
                }
            } else {
                discoverButtonFallback
            }
        }
    }

    // MARK: - Kind selector

    /// Only movie/show are shown; .auto is set programmatically when the
    /// user has typed prose into the composer.
    private let userVisibleKinds: [DiscoverMediaSelection] = [.movie, .show]

    private var kindSelector: some View {
        HStack(spacing: 4) {
            ForEach(userVisibleKinds) { kind in
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
        .opacity(freeText.trimmingCharacters(in: .whitespaces).isEmpty ? 1.0 : 0.4)
    }

    // MARK: - Pill cloud (animated tag cloud)

    private var pillCloud: some View {
        DiscoverTagCloud<String>(
            tags: Self.moodPills.map { p in
                DiscoverTagCloud<String>.Tag(
                    id: p.label,
                    label: p.label,
                    palette: {
                        switch p.kind {
                        case .mood:      return .mood
                        case .genre:     return .genre
                        }
                    }()
                )
            },
            isPicked: { label in
                if viewModel.pickedMoods.contains(label) { return true }
                if let g = Self.moodPills.first(where: { $0.label == label }),
                   case let .genre(genre) = g.kind,
                   viewModel.filter.genres.contains(genre) {
                    return true
                }
                return false
            },
            onToggle: { label in
                guard let pill = Self.moodPills.first(where: { $0.label == label }) else { return }
                togglePill(pill)
            }
        )
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

    // MARK: - AI kind hint

    @ViewBuilder
    private var aiKindHint: some View {
        if llmAvailable
           && !freeText.trimmingCharacters(in: .whitespaces).isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                    .scaledFont(size: 9)
                Text("AI will pick movies or shows based on your description", bundle: .module)
                    .scaledFont(size: 10)
            }
            .foregroundStyle(.purple.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
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

        // If the user typed prose into the composer, let the LLM decide
        // per-title kind regardless of the Movies/Shows toggle. The toggle
        // only steers sources when the user is browsing without prose.
        if !free.isEmpty && llmAvailable {
            viewModel.mediaSelection = .auto
        }

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

