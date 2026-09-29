import SwiftUI

/// A request that waits for its host: state with the app's lifetime rather than a one-shot post, so a host not
/// mounted yet (a cold launch, a window still opening) takes it when it appears. The first host to take it
/// clears it, and one past `lifetime` is never replayed by a host mounting later.
@Observable
public final class RequestRouter<Value: Sendable> {
    public struct Request: Identifiable, Sendable {
        public let id = UUID()
        public let value: Value
        let sentAt = Date()
    }

    public private(set) var request: Request?
    let lifetime: TimeInterval

    public init(lifetime: TimeInterval = 5) { self.lifetime = lifetime }

    /// A fresh `id` per send, so the same title opens twice.
    public func send(_ value: Value) { request = Request(value: value) }

    fileprivate func take(_ taken: Request) {
        if request?.id == taken.id { request = nil }
    }
}

public enum Router {
    public static let detail = RequestRouter<QueueItem>()
    public static let searchAdd = RequestRouter<SearchAddRoute>()
    /// The search-to-add intent or a chat link that resolved to nothing: run this query on the search surface.
    /// Never stale: the menu-bar panel can't be opened programmatically, so the query waits for its next open.
    public static let searchQuery = RequestRouter<String>(lifetime: .infinity)
}

public struct SearchAddRoute: Sendable {
    /// What Back honours: chat returns to chat, a quiz card to the deck.
    public enum Origin: Sendable, Equatable { case chat, quiz, search }
    public let result: SearchResult
    public let origin: Origin
}

/// A row menu's entry, beside the detail request rather than in it: hosts push the item into details that
/// don't know the router. One-shot: any detail that finishes loading clears it, so an intent whose detail
/// never loaded can't fire on a later open.
enum DetailIntents {
    private static var pending: (itemID: String, intent: DetailIntent)?

    static func stage(_ intent: DetailIntent?, for itemID: String) {
        pending = intent.map { (itemID, $0) }
    }

    static func take(for itemID: String) -> DetailIntent? {
        defer { pending = nil }
        guard let pending, pending.itemID == itemID else { return nil }
        return pending.intent
    }
}

public extension View {
    /// `perform` returns false when this host shouldn't take it (a hidden tab); it then waits for one that does.
    func onRequest<Value>(from router: RequestRouter<Value>, perform: @escaping @MainActor (Value) -> Bool) -> some View {
        modifier(RequestObserver(router: router, perform: perform))
    }
}

private struct RequestObserver<Value: Sendable>: ViewModifier {
    let router: RequestRouter<Value>
    let perform: @MainActor (Value) -> Bool

    func body(content: Content) -> some View {
        content.onChange(of: router.request?.id, initial: true) {
            guard let request = router.request, Date().timeIntervalSince(request.sentAt) < router.lifetime,
                  perform(request.value) else { return }
            router.take(request)
        }
    }
}
