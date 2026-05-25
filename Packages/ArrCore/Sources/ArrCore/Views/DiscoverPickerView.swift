import SwiftUI

// MARK: - DiscoverPickerView

public struct DiscoverPickerView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let llmAvailable: Bool
    let tmdbAvailable: Bool
    let onSubmit: () -> Void

    @State private var freeText: String = ""
    @FocusState private var freeTextFocused: Bool
    @State private var addingPerson: Bool = false
    @State private var newPersonText: String = ""
    @FocusState private var newPersonFocused: Bool
    /// Per-category "+" input state — keyed by category raw value so
    /// the genre / decade / rating / runtime rows all share the same
    /// expandable-chip primitive without duplicating @State.
    @State private var addingTagFor: String? = nil
    @State private var newCustomTagText: String = ""
    @FocusState private var newCustomTagFocused: Bool

    public init(viewModel: DiscoverViewModel,
                llmAvailable: Bool,
                tmdbAvailable: Bool,
                onSubmit: @escaping () -> Void) {
        self.viewModel = viewModel
        self.llmAvailable = llmAvailable
        self.tmdbAvailable = tmdbAvailable
        self.onSubmit = onSubmit
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

    /// Mood isn't a filter category — it's free-form intent that flows
    /// into the composer below. We removed it from the cloud so the
    /// picker shows only real filters; custom moods now live in the
    /// suggested-prompts section as quick-fills for the composer.
    private enum PickerCategory: String { case people, genre, decade, rating, runtime }

    /// LLM-only categories (custom tags here flow purely into `moodText`).
    /// Mood and People have their own dedicated add-chips with different
    /// commit semantics, so they're excluded.
    private static let customAdditionCategories: Set<PickerCategory> =
        [.genre, .decade, .rating, .runtime]

    /// Color used by both the Suggestions row and the in-composer chips
    /// to keep the per-category palette consistent.
    private static func color(for category: SuggestedFilter.Category) -> Color {
        switch category {
        case .people:  return .teal
        case .genre:   return .blue
        case .decade:  return .orange
        case .rating:  return .green
        case .runtime: return .purple
        }
    }

    /// Curated list of directors / actors that get a dedicated pill in
    /// the picker. Tap resolves to TMDB person id via `searchPerson`,
    /// cached in the VM so subsequent taps are instant. Names chosen for
    /// recognizability across film fan communities; deliberately mixed
    /// directors + actors so the row reads as "filmmakers" not just one
    /// trade.
    private static let predefinedPeople: [String] = [
        "Quentin Tarantino",
        "Christopher Nolan",
        "Adam Sandler",
        "Leonardo DiCaprio",
    ]

    // MARK: - Tag catalog

    private func filterTags() -> [PickerTag] {
        var out: [PickerTag] = []

        // (Mood category removed — mood is free text in the composer,
        // not a filter pill. Custom mood strings now surface in the
        // starter-prompts list below.)

        // Predefined + user-added names merged. Same sort — most used
        // bubble up so "Tarantino" sits leftmost after a few taps even
        // though it isn't first in the curated array.
        let mergedPeople = Self.predefinedPeople + viewModel.customPeople
        let sortedPeople = mergedPeople.sorted { a, b in
            viewModel.personUsageCount[a, default: 0]
                > viewModel.personUsageCount[b, default: 0]
        }
        for name in sortedPeople {
            out.append(PickerTag(id: "person.\(name)", label: name,
                                 icon: "person.fill", category: .people))
        }

        // Curated short list — the long form (18 genres) made the cloud
        // feel like a checkbox menu. These 8 cover ~80% of what users
        // reach for; anything else can be added via the "+ Add" chip.
        let genreSpec: [(DiscoverGenre, String)] = [
            (.action,         "bolt"),
            (.comedy,         "face.smiling"),
            (.drama,          "theatermasks"),
            (.horror,         "drop"),
            (.romance,        "heart"),
            (.scienceFiction, "atom"),
            (.thriller,       "exclamationmark.triangle"),
            (.documentary,    "doc.text"),
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

        // Append user-added free-form tags per category. Each one
        // behaves like a custom mood on tap (sets moodText + commits) —
        // the catalog filters (genre / decade / etc.) can't be extended
        // to new TMDB values, but the LLM understands free text so we
        // just route the label there.
        for cat in Self.customAdditionCategories {
            let extras = viewModel.customTagsByCategory[cat.rawValue] ?? []
            for label in extras {
                out.append(PickerTag(id: "custom.\(cat.rawValue).\(label)",
                                     label: label, icon: "sparkles",
                                     category: cat))
            }
        }

        return out
    }

    // MARK: - isPicked / toggle

    private func isPicked(_ tag: PickerTag) -> Bool {
        // Custom tags from any category live in `moodText` — picked
        // when their label is the active mood string.
        if isCustomTag(tag) {
            return viewModel.moodText == customTagLabel(tag)
        }
        switch tag.category {
        case .people:
            // Read from `selectedPersonNames` so the pill colors *the
            // instant the user taps*, before the TMDB resolve completes.
            // Reading from `filter.personIds` (the old approach) left the
            // pill grey during the round-trip — the user thought the tap
            // didn't register.
            let name = String(tag.id.dropFirst("person.".count))
            return viewModel.isPersonSelected(name: name)
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

    /// True iff this tag is a user-added custom label (not a catalog
    /// entry). Custom tag ids carry a "custom." prefix encoding the
    /// category and label.
    private func isCustomTag(_ tag: PickerTag) -> Bool {
        tag.id.hasPrefix("custom.")
    }

    /// Centralised on/off behavior for any pill that maps to `moodText`
    /// (mood pills + any custom tag from genre / decade / rating /
    /// runtime). Bumps usage only when *selecting* the label, so toggle-
    /// off doesn't inflate the count.
    private func toggleMoodLabel(_ label: String) {
        if viewModel.moodText == label {
            viewModel.moodText = ""
        } else {
            viewModel.bumpMoodUsage(label)
            viewModel.moodText = label
        }
        viewModel.userChangedFilter()
    }

    /// Pulls the label out of a "custom.<category>.<label>" id. Same
    /// string the user typed in.
    private func customTagLabel(_ tag: PickerTag) -> String {
        let prefix = "custom.\(tag.category.rawValue)."
        return String(tag.id.dropFirst(prefix.count))
    }

    private func toggle(_ tag: PickerTag) {
        // Free-form custom tag from any category — toggles `moodText`
        // on/off. Same single-string slot as the mood pills (only one
        // intent string can be active), so picking a new one replaces
        // the old; picking the same one again clears it.
        if isCustomTag(tag) {
            toggleMoodLabel(customTagLabel(tag))
            return
        }
        switch tag.category {
        case .people:
            // People are filter pills, not commit-on-tap (moods are).
            // Tap toggles the personId in the filter; the user combines
            // people with genres / decade / mood and then hits the
            // Discover button (or composer Enter) to commit. Tap also
            // bumps usage so favourites bubble left.
            let name = String(tag.id.dropFirst("person.".count))
            viewModel.bumpPersonUsage(name)
            Task { await viewModel.togglePerson(name: name) }
            return
        default:
            break
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
            switch tag.category {
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
            case .people:
                break // handled above
            }
        }
    }

    // MARK: - Tint

    /// One color per category — not per individual tag. The previous
    /// "genre family rainbow" made tag selections look like confetti;
    /// now the cloud reads as composition: pink moods, teal people,
    /// blue genres, orange decades, green ratings, purple runtimes.
    /// User glances at the picker and sees the *shape* of their mood
    /// (2 genres + 1 decade + a mood) instead of trying to decode 4
    /// different hues per row.
    private func tint(for tag: PickerTag) -> Color {
        switch tag.category {
        case .people:  return .teal
        case .genre:   return .blue
        case .decade:  return .orange
        case .rating:  return .green
        case .runtime: return .purple
        }
    }

    // MARK: - Partitioning

    private var selectedTagsForCurrentStage: [PickerTag] {
        filterTags().filter(isPicked)
    }

    // MARK: - Active chip descriptors

    /// Snapshot of every filter currently active. Composer renders one chip
    /// per entry, in insertion-friendly category order (people → genre →
    /// decade → rating → runtime). Each entry carries the closure that
    /// removes the filter when the chip's × is tapped.
    private struct ActiveChipDescriptor: Identifiable {
        let id: String
        let label: String
        let category: SuggestedFilter.Category
        let onRemove: () -> Void
    }

    private var activeChips: [ActiveChipDescriptor] {
        var out: [ActiveChipDescriptor] = []
        for name in viewModel.selectedPersonNames.sorted() {
            out.append(.init(id: "person.\(name)", label: name, category: .people) {
                Task { await viewModel.togglePerson(name: name) }
            })
        }
        for g in viewModel.filter.genres.sorted(by: { $0.rawValue < $1.rawValue }) {
            out.append(.init(id: "genre.\(g.rawValue)", label: g.displayName, category: .genre) {
                viewModel.filter.genres.remove(g)
                viewModel.userChangedFilter()
            })
        }
        if viewModel.filter.decade != .any {
            let d = viewModel.filter.decade
            out.append(.init(id: "decade.\(d.rawValue)", label: d.rawValue, category: .decade) {
                viewModel.filter.decade = .any
                viewModel.userChangedFilter()
            })
        }
        if viewModel.filter.rating != .any {
            let r = viewModel.filter.rating
            out.append(.init(id: "rating.\(r.rawValue)",
                             label: r.rawValue.capitalized, category: .rating) {
                viewModel.filter.rating = .any
                viewModel.userChangedFilter()
            })
        }
        if viewModel.filter.runtime != .any {
            let rt = viewModel.filter.runtime
            out.append(.init(id: "runtime.\(rt.rawValue)",
                             label: rt.rawValue.capitalized, category: .runtime) {
                viewModel.filter.runtime = .any
                viewModel.userChangedFilter()
            })
        }
        return out
    }

    // MARK: - Rotating placeholder

    @State private var placeholderTick: Int = 0

    /// Rotates every 3 seconds while composer is empty and unfocused. Goes
    /// quiet while focused so it doesn't fight the cursor.
    private static let placeholderRotation: [String] = [
        "Try: Cozy Sunday afternoon…",
        "Try: Friends over with pizza…",
        "Try: Date night…",
        "Try: Long flight…",
        "Try: Crowd-pleaser…",
    ]

    private var currentPlaceholder: String {
        if !activeChips.isEmpty {
            return "Or describe…"
        }
        return Self.placeholderRotation[
            placeholderTick % Self.placeholderRotation.count
        ]
    }

    // MARK: - Body

    public var body: some View {
        // Picker is the root of Discover — no back button here. Earlier
        // draft had a back-to-tinder chevron whenever an active session
        // existed; combined with tinder's own back button it formed a
        // tinder ↔ picker loop the user couldn't escape. Now: tinder's
        // back goes to picker (root); to re-enter the swipe deck the
        // user commits via composer Enter / Discover button.
        VStack(spacing: 0) {
            mainPickerScroll
            if llmAvailable {
                composer.padding(.horizontal, 10).padding(.bottom, 10)
            } else {
                discoverButtonFallback
            }
        }
    }

    // MARK: - Kind selector bar

    private var kindSelectorBar: some View {
        HStack(spacing: 8) {
            kindButton(.movie, label: "Movies", color: .blue, icon: "film")
            kindButton(.show,  label: "Shows",  color: .orange, icon: "tv")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func kindButton(_ kind: DiscoverMediaSelection,
                            label: LocalizedStringKey,
                            color: Color,
                            icon: String) -> some View {
        let active = viewModel.mediaSelection == kind
        // Inactive ⇒ neutral grey (so the active one stands out cleanly).
        // Active ⇒ colored outline + colored text (NOT solid fill).
        // Previous variant had inactive in the category color too, which
        // made it ambiguous which one was selected.
        let fg: Color = active ? color : .secondary
        let stroke: Color = active ? color : .secondary.opacity(0.4)
        let strokeWidth: CGFloat = active ? 1.5 : 1
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                viewModel.mediaSelection = kind
                viewModel.hasPickedKind = true
                viewModel.mediaSelectionChanged()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .scaledFont(size: 11, weight: .semibold)
                Text(label, bundle: .module)
                    .scaledFont(size: 12, weight: .semibold)
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(stroke, lineWidth: strokeWidth)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - TMDB missing banner

    @ViewBuilder
    private var tmdbMissingBanner: some View {
        if !tmdbAvailable {
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .scaledFont(size: 10, weight: .medium)
                    .foregroundStyle(.orange)
                Text("Add TMDB API key in Settings to discover new films.", bundle: .module)
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.orange.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Main picker scroll

    private var mainPickerScroll: some View {
        ScrollView {
            VStack(spacing: 12) {
                tmdbMissingBanner
                kindSelectorBar
                // Picked pills stay inline within their category — color
                // is the only signal. The earlier two-row split (Selected
                // up top + Available below) caused tags to jump rows on
                // every tap, which made scanning hard and broke spatial
                // memory ("where did I just see Comedy?").
                pillRows
                moodStarters
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Mood starters

    /// Themed groups of starter prompts. Each theme has a header and a
    /// few example moods that fill the composer on tap. Better than the
    /// old flat 3-item list — gives the user shape ("there are evening
    /// moods, travel moods, weekend moods") and a fuller sense of what
    /// the LLM can do, without dumping a huge wall of prompts.
    @ViewBuilder
    private var moodStarters: some View {
        if llmAvailable
           && freeText.trimmingCharacters(in: .whitespaces).isEmpty {
            // No extra horizontal padding here — the parent VStack
            // already applies `.padding(.horizontal, 12)`, so starters
            // align flush with the pill rows above. Earlier we double-
            // padded, leaving starters indented 24pt while pills sat at
            // 12pt — looked broken and was the "z dupy" alignment.
            VStack(alignment: .leading, spacing: 12) {
                // STARTERS is the parent of the theme groups (Cozy
                // night in / Saturday night / Long haul) — bumped to
                // 11pt secondary so it visibly outranks the per-theme
                // labels below, which use the standard 9pt tertiary
                // category-header treatment.
                Text("STARTERS (AI)", bundle: .module)
                    .scaledFont(size: 11, weight: .semibold)
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                ForEach(Self.starterThemes, id: \.title) { theme in
                    VStack(alignment: .leading, spacing: 6) {
                        // Same chrome as category headers (Genre, Decade,
                        // Vibe, Length) — 9pt all-caps tertiary. Starters
                        // are a peer section, not a louder one.
                        Text(LocalizedStringKey(theme.title), bundle: .module)
                            .scaledFont(size: 9, weight: .semibold)
                            .tracking(0.6)
                            .textCase(.uppercase)
                            .foregroundStyle(.tertiary)
                        FlowLayout(spacing: 5) {
                            ForEach(theme.prompts, id: \.self) { prompt in
                                starterPill(prompt)
                            }
                        }
                    }
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func starterPill(_ prompt: String) -> some View {
        // Hover state matches unpicked `PillButtonView` (text brightens
        // secondary → primary, stroke thickens 0.4 → 0.85). Per-pill
        // hover requires its own @State, so the pill is a small nested
        // struct.
        StarterPillButton(prompt: prompt) {
            freeText = String(localized: String.LocalizationValue(prompt),
                              bundle: .module)
            freeTextFocused = true
        }
    }

    private struct StarterPillButton: View {
        let prompt: String
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            let textColor: Color = isHovering ? .primary : .secondary
            let strokeOpacity: Double = isHovering ? 0.85 : 0.4
            let strokeWidth: CGFloat = isHovering ? 1.2 : 1.0
            Button(action: action) {
                HStack(spacing: 3) {
                    Image(systemName: "sparkles")
                        .scaledFont(size: 8, weight: .semibold)
                    Text(LocalizedStringKey(prompt), bundle: .module)
                        .scaledFont(size: 10, weight: .medium)
                }
                .foregroundStyle(textColor)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(textColor.opacity(strokeOpacity),
                                lineWidth: strokeWidth)
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in isHovering = hovering }
        }
    }

    private struct StarterTheme { let title: String; let prompts: [String] }

    private static let starterThemes: [StarterTheme] = [
        StarterTheme(title: "Cozy night in", prompts: [
            "Cozy Sunday afternoon",
            "Background while cooking",
            "Easy comfort watch",
        ]),
        StarterTheme(title: "Saturday night", prompts: [
            "Friends over with pizza",
            "Date night",
            "Crowd-pleaser",
        ]),
        StarterTheme(title: "Long haul", prompts: [
            "Long solo flight",
            "Marathon binge",
            "Hangover Sunday",
        ]),
    ]

    // MARK: - Pill rows (inline picked state)

    /// All tags grouped by category, picked or not — selection is signaled
    /// via the pill's color and stroke, not by moving the pill out of its
    /// category. Spatial stability lets the user tap → see the same pill
    /// just change color, instead of watching it migrate up a row.
    private var pillRows: some View {
        let tags = filterTags()
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(categoriesOrdered, id: \.self) { category in
                let group = tags.filter { $0.category == category }
                // Mood category is always rendered (even when empty) so
                // the "+" add chip is always available — without this
                // first-time users with no custom moods would never see
                // the affordance.
                if !group.isEmpty || category == .people {
                    categoryHeader(category)
                    FlowLayout(spacing: 5) {
                        ForEach(group) { tag in
                            pillView(tag, picked: isPicked(tag))
                        }
                        if category == .people {
                            addPersonChip
                        } else if Self.customAdditionCategories.contains(category) {
                            addCustomTagChip(for: category)
                        }
                    }
                }
            }
        }
    }

    private var categoriesOrdered: [PickerCategory] {
        [.people, .genre, .decade, .rating, .runtime]
    }

    @ViewBuilder
    private func categoryHeader(_ cat: PickerCategory) -> some View {
        // Mood / People use the singular sentence-case keys ("Mood",
        // "People") because Swift's xcstrings symbol generator collapses
        // case and would clash with the existing "Mood" entry. We
        // uppercase visually via `.textCase(.uppercase)` — same look as
        // GENRE / DECADE / VIBE / LENGTH which are already all-caps keys.
        let label: LocalizedStringKey = {
            switch cat {
            case .people:  return "People"
            case .genre:   return "GENRE"
            case .decade:  return "DECADE"
            case .rating:  return "VIBE"
            case .runtime: return "LENGTH"
            }
        }()
        Text(label, bundle: .module)
            .scaledFont(size: 9, weight: .semibold)
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Add-mood chip

    // MARK: - Add-person chip

    /// Same UX as `addMoodChip` but writes into `customPeople`. The name
    /// only resolves to a TMDB id when the user *taps* the resulting
    /// pill — we don't pre-resolve here, so a typo just costs a pill
    /// that the user can right-click to remove.
    @ViewBuilder
    private var addPersonChip: some View {
        if addingPerson {
            HStack(spacing: 4) {
                TextField("Person", text: $newPersonText,
                          prompt: Text("Add person", bundle: .module))
                    .textFieldStyle(.plain)
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(.primary)
                    .focused($newPersonFocused)
                    .frame(width: 110)
                    .onSubmit { commitNewPerson() }
                Button {
                    commitNewPerson()
                } label: {
                    Image(systemName: "checkmark")
                        .scaledFont(size: 8, weight: .bold)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Save person", bundle: .module))
                // Cancel — close input without saving. Mirrors macOS form
                // affordances where ✓ commits and × bails.
                Button {
                    newPersonText = ""
                    addingPerson = false
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(size: 8, weight: .bold)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Cancel", bundle: .module))
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.secondary.opacity(0.6), lineWidth: 1)
            )
            .onAppear { newPersonFocused = true }
        } else {
            Button {
                addingPerson = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                        .scaledFont(size: 8, weight: .bold)
                    Text("Add person", bundle: .module)
                        .scaledFont(size: 10, weight: .semibold)
                }
                // Neutral grey — the "+" chip is a meta affordance ("add
                // something here"), not a selectable filter. Painting it
                // the category color made it compete visually with the
                // real pills.
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.secondary.opacity(0.5),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func commitNewPerson() {
        let name = newPersonText.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.addCustomPerson(name)
        // Auto-select the new name — fires the same TMDB resolve path
        // as a normal pill tap, so the pill lights up and personId
        // lands in the filter once resolution returns.
        if !name.isEmpty {
            Task { await viewModel.togglePerson(name: name) }
        }
        newPersonText = ""
        addingPerson = false
    }

    // MARK: - Add-tag chip (genre / decade / rating / runtime)

    /// Shared "+" affordance for the four catalog categories. Same
    /// expand-to-inline-input pattern as `addPersonChip`, but writes
    /// into the per-category map. Now uniformly grey across categories
    /// — these are meta-affordances ("add a new tag here"), not
    /// selectable filters, so they shouldn't compete visually with the
    /// real pills.
    @ViewBuilder
    private func addCustomTagChip(for category: PickerCategory) -> some View {
        if addingTagFor == category.rawValue {
            HStack(spacing: 4) {
                TextField("Custom", text: $newCustomTagText,
                          prompt: Text("Add", bundle: .module))
                    .textFieldStyle(.plain)
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(.primary)
                    .focused($newCustomTagFocused)
                    .frame(width: 90)
                    .onSubmit { commitNewCustomTag(category: category) }
                Button {
                    commitNewCustomTag(category: category)
                } label: {
                    Image(systemName: "checkmark")
                        .scaledFont(size: 8, weight: .bold)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Button {
                    newCustomTagText = ""
                    addingTagFor = nil
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(size: 8, weight: .bold)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Cancel", bundle: .module))
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.secondary.opacity(0.6), lineWidth: 1)
            )
            .onAppear { newCustomTagFocused = true }
        } else {
            Button {
                addingTagFor = category.rawValue
                newCustomTagText = ""
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                        .scaledFont(size: 8, weight: .bold)
                    Text("Add", bundle: .module)
                        .scaledFont(size: 10, weight: .semibold)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.secondary.opacity(0.5),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func commitNewCustomTag(category: PickerCategory) {
        let label = newCustomTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.addCustomTag(category: category.rawValue, label: label)
        // Custom genre / decade / rating / runtime labels feed `moodText`
        // (see `toggle(_:)`), so auto-select by writing the label there.
        if !label.isEmpty { viewModel.moodText = label }
        newCustomTagText = ""
        addingTagFor = nil
    }

    // MARK: - Pill view

    @ViewBuilder
    private func pillView(_ tag: PickerTag, picked: Bool) -> some View {
        let color = tint(for: tag)
        let pill = PillButtonView(tag: tag, color: color, picked: picked,
                                  toggle: { toggle(tag) })
        if isCustomTag(tag) {
            // Custom genre / decade / rating / runtime label — removable.
            let label = customTagLabel(tag)
            let cat = tag.category.rawValue
            pill.contextMenu {
                Button(role: .destructive) {
                    viewModel.removeCustomTag(category: cat, label: label)
                } label: {
                    Label {
                        Text("Remove", bundle: .module)
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
            }
        } else if tag.category == .people {
            // Only user-added names are removable. Predefined names
            // (`Self.predefinedPeople`) stay in the catalog.
            let name = String(tag.id.dropFirst("person.".count))
            let isCustom = viewModel.customPeople.contains(name)
            if isCustom {
                pill.contextMenu {
                    Button(role: .destructive) {
                        viewModel.removeCustomPerson(name)
                    } label: {
                        Label {
                            Text("Remove person", bundle: .module)
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                }
            } else {
                pill
            }
        } else {
            pill
        }
    }

    /// Pill button with per-instance hover state.
    /// Requires a separate struct because @State for hover can't live inline
    /// in a @ViewBuilder function — each pill needs independent hover tracking.
    private struct PillButtonView: View {
        let tag: PickerTag
        let color: Color
        let picked: Bool
        let toggle: () -> Void
        @State private var isHovering = false

        var body: some View {
            let activeColor: Color = (isHovering || picked) ? color : .secondary
            let strokeOpacity: Double = (isHovering || picked) ? 0.85 : 0.4
            let strokeWidth: CGFloat = (isHovering || picked) ? 1.2 : 1.0
            Button(action: toggle) {
                HStack(spacing: 3) {
                    if let icon = tag.icon {
                        Image(systemName: icon)
                            .scaledFont(size: 8, weight: .semibold)
                    }
                    Text(LocalizedStringKey(tag.label), bundle: .module)
                        .scaledFont(size: 10, weight: .semibold)
                }
                .foregroundStyle(activeColor)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(activeColor.opacity(strokeOpacity),
                                lineWidth: strokeWidth)
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in isHovering = hovering }
        }
    }

    // MARK: - Chip composer

    /// Tag-input style composer:
    ///   [🎞 Movies][Tarantino ×][Comedy ×]  Or describe…  [↑]
    /// Chips wrap to additional rows via FlowLayout; the TextField flows
    /// inline after the last chip and absorbs the remaining space.
    private var chipComposer: some View {
        FlowLayout(spacing: 5) {
            kindChip
            ForEach(activeChips) { chip in
                activeChipView(chip)
            }
            TextField("", text: $freeText,
                      prompt: Text(LocalizedStringKey(currentPlaceholder),
                                   bundle: .module),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .focused($freeTextFocused)
                .lineLimit(1...4)
                .scaledFont(size: 13)
                .frame(minWidth: 80)
                .onSubmit {
                    if canCommit { commit() }
                }
                .onKeyPress(.delete) {
                    // Backspace on empty text removes the last chip — the
                    // standard tag-input affordance. If text is non-empty,
                    // let the OS handle the deletion normally.
                    if freeText.isEmpty, let last = activeChips.last {
                        last.onRemove()
                        return .handled
                    }
                    return .ignored
                }
            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassyFloatingBar()
    }

    @ViewBuilder
    private var kindChip: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                viewModel.mediaSelection =
                    (viewModel.mediaSelection == .movie) ? .show : .movie
                viewModel.hasPickedKind = true
                viewModel.mediaSelectionChanged()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.mediaSelection == .show ? "tv" : "film")
                    .scaledFont(size: 10, weight: .semibold)
                Text(viewModel.mediaSelection == .show ? "Shows" : "Movies",
                     bundle: .module)
                    .scaledFont(size: 11, weight: .semibold)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(
                Capsule().stroke(Color.secondary.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(Text("Switch movie/show kind", bundle: .module))
    }

    @ViewBuilder
    private func activeChipView(_ chip: ActiveChipDescriptor) -> some View {
        let color = Self.color(for: chip.category)
        HStack(spacing: 3) {
            Text(chip.label)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(color)
            Button(action: chip.onRemove) {
                Image(systemName: "xmark")
                    .scaledFont(size: 8, weight: .bold)
                    .foregroundStyle(color.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 7).padding(.trailing, 5).padding(.vertical, 3)
        .overlay(
            Capsule().stroke(color.opacity(0.85), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var sendButton: some View {
        Button {
            if canCommit { commit() }
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .scaledFont(size: 22)
                .foregroundStyle(canCommit ? Color.primary : Color.secondary.opacity(0.4))
        }
        .buttonStyle(.plain)
        .disabled(!canCommit)
        .keyboardShortcut(.return, modifiers: [.command])
    }

    // MARK: - Composer

    private var composerPlaceholder: LocalizedStringKey {
        let pickedFilters = selectedTagsForCurrentStage.count
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
        viewModel.hasPickedKind || !freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commit() {
        let free = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.moodText = free
        viewModel.userSubmittedMood()
        freeTextFocused = false
        onSubmit()
    }
}
