import Foundation
import SwiftUI

@MainActor
public final class DiscoverViewModel: ObservableObject {

    public enum Source: Hashable, CaseIterable, Sendable {
        case tmdb, library, llm
    }

    // MARK: - Published state

    @Published public private(set) var current: DiscoverItem?
    @Published public private(set) var queue: [DiscoverItem] = []
    @Published public var filter = DiscoverFilter()
    @Published public var moodText: String = ""
    @Published public private(set) var failedSources: Set<Source> = []
    @Published public private(set) var llmPoolExhausted: Bool = false
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var pendingAction: DiscoverAction?
    @Published public private(set) var pendingActionItem: DiscoverItem?

    // MARK: - Source closures

    public typealias TMDBSource = @MainActor (DiscoverFilter, Int) async throws -> [DiscoverItem]
    public typealias LibrarySource = @MainActor (DiscoverFilter) async throws -> [DiscoverItem]
    public typealias LLMSource = @MainActor ([String], String) async throws -> [DiscoverItem]

    private var tmdb: TMDBSource?
    private var library: LibrarySource?
    private var llm: LLMSource?

    // MARK: - Internals

    private var seenKeys = Set<String>()
    private var llmShownTitles: [String] = []
    private var tmdbPage = 0
    private var libraryDrained = false
    private var llmDormant = false
    private var topUpTask: Task<Void, Never>?
    private let topUpThreshold = 5

    public init() {}

    public func configure(tmdb: TMDBSource?, library: LibrarySource?, llm: LLMSource?) {
        self.tmdb = tmdb
        self.library = library
        self.llm = llm
    }

    // MARK: - Lifecycle

    public func start() async {
        reset()
        isLoading = true
        await fillBucket()
        advanceIfNeeded()
        isLoading = false
    }

    public func reshuffle() async {
        await start()
    }

    public func swipe(right: Bool) async {
        guard let item = current else { return }
        if right {
            pendingAction = item.action
            pendingActionItem = item
        }
        current = nil
        advanceIfNeeded()
        if queue.count < topUpThreshold {
            scheduleTopUp()
        }
    }

    public func requestMoreLLM() async {
        guard llm != nil else { return }
        llmDormant = false
        llmPoolExhausted = false
        await drain(source: .llm)
        advanceIfNeeded()
    }

    public func clearPendingAction() {
        pendingAction = nil
        pendingActionItem = nil
    }

    // MARK: - Round-robin fill

    private func fillBucket() async {
        for src in availableSources() {
            await drain(source: src)
        }
    }

    private func availableSources() -> [Source] {
        var out: [Source] = []
        if tmdb != nil && !failedSources.contains(.tmdb) { out.append(.tmdb) }
        if library != nil && !failedSources.contains(.library) && !libraryDrained {
            out.append(.library)
        }
        if llm != nil && !failedSources.contains(.llm) && !llmDormant && !moodText.isEmpty {
            out.append(.llm)
        }
        return out
    }

    private func drain(source: Source) async {
        do {
            let items: [DiscoverItem]
            switch source {
            case .tmdb:
                tmdbPage += 1
                items = try await tmdb!(filter, tmdbPage)
            case .library:
                items = try await library!(filter)
                libraryDrained = true
            case .llm:
                items = try await llm!(llmShownTitles, moodText)
                if items.isEmpty {
                    llmDormant = true
                    llmPoolExhausted = true
                } else {
                    llmShownTitles.append(contentsOf: items.map(titleYearKey))
                }
            }
            append(items)
        } catch {
            failedSources.insert(source)
            errorMessage = "Discover source failed: \(source) (\(error))"
        }
    }

    private func append(_ items: [DiscoverItem]) {
        for it in items {
            if seenKeys.insert(it.dedupKey).inserted {
                queue.append(it)
            }
        }
    }

    private func advanceIfNeeded() {
        if current == nil, !queue.isEmpty {
            current = queue.removeFirst()
        }
    }

    private func scheduleTopUp() {
        if let existing = topUpTask, !existing.isCancelled { return }
        topUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.topUpTask = nil }
            for src in self.availableSources() {
                if self.queue.count >= self.topUpThreshold { break }
                await self.drain(source: src)
            }
            self.advanceIfNeeded()
        }
    }

    private func reset() {
        current = nil
        queue.removeAll()
        seenKeys.removeAll()
        llmShownTitles.removeAll()
        tmdbPage = 0
        libraryDrained = false
        llmDormant = false
        llmPoolExhausted = false
        failedSources.removeAll()
        errorMessage = nil
        pendingAction = nil
        pendingActionItem = nil
        topUpTask?.cancel()
        topUpTask = nil
    }

    private func titleYearKey(_ item: DiscoverItem) -> String {
        let year = item.result.year.map(String.init) ?? ""
        return year.isEmpty ? item.result.title : "\(item.result.title) (\(year))"
    }
}
