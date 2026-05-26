# Chat empty state + Quiz mode — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the Chat tab so the empty state surfaces a clean Quiz entry point and a small set of suggestion prompts; add a self-contained Quiz mode (poster swipe + bottom-sheet filters) that calls existing TMDB discover / suggest tools without going through the LLM router.

**Architecture:** New SwiftUI views split out of `ChatView` plus a small state-machine extension on `ChatViewModel`. Quiz fetches its deck via a new typed wrapper on `LocalToolBackend` (bypassing the LLM) and adds items via the existing `SearchViewModel.addMovie` / `addSeries` paths. No new tool endpoints.

**Tech stack:** Swift 5.9+, SwiftUI, Swift Testing, ArrCore package (Packages/ArrCore/).

**Reference patterns (do not copy verbatim):**
- `.worktrees/discover-llm-only/Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift` — prior take on the deck state machine.
- `.claude/worktrees/discover-tab/Packages/ArrCore/Sources/ArrCore/Views/DiscoverCardView.swift` — prior card layout.

These are previous experiments the team rejected as visually busy. Treat as one valid implementation of similar moving parts, **not** as a template. New work must match `docs/superpowers/specs/2026-05-27-chat-empty-state-mockup.svg`.

**Spec:** `docs/superpowers/specs/2026-05-27-chat-empty-state-and-quiz-design.md`

---

## Pre-flight

- [ ] **P1: Create a worktree for this work**

```bash
git worktree add .worktrees/chat-empty-quiz -b chat-empty-quiz
cd .worktrees/chat-empty-quiz
```

All subsequent file paths are relative to the worktree root.

- [ ] **P2: Confirm the spec is current**

```bash
ls docs/superpowers/specs/2026-05-27-chat-empty-state-and-quiz-design.md \
   docs/superpowers/specs/2026-05-27-chat-empty-state-mockup.svg
```

Expected: both files exist.

---

## Task 1 — Models: `QuizFilters` and `QuizSession`

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Models/QuizFilters.swift`
- Create: `Packages/ArrCore/Sources/ArrCore/Models/QuizSession.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/QuizFiltersTests.swift`

- [ ] **Step 1: Write failing tests for `QuizFilters` defaults and lens label**

```swift
// QuizFiltersTests.swift
import Testing
@testable import ArrCore

@Suite("QuizFilters")
struct QuizFiltersTests {
    @Test("defaults match spec: movies, popular, hide owned, no mood/year/freeText")
    func defaultsMatchSpec() {
        let f = QuizFilters.defaults
        #expect(f.contentType == .movies)
        #expect(f.genre == nil)
        #expect(f.yearBucket == .any)
        #expect(f.sortBy == .popular)
        #expect(f.hideOwned == true)
        #expect(f.freeText == nil)
    }

    @Test("lens label shows content type + sort + nieobejrzane")
    func lensLabelDefault() {
        let f = QuizFilters.defaults
        #expect(f.lensLabel == "Filmy · Popularne · nieobejrzane")
    }

    @Test("lens label includes mood when set")
    func lensLabelWithMood() {
        var f = QuizFilters.defaults
        f.genre = "horror"
        #expect(f.lensLabel == "Filmy · Horror · Popularne · nieobejrzane")
    }

    @Test("lens label uses free-text indicator when set")
    func lensLabelFreeText() {
        var f = QuizFilters.defaults
        f.freeText = "coś jak Drive"
        #expect(f.lensLabel == "Filmy · „coś jak Drive\u{201D} · nieobejrzane")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -scheme ArrBarr -project ArrBarr.xcodeproj test \
  -only-testing:ArrCoreTests/QuizFiltersTests 2>&1 | tail -20
```

Expected: compile errors / FAIL — `QuizFilters` not defined.

- [ ] **Step 3: Implement `QuizFilters`**

```swift
// Packages/ArrCore/Sources/ArrCore/Models/QuizFilters.swift
import Foundation

public struct QuizFilters: Equatable, Sendable {
    public enum ContentType: String, Equatable, Sendable {
        case movies, series, both
        public var displayLabel: String {
            switch self {
            case .movies: return "Filmy"
            case .series: return "Seriale"
            case .both: return "Oba"
            }
        }
    }

    public enum YearBucket: Equatable, Sendable {
        case any
        case decade(Int)   // e.g. 1990 -> "90s"
        case from(Int)     // e.g. 2020 -> "2020+"

        public var displayLabel: String {
            switch self {
            case .any: return "Cokolwiek"
            case .decade(let y): return "\(y % 100)s"
            case .from(let y): return "\(y)+"
            }
        }

        public var range: (Int, Int)? {
            switch self {
            case .any: return nil
            case .decade(let y): return (y, y + 9)
            case .from(let y): return (y, Calendar.current.component(.year, from: Date()) + 1)
            }
        }
    }

    public enum SortBy: String, Equatable, Sendable {
        case popular, topRated, newest
        public var displayLabel: String {
            switch self {
            case .popular: return "Popularne"
            case .topRated: return "Wysoko oceniane"
            case .newest: return "Najnowsze"
            }
        }
        public var tmdbKey: String {
            switch self {
            case .popular: return "popularity.desc"
            case .topRated: return "vote_average.desc"
            case .newest: return "primary_release_date.desc"
            }
        }
    }

    public var contentType: ContentType
    public var genre: String?            // lowercase TMDB genre name
    public var yearBucket: YearBucket
    public var sortBy: SortBy
    public var hideOwned: Bool
    public var freeText: String?         // when non-empty, uses suggest_titles

    public static let defaults = QuizFilters(
        contentType: .movies,
        genre: nil,
        yearBucket: .any,
        sortBy: .popular,
        hideOwned: true,
        freeText: nil
    )

    public var lensLabel: String {
        var parts: [String] = [contentType.displayLabel]
        if let g = genre { parts.append(g.capitalized) }
        if case .any = yearBucket {} else { parts.append(yearBucket.displayLabel) }
        if let t = freeText, !t.isEmpty {
            parts.append("„\(t)\u{201D}")
        } else {
            parts.append(sortBy.displayLabel)
        }
        if hideOwned { parts.append("nieobejrzane") }
        return parts.joined(separator: " · ")
    }
}
```

- [ ] **Step 4: Implement `QuizSession`**

```swift
// Packages/ArrCore/Sources/ArrCore/Models/QuizSession.swift
import Foundation

public struct QuizSession: Equatable, Sendable {
    public let filters: QuizFilters
    public var deck: [SearchResult]
    public var index: Int
    public var addedCount: Int
    public var skippedCount: Int

    public var currentCard: SearchResult? {
        guard index < deck.count else { return nil }
        return deck[index]
    }

    public var progress: (current: Int, total: Int) {
        (min(index + 1, deck.count), deck.count)
    }

    public var isExhausted: Bool { index >= deck.count }

    public init(filters: QuizFilters, deck: [SearchResult]) {
        self.filters = filters
        self.deck = deck
        self.index = 0
        self.addedCount = 0
        self.skippedCount = 0
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild -scheme ArrBarr -project ArrBarr.xcodeproj test \
  -only-testing:ArrCoreTests/QuizFiltersTests 2>&1 | tail -20
```

Expected: 4 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Models/QuizFilters.swift \
        Packages/ArrCore/Sources/ArrCore/Models/QuizSession.swift \
        Packages/ArrCore/Tests/ArrCoreTests/QuizFiltersTests.swift
git commit -m "feat(quiz): QuizFilters + QuizSession models"
```

---

## Task 2 — Typed deck fetch on `LocalToolBackend`

**Goal:** A view-layer-callable function that builds a `[SearchResult]` deck from filters, bypassing the LLM router.

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/LocalToolBackend.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/LocalToolBackendQuizDeckTests.swift`

- [ ] **Step 1: Read the existing tool dispatch**

```bash
sed -n '37,120p' Packages/ArrCore/Sources/ArrCore/Services/LocalToolBackend.swift
```

Note the private helpers `tmdbDiscoverMovies(_:)`, `tmdbDiscoverSeries(_:)`, `suggestTitles(_:)`. They take `JSONValue` and return `ToolCallOutput`. We will add a typed public wrapper that constructs the JSON arguments and parses the rich output back into `[SearchResult]`.

- [ ] **Step 2: Write failing test (uses a stub HTTP layer or `URLProtocol`)**

The existing tests already stub TMDB. Mirror the closest existing pattern (search `LocalToolBackend` tests in `Packages/ArrCore/Tests/ArrCoreTests/`).

```swift
// LocalToolBackendQuizDeckTests.swift
import Testing
@testable import ArrCore

@Suite("LocalToolBackend.fetchQuizDeck")
struct LocalToolBackendQuizDeckTests {
    @Test("defaults call tmdb_discover_movies with popularity.desc and no genre/year")
    func defaultsHitDiscover() async throws {
        let stub = StubToolBackend()
        let deck = try await stub.fetchQuizDeck(filters: .defaults)
        #expect(stub.lastToolCalled == "tmdb_discover_movies")
        #expect(stub.lastArgs?["sortBy"] == .string("popularity.desc"))
        #expect(stub.lastArgs?["genre"] == nil)
        #expect(deck.count == stub.scriptedDeckSize)
    }

    @Test("freeText routes to suggest_titles, ignores genre/year/sort")
    func freeTextRoutesToSuggest() async throws {
        let stub = StubToolBackend()
        var f = QuizFilters.defaults
        f.freeText = "coś jak Drive"
        f.genre = "horror"     // should be ignored
        _ = try await stub.fetchQuizDeck(filters: f)
        #expect(stub.lastToolCalled == "suggest_titles")
        #expect(stub.lastArgs?["query"] == .string("coś jak Drive"))
        #expect(stub.lastArgs?["genre"] == nil)
    }

    @Test("hideOwned filters out items marked [OWNED]")
    func hideOwnedFilters() async throws {
        let stub = StubToolBackend()
        stub.deckIncludesOwned = true
        let deck = try await stub.fetchQuizDeck(filters: .defaults)
        #expect(deck.allSatisfy { !$0.isOwned })
    }
}
```

`StubToolBackend` exists for the test target — extend it (or create it) to record `lastToolCalled` / `lastArgs` and return a synthetic deck. If the existing test file uses a different mock pattern, adapt accordingly.

- [ ] **Step 3: Run tests, verify they fail**

```bash
xcodebuild -scheme ArrBarr -project ArrBarr.xcodeproj test \
  -only-testing:ArrCoreTests/LocalToolBackendQuizDeckTests 2>&1 | tail -20
```

Expected: FAIL — `fetchQuizDeck(filters:)` not defined.

- [ ] **Step 4: Implement the public wrapper**

Add to `LocalToolBackend.swift` (public method on the actor):

```swift
public func fetchQuizDeck(filters: QuizFilters) async throws -> [SearchResult] {
    let toolName: String
    let args: JSONValue

    if let text = filters.freeText, !text.isEmpty {
        toolName = "suggest_titles"
        args = .object([
            "query": .string(text),
            "kind": .string(filters.contentType == .series ? "tv" : "movie"),
        ])
    } else {
        toolName = filters.contentType == .series
            ? "tmdb_discover_series"
            : "tmdb_discover_movies"
        var fields: [String: JSONValue] = [
            "sortBy": .string(filters.sortBy.tmdbKey)
        ]
        if let g = filters.genre { fields["genre"] = .string(g) }
        if let range = filters.yearBucket.range {
            fields["startYear"] = .int(range.0)
            fields["endYear"] = .int(range.1)
        }
        args = .object(fields)
    }

    let output = try await callTool(name: toolName, arguments: args)
    let results = Self.searchResults(from: output)
    return filters.hideOwned ? results.filter { !$0.isOwned } : results
}

private static func searchResults(from output: ToolCallOutput) -> [SearchResult] {
    // Reuse the existing rich-output parser. If a parser already exists
    // in this file or in ChatRichContent.swift, call it; otherwise extract
    // the rich payload and decode the SearchResult array.
    // Concrete extraction: inspect `output.rich` for the discover/suggest
    // shape used in the existing rich-card pipeline and map to SearchResult.
    // The mapping already exists in the production code path that renders
    // discover results today (RichToolResultView). Factor that mapping into
    // a static helper here and have RichToolResultView call it.
    fatalError("see Task 2 step 5")
}
```

- [ ] **Step 5: Factor the existing rich → SearchResult mapping**

Find the existing code path that turns a discover tool result into the cards shown today. Likely in `RichToolResultView.swift` or `ChatRichContent.swift`. Extract that mapping into a static helper (`SearchResult.fromDiscoverOutput(_:)` or similar) and call it from both places.

```bash
grep -nE "SearchResult|fromDiscover|rich" \
  Packages/ArrCore/Sources/ArrCore/Views/RichToolResultView.swift \
  Packages/ArrCore/Sources/ArrCore/Models/ChatRichContent.swift | head -40
```

Once located, move the mapping to `Models/SearchResult+ToolOutput.swift` (new file). Replace `fatalError` above with the real call.

- [ ] **Step 6: Run tests, verify they pass**

```bash
xcodebuild -scheme ArrBarr -project ArrBarr.xcodeproj test \
  -only-testing:ArrCoreTests/LocalToolBackendQuizDeckTests 2>&1 | tail -20
```

Expected: 3 tests pass. No regressions in existing rich-card tests.

- [ ] **Step 7: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/LocalToolBackend.swift \
        Packages/ArrCore/Sources/ArrCore/Models/SearchResult+ToolOutput.swift \
        Packages/ArrCore/Sources/ArrCore/Views/RichToolResultView.swift \
        Packages/ArrCore/Tests/ArrCoreTests/LocalToolBackendQuizDeckTests.swift
git commit -m "feat(quiz): typed deck fetch on LocalToolBackend"
```

---

## Task 3 — `ChatViewModel` state machine extension

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/ViewModels/ChatViewModel.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/ChatViewModelQuizTests.swift`

- [ ] **Step 1: Write failing tests for the state machine**

```swift
// ChatViewModelQuizTests.swift
import Testing
@testable import ArrCore

@Suite("ChatViewModel — Quiz state machine")
@MainActor
struct ChatViewModelQuizTests {
    @Test("startQuiz with defaults populates session and switches state")
    func startQuizDefaults() async throws {
        let backend = StubToolBackend(scriptedDeckSize: 5)
        let vm = makeVM(backend: backend)
        await vm.startQuiz(filters: .defaults)
        #expect(vm.tabState == .quizActive)
        #expect(vm.quizSession?.deck.count == 5)
        #expect(vm.quizSession?.filters == .defaults)
    }

    @Test("skip advances index, accept calls add path and advances")
    func skipAndAccept() async throws {
        let backend = StubToolBackend(scriptedDeckSize: 3)
        let search = StubSearchVM()
        let vm = makeVM(backend: backend, search: search)
        await vm.startQuiz(filters: .defaults)
        await vm.skipQuizCard()
        #expect(vm.quizSession?.index == 1)
        #expect(vm.quizSession?.skippedCount == 1)
        await vm.acceptQuizCard()
        #expect(vm.quizSession?.index == 2)
        #expect(vm.quizSession?.addedCount == 1)
        #expect(search.addedMovies.count == 1)
    }

    @Test("applyQuizFilters refetches and resets index")
    func applyFiltersResets() async throws {
        let backend = StubToolBackend(scriptedDeckSize: 3)
        let vm = makeVM(backend: backend)
        await vm.startQuiz(filters: .defaults)
        await vm.skipQuizCard()
        var newFilters = QuizFilters.defaults
        newFilters.genre = "horror"
        await vm.applyQuizFilters(newFilters)
        #expect(vm.quizSession?.filters.genre == "horror")
        #expect(vm.quizSession?.index == 0)
        #expect(vm.quizSession?.skippedCount == 0)
    }

    @Test("exitQuiz returns to .empty when no messages, .conversation otherwise")
    func exitReturnsToPrevious() async throws {
        let backend = StubToolBackend(scriptedDeckSize: 2)
        let vm = makeVM(backend: backend)
        await vm.startQuiz(filters: .defaults)
        vm.exitQuiz()
        #expect(vm.tabState == .empty)
        #expect(vm.quizSession == nil)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
xcodebuild -scheme ArrBarr -project ArrBarr.xcodeproj test \
  -only-testing:ArrCoreTests/ChatViewModelQuizTests 2>&1 | tail -20
```

Expected: compile errors — `tabState`, `quizSession`, `startQuiz` etc. not defined.

- [ ] **Step 3: Extend `ChatViewModel`**

Add to `Packages/ArrCore/Sources/ArrCore/ViewModels/ChatViewModel.swift`:

```swift
public enum ChatTabState: Equatable, Sendable {
    case empty
    case conversation
    case quizActive
}

extension ChatViewModel {
    public var tabState: ChatTabState {
        if quizSession != nil { return .quizActive }
        return messages.isEmpty ? .empty : .conversation
    }
}

// Inside ChatViewModel:
//   @Published public private(set) var quizSession: QuizSession?
//   public weak var searchViewModel: SearchViewModel?  // injected at construction

public func startQuiz(filters: QuizFilters) async {
    do {
        let deck = try await backend.fetchQuizDeck(filters: filters)
        quizSession = QuizSession(filters: filters, deck: deck)
    } catch {
        lastError = String(describing: error)
    }
}

public func applyQuizFilters(_ filters: QuizFilters) async {
    await startQuiz(filters: filters)
}

public func skipQuizCard() {
    guard var s = quizSession else { return }
    s.skippedCount += 1
    s.index += 1
    quizSession = s
}

public func acceptQuizCard() async {
    guard var s = quizSession, let card = s.currentCard else { return }
    await searchViewModel?.addFromQuiz(card)
    s.addedCount += 1
    s.index += 1
    quizSession = s
}

public func exitQuiz() {
    quizSession = nil
}
```

Where `searchViewModel?.addFromQuiz(_:)` is a thin wrapper that calls `addMovie` or `addSeries` based on `card.mediaRef` with default profile / root folder / monitor mode. Implement that wrapper in `SearchViewModel`:

```swift
public func addFromQuiz(_ result: SearchResult) async {
    // Pick first quality profile / root folder / default monitor mode for
    // the source. Replicate the defaults applied by SearchAddPanel when
    // a user opens a card and just hits "Add" without changing fields.
    switch result.mediaRef {
    case .tmdb where result.source == .radarr:
        await addMovie(result,
                       qualityProfileId: defaultQualityProfileId(.radarr),
                       rootFolderPath: defaultRootFolder(.radarr),
                       monitor: .movieOnly)
    case .tvdb, .tmdb:
        await addSeries(result,
                        qualityProfileId: defaultQualityProfileId(.sonarr),
                        rootFolderPath: defaultRootFolder(.sonarr),
                        monitor: .future,
                        seriesType: .standard,
                        seasonFolder: true)
    default: break
    }
}
```

Use the existing `defaultQualityProfileId` / `defaultRootFolder` helpers if present; otherwise inline the same "first available" lookup used by `SearchAddPanel` on first render.

- [ ] **Step 4: Run tests, verify they pass**

```bash
xcodebuild -scheme ArrBarr -project ArrBarr.xcodeproj test \
  -only-testing:ArrCoreTests/ChatViewModelQuizTests 2>&1 | tail -20
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/ViewModels/ChatViewModel.swift \
        Packages/ArrCore/Sources/ArrCore/ViewModels/SearchViewModel.swift \
        Packages/ArrCore/Tests/ArrCoreTests/ChatViewModelQuizTests.swift
git commit -m "feat(quiz): ChatViewModel state machine + addFromQuiz"
```

---

## Task 4 — Design token additions

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/Tokens.swift`

- [ ] **Step 1: Add new radii**

```swift
public enum Radius {
    public static let chip: CGFloat = 4
    public static let card: CGFloat = 6
    public static let panel: CGFloat = 10
    public static let suggestionRow: CGFloat = 12
    public static let filterPill: CGFloat = 14
    public static let actionButton: CGFloat = 24
    public static let input: CGFloat = 22
}
```

- [ ] **Step 2: Verify build**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr \
  -configuration Debug -derivedDataPath build build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/Tokens.swift
git commit -m "feat(tokens): add suggestionRow / filterPill / actionButton / input radii"
```

---

## Task 5 — Empty-state primitives: `QuizFeatureCard`, `SuggestionPromptRow`

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Views/QuizFeatureCard.swift`
- Create: `Packages/ArrCore/Sources/ArrCore/Views/SuggestionPromptRow.swift`

- [ ] **Step 1: Implement `QuizFeatureCard`**

```swift
// Packages/ArrCore/Sources/ArrCore/Views/QuizFeatureCard.swift
import SwiftUI

public struct QuizFeatureCard: View {
    public let lensCaption: String   // e.g. "popularne · nieobejrzane"
    public let onStart: () -> Void

    public init(lensCaption: String, onStart: @escaping () -> Void) {
        self.lensCaption = lensCaption
        self.onStart = onStart
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(red: 122/255, green: 90/255, blue: 248/255),
                                     Color(red: 79/255, green: 70/255, blue: 229/255)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text("chat.empty.quiz.title", bundle: .module)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("chat.empty.quiz.subtitle", bundle: .module)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Button(action: onStart) {
                HStack {
                    Text("chat.empty.quiz.cta", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(lensCaption)
                        .font(.system(size: 12))
                        .opacity(0.7)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(white: 0.11))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 244/255, green: 241/255, blue: 251/255),
                             Color(red: 238/255, green: 240/255, blue: 251/255)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        )
    }
}
```

- [ ] **Step 2: Implement `SuggestionPromptRow`**

```swift
// Packages/ArrCore/Sources/ArrCore/Views/SuggestionPromptRow.swift
import SwiftUI

public struct SuggestionPromptRow: View {
    public let titleKey: LocalizedStringKey
    public let onTap: () -> Void

    public init(_ titleKey: LocalizedStringKey, onTap: @escaping () -> Void) {
        self.titleKey = titleKey
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack {
                Text(titleKey, bundle: .module)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.suggestionRow, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.55))
            )
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 3: Rebuild and verify no warnings**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug \
  -derivedDataPath build build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/QuizFeatureCard.swift \
        Packages/ArrCore/Sources/ArrCore/Views/SuggestionPromptRow.swift
git commit -m "feat(views): QuizFeatureCard + SuggestionPromptRow primitives"
```

---

## Task 6 — `ChatEmptyStateView`

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Views/ChatEmptyStateView.swift`

- [ ] **Step 1: Implement**

```swift
// Packages/ArrCore/Sources/ArrCore/Views/ChatEmptyStateView.swift
import SwiftUI

public struct ChatEmptyStateView: View {
    public let lensCaption: String
    public let onQuizStart: () -> Void
    public let onSuggestionTap: (String) -> Void

    private struct Suggestion {
        let key: LocalizedStringKey
        let prompt: String
    }

    private let suggestions: [Suggestion] = [
        .init(key: "chat.empty.suggest.upcoming",  prompt: "Co dziś wychodzi?"),
        .init(key: "chat.empty.suggest.queue",     prompt: "Co się teraz ściąga?"),
        .init(key: "chat.empty.suggest.mrRobot",   prompt: "Polecisz coś jak Mr. Robot?"),
        .init(key: "chat.empty.suggest.swinton",   prompt: "Filmy z Tildą Swinton"),
    ]

    public init(lensCaption: String,
                onQuizStart: @escaping () -> Void,
                onSuggestionTap: @escaping (String) -> Void) {
        self.lensCaption = lensCaption
        self.onQuizStart = onQuizStart
        self.onSuggestionTap = onSuggestionTap
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("chat.empty.greeting", bundle: .module)
                        .font(.system(size: 22, weight: .semibold))
                    Text("chat.empty.subhead", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)
                .padding(.horizontal, 24)

                QuizFeatureCard(lensCaption: lensCaption, onStart: onQuizStart)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                HStack(spacing: 12) {
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 0.5)
                    Text("chat.empty.divider", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 0.5)
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)

                VStack(spacing: 10) {
                    ForEach(suggestions, id: \.prompt) { s in
                        SuggestionPromptRow(s.key) { onSuggestionTap(s.prompt) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
    }
}
```

- [ ] **Step 2: Add localization keys**

Open `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings` in Xcode and add — with Polish + English (and other existing languages):

```
chat.empty.greeting        → "Co dziś obejrzeć?"           / "What to watch tonight?"
chat.empty.subhead         → "Quiz, podpowiedź albo wpisz pytanie." / "Quiz, a tip, or type a question."
chat.empty.divider         → "ALBO ZAPYTAJ"                / "OR ASK"
chat.empty.quiz.title      → "Quiz"                        / "Quiz"
chat.empty.quiz.subtitle   → "Swipuj propozycje, dodawaj do biblioteki." / "Swipe through picks, add to your library."
chat.empty.quiz.cta        → "Zaczynamy"                   / "Let's go"
chat.empty.suggest.upcoming → "Co dziś wychodzi?"          / "What's out today?"
chat.empty.suggest.queue   → "Co się teraz ściąga?"        / "What's downloading?"
chat.empty.suggest.mrRobot → "Polecisz coś jak Mr. Robot?" / "Suggest something like Mr. Robot?"
chat.empty.suggest.swinton → "Filmy z Tildą Swinton"       / "Movies with Tilda Swinton"
```

- [ ] **Step 3: Build, verify**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug \
  -derivedDataPath build build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/ChatEmptyStateView.swift \
        Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings
git commit -m "feat(views): ChatEmptyStateView with localised copy"
```

---

## Task 7 — `QuizFiltersSheet`

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Views/QuizFiltersSheet.swift`

- [ ] **Step 1: Implement**

Build a sheet that takes a `@Binding<QuizFilters>` plus an `onApply` callback. Mirror the structure in the SVG mockup (sections: Co? / Nastrój / Z jakich lat? / Sortuj / Pomiń to co mam / LUB OPISZ). Use chip primitives (introduce a private `ChipPicker` view inside the file to avoid bloating the public API surface).

Genre options (matches `tmdb_discover_movies` known values):
`[nil, "action", "comedy", "horror", "science fiction", "drama", "romance", "thriller", "animation", "documentary"]`

Year buckets: `[.any, .decade(1980), .decade(1990), .decade(2000), .decade(2010), .from(2020)]`.

Sort: `[.popular, .topRated, .newest]`.

Apply button is a full-width dark pill at the bottom; tapping it dismisses the sheet and calls `onApply(filters)`.

Add localization keys under `chat.quiz.filters.*`.

Full code skeleton (filling in the SwiftUI per the mockup; presented bodies cribbed from `QuizFeatureCard` styling):

```swift
import SwiftUI

public struct QuizFiltersSheet: View {
    @Binding public var filters: QuizFilters
    public let onApply: (QuizFilters) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(filters: Binding<QuizFilters>, onApply: @escaping (QuizFilters) -> Void) {
        self._filters = filters
        self.onApply = onApply
    }

    public var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    contentTypeSection
                    moodSection
                    yearSection
                    sortSection
                    hideOwnedToggle
                    freeTextSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            applyButton
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // ... sections — chip rows wired to `filters` via Binding ...
}
```

(The executor fills the section views matching the SVG: 32pt-tall chip rows for Co?, two-row wrapped chips for Mood, single-row for Year and Sort, a `Toggle("…", isOn: $filters.hideOwned)`, and a `TextField` for `filters.freeText`. Each chip is a `Button` styled per the mockup's selected/unselected appearance.)

- [ ] **Step 2: Add chip-picker primitive (private to the file)**

```swift
private struct ChipRow<Value: Hashable, Label: View>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> Label
    var body: some View {
        // FlowLayout (use SwiftUI's Layout protocol or a stack with wrapping)
        // Each chip: selected = .black bg, white text; otherwise white bg + hairline.
    }
}
```

If a flow layout doesn't exist in the codebase, write a minimal one in the same file (50-80 lines). Do not add a third-party dependency.

- [ ] **Step 3: Build, verify**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug \
  -derivedDataPath build build 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/QuizFiltersSheet.swift \
        Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings
git commit -m "feat(views): QuizFiltersSheet"
```

---

## Task 8 — `QuizFiltersPill` + `QuizActiveView`

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Views/QuizFiltersPill.swift`
- Create: `Packages/ArrCore/Sources/ArrCore/Views/QuizActiveView.swift`

- [ ] **Step 1: Implement `QuizFiltersPill`**

```swift
import SwiftUI

public struct QuizFiltersPill: View {
    public let label: String
    public let onTap: () -> Void

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 12, weight: .semibold))
                Text(label).font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.55))
            )
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Implement `QuizActiveView`**

```swift
import SwiftUI

public struct QuizActiveView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var sheetFilters: QuizFilters?

    public var body: some View {
        guard let session = viewModel.quizSession else {
            return AnyView(EmptyView())
        }
        return AnyView(content(session: session))
    }

    @ViewBuilder
    private func content(session: QuizSession) -> some View {
        VStack(spacing: 0) {
            header(session: session)
            QuizFiltersPill(label: session.filters.lensLabel) {
                sheetFilters = session.filters
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            progressDots(session: session)
                .padding(.top, 22)

            if let card = session.currentCard {
                QuizPosterCard(result: card)
                    .padding(.horizontal, 48)
                    .padding(.top, 24)
            } else {
                summaryCard(session: session)
            }

            actionButtons(disabled: session.currentCard == nil)
                .padding(.horizontal, 48)
                .padding(.top, 24)
                .padding(.bottom, 20)
        }
        .sheet(item: $sheetFilters) { initial in
            QuizFiltersSheet(filters: .constant(initial)) { applied in
                Task { await viewModel.applyQuizFilters(applied) }
                sheetFilters = nil
            }
        }
    }

    // header, progressDots, summaryCard, actionButtons,
    // QuizPosterCard — concrete bodies match the SVG (Task 0 ref).
}
```

`QuizPosterCard` can live in the same file as a private view. Use `AsyncImage` for the poster URL from `SearchResult`.

- [ ] **Step 3: Build, verify**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug \
  -derivedDataPath build build 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/QuizFiltersPill.swift \
        Packages/ArrCore/Sources/ArrCore/Views/QuizActiveView.swift \
        Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings
git commit -m "feat(views): QuizActiveView + filters pill + poster card"
```

---

## Task 9 — Wire it together in `ChatTabContent` / `ChatView`

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/ChatTabContent.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/ChatView.swift`

- [ ] **Step 1: Replace the inline empty state in `ChatView` with `ChatEmptyStateView`**

In `ChatView.swift`, replace the existing hardcoded suggestions block with:

```swift
if viewModel.messages.isEmpty && !viewModel.isThinking {
    ChatEmptyStateView(
        lensCaption: "popularne · nieobejrzane",
        onQuizStart: { Task { await viewModel.startQuiz(filters: .defaults) } },
        onSuggestionTap: { prompt in Task { await viewModel.send(prompt) } }
    )
}
```

- [ ] **Step 2: Add Quiz routing in `ChatTabContent`**

```swift
public struct ChatTabContent: View {
    @ObservedObject var chatHolder: ChatViewModelHolder

    public var body: some View {
        switch chatHolder.viewModel.tabState {
        case .empty, .conversation:
            ChatView(viewModel: chatHolder.viewModel)   // existing
        case .quizActive:
            QuizActiveView(viewModel: chatHolder.viewModel)
        }
    }
}
```

(Adjust signatures to whatever `ChatTabContent` currently accepts; the point is that the tab content switches at the outer level so the chat input bar disappears in quiz mode.)

- [ ] **Step 3: Build**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug \
  -derivedDataPath build build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Kill + relaunch + smoke test**

```bash
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

Click ArrBarr in the menubar. Switch to the Chat tab.
Expected:
1. Greeting + hero "Quiz" + 4 suggestion rows + chat input visible.
2. Tap "Zaczynamy" → Quiz mode opens with poster card.
3. Tap filters pill → bottom-sheet appears with all sections.
4. Apply a different mood → poster updates.
5. Tap "Pomiń" / "Dodaj" → advance, item enters Radarr.
6. Exit (×) → return to empty state (or conversation if you sent a message first).

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/ChatTabContent.swift \
        Packages/ArrCore/Sources/ArrCore/Views/ChatView.swift
git commit -m "feat(chat): wire new empty state + Quiz routing"
```

---

## Task 10 — Verification + cleanup

- [ ] **Step 1: Full test pass**

```bash
xcodebuild -scheme ArrBarr -project ArrBarr.xcodeproj test 2>&1 | tail -10
```

Expected: All tests pass.

- [ ] **Step 2: Remove dead code**

Delete the hardcoded suggestion list left over in `ChatView.swift` if any, plus any unused helpers replaced by Task 6.

- [ ] **Step 3: Verify no occurrences of the forbidden word**

```bash
grep -rni "tinder" Packages/ArrCore docs/superpowers/specs/2026-05-27-* 2>&1 | head
```

Expected: no matches.

- [ ] **Step 4: Final commit if anything changed**

```bash
git add -A
git diff --cached --stat
git commit -m "chore(quiz): cleanup + final verify"
```

- [ ] **Step 5: Open PR**

```bash
git push -u origin chat-empty-quiz
gh pr create --title "Chat empty state + Quiz mode" --body "$(cat <<'EOF'
## Summary
- Lean empty state with hero Quiz card + 4 suggestion prompts
- Self-contained Quiz mode (poster swipe + filters bottom-sheet)
- New typed deck fetch on LocalToolBackend, no LLM router involvement
- ChatViewModel state machine: empty / conversation / quizActive

## Test plan
- [ ] Unit tests pass (QuizFilters, fetchQuizDeck, ChatViewModel state)
- [ ] Empty state matches mockup
- [ ] Filters sheet applies and refetches
- [ ] Add path lands items in Radarr / Sonarr

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-review notes

- All spec sections (greeting, hero, suggestions, filters sheet, active quiz, defaults, state transitions) map to tasks 1, 3, 6, 7, 8, 9.
- Tokens additions cover the radii the mockup uses (Task 4).
- Localisation strings ship in Tasks 6 and 7 (the only places they're introduced).
- Add path defaults reuse `SearchAddPanel`'s implicit "first available" rule — flagged in Task 3 Step 3 for the executor to verify against current `SearchAddPanel.swift`.
- The bottom-sheet flow layout is intentionally hand-rolled; do not pull in a layout library.
- "Jeszcze raz" / summary card behavior is implemented in Task 8 inside `QuizActiveView`.
- Out-of-scope: person-based Quiz seeds, "Zgadnij film", filter persistence (per spec).
