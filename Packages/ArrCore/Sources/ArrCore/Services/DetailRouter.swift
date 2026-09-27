import SwiftUI

/// Who is asked to open a detail view, and with what.
///
/// This used to be a one-shot `AppMessages.OpenDetail`, and the tap simply did
/// not arrive: a library tile logged "open detail requested" while the popover
/// logged nothing at all. The queue never showed the bug because its rows set
/// the host's `detailItem` binding directly — every surface that went through
/// the bus (Library, Upcoming, chat cards) was dead.
///
/// It is the third feature to lose messages this way (the quiz deck and
/// `ConfirmRequest` came first), and all three were fixed the same way: the
/// state lives on something with the app's lifetime and surfaces *read* it.
/// A request carries a fresh `id`, so hosts fire on the id changing — opening
/// the same title twice is two requests, and a host that mounts later does not
/// replay an old one.
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
    /// Runs `perform` whenever some surface asks for a detail view. Hosts that
    /// are off screen guard on their own "am I the visible tab" flag.
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


/// Same story as `DetailRouter`, for the "add this to an arr" panel.
///
/// The Quiz's "More" button posted `AppMessages.OpenSearchAdd` and nothing
/// happened — a quiz card is usually NOT in the library, so that button took
/// the add-panel branch, which was still on the bus that loses messages. The
/// in-library branch had already been moved and worked.
public final class SearchAddRouter: ObservableObject {
    public static let shared = SearchAddRouter()

    /// Where the request came from, which is what Back has to honour: a chat
    /// tap returns to chat, a quiz card returns to the deck (still parked
    /// under the panel), a search hit stays where it was.
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
    /// Runs `perform` whenever some surface asks for the add panel.
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
