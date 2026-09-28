import SwiftUI

/// State with the app's lifetime rather than a one-shot `AppMessages` post, which
/// hosts not yet listening dropped. A fresh `id` per request lets the same title open twice.
public final class DetailRouter: ObservableObject {
    public static let shared = DetailRouter()

    public struct Request: Identifiable, Equatable {
        public let id = UUID()
        public let item: QueueItem
    }

    @Published public private(set) var request: Request?

    private init() {}

    public func open(_ item: QueueItem) {
        request = Request(item: item)
    }
}

public extension View {
    /// Off-screen hosts guard on their own "am I the visible tab" flag.
    func onDetailRequest(perform: @escaping @MainActor (QueueItem) -> Void) -> some View {
        modifier(DetailRequestObserver(perform: perform))
    }
}

private struct DetailRequestObserver: ViewModifier {
    @ObservedObject private var router = DetailRouter.shared
    let perform: @MainActor (QueueItem) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: router.request?.id) { _, _ in
            guard let item = router.request?.item else { return }
            perform(item)
        }
    }
}


/// Same as `DetailRouter`, for the "add this to an arr" panel.
public final class SearchAddRouter: ObservableObject {
    public static let shared = SearchAddRouter()

    /// What Back honours: chat returns to chat, a quiz card to the deck.
    public enum Origin: Sendable, Equatable { case chat, quiz, search }

    public struct Request: Identifiable, Equatable {
        public let id = UUID()
        public let result: SearchResult
        public let origin: Origin
    }

    @Published public private(set) var request: Request?

    private init() {}

    public func open(_ result: SearchResult, origin: Origin) {
        request = Request(result: result, origin: origin)
    }
}

public extension View {
    func onSearchAddRequest(perform: @escaping @MainActor (SearchResult, SearchAddRouter.Origin) -> Void) -> some View {
        modifier(SearchAddRequestObserver(perform: perform))
    }
}

private struct SearchAddRequestObserver: ViewModifier {
    @ObservedObject private var router = SearchAddRouter.shared
    let perform: @MainActor (SearchResult, SearchAddRouter.Origin) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: router.request?.id) { _, _ in
            guard let request = router.request else { return }
            perform(request.result, request.origin)
        }
    }
}
