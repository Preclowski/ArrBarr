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

    // MARK: - Pill cloud (concrete filter-mapping tag cloud)

    private var pillCloud: some View {
        DiscoverTagCloud<String>(
            tags: visibleTags.map { tag in
                DiscoverTagCloud<String>.Tag(
                    id: tag.label,
                    label: tag.label,
                    icon: tag.icon,
                    category: tag.cloudCategory
                )
            },
            isPicked: { label in
                guard let tag = Self.cloudTags.first(where: { $0.label == label }) else { return false }
                return tag.isPicked(viewModel)
            },
            onToggle: { label in
                guard let tag = Self.cloudTags.first(where: { $0.label == label }) else { return }
                tag.apply(viewModel)
            }
        )
    }

    /// Runtime pills are hidden when browsing shows (TV runtime is per-episode).
    private var visibleTags: [CloudTag] {
        Self.cloudTags.filter { tag in
            if viewModel.mediaSelection == .show && tag.category == .runtime { return false }
            return true
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

    /// Always true — user can browse with no signal (TMDB Discover returns
    /// popular titles by default). Filters already applied via pills.
    private var canCommit: Bool { true }

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

    // MARK: - Tag catalog

    private enum TagCategory: String {
        case genre, decade, rating, runtime
    }

    private struct CloudTag {
        let label: String           // localization key
        let icon: String            // SF Symbol name
        let category: TagCategory
        let apply: (DiscoverViewModel) -> Void
        let isPicked: (DiscoverViewModel) -> Bool

        var cloudCategory: DiscoverTagCloud<String>.Category {
            switch category {
            case .genre:   return .genre
            case .decade:  return .decade
            case .rating:  return .rating
            case .runtime: return .runtime
            }
        }
    }

    private static let cloudTags: [CloudTag] = makeTags()

    private static func makeTags() -> [CloudTag] {
        var tags: [CloudTag] = []

        // GENRES — 18 (tvMovie excluded per spec)
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
            tags.append(CloudTag(
                label: g.displayName,
                icon: icon,
                category: .genre,
                apply: { vm in
                    if vm.filter.genres.contains(g) { vm.filter.genres.remove(g) }
                    else { vm.filter.genres.insert(g) }
                    vm.userChangedFilter()
                },
                isPicked: { vm in vm.filter.genres.contains(g) }
            ))
        }

        // DECADES — single-select; re-tap clears.
        for d in [DiscoverDecade.eighties, .nineties, .twoThousands,
                  .twoThousandTens, .twoThousandTwenties] {
            tags.append(CloudTag(
                label: d.rawValue,
                icon: "calendar",
                category: .decade,
                apply: { vm in
                    vm.filter.decade = (vm.filter.decade == d) ? .any : d
                    vm.userChangedFilter()
                },
                isPicked: { vm in vm.filter.decade == d }
            ))
        }

        // RATING — exclusive; re-tap clears.
        tags.append(CloudTag(
            label: "Highly rated", icon: "star.fill", category: .rating,
            apply: { vm in
                vm.filter.rating = (vm.filter.rating == .highlyRated) ? .any : .highlyRated
                vm.userChangedFilter()
            },
            isPicked: { vm in vm.filter.rating == .highlyRated }
        ))
        tags.append(CloudTag(
            label: "Cult favorite", icon: "flame", category: .rating,
            apply: { vm in
                vm.filter.rating = (vm.filter.rating == .cultFavorite) ? .any : .cultFavorite
                vm.userChangedFilter()
            },
            isPicked: { vm in vm.filter.rating == .cultFavorite }
        ))

        // RUNTIME
        tags.append(CloudTag(
            label: "Short", icon: "hare", category: .runtime,
            apply: { vm in
                vm.filter.runtime = (vm.filter.runtime == .short) ? .any : .short
                vm.userChangedFilter()
            },
            isPicked: { vm in vm.filter.runtime == .short }
        ))
        tags.append(CloudTag(
            label: "Epic", icon: "hourglass", category: .runtime,
            apply: { vm in
                vm.filter.runtime = (vm.filter.runtime == .epic) ? .any : .epic
                vm.userChangedFilter()
            },
            isPicked: { vm in vm.filter.runtime == .epic }
        ))

        return tags
    }
}
