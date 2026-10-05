import SwiftUI

/// A one-line note on how something the user just started turned out.
struct Toast: Identifiable {
    enum Tone { case success, neutral, failure }

    struct Action {
        let label: LocalizedStringKey
        let perform: @MainActor () -> Void
    }

    let id = UUID()
    let tone: Tone
    let symbol: String
    let title: LocalizedStringKey
    /// Verbatim: a title, or the server's own words.
    var detail: String?
    var action: Action?

    var lifetime: Duration {
        switch tone {
        case .success: .seconds(2.5)
        case .neutral: .seconds(3)
        case .failure: .seconds(4)
        }
    }

    static func failure(_ title: LocalizedStringKey, error: Error, retry: (@MainActor () -> Void)? = nil) -> Toast {
        Toast(tone: .failure, symbol: "exclamationmark.triangle.fill", title: title,
              detail: error.localizedDescription,
              action: retry.map { Action(label: "common.retry.button", perform: $0) })
    }
}

/// State, like `ConfirmCenter`: whoever finishes the work posts here, the root surface draws it.
/// One at a time; a new toast replaces the one showing.
@Observable
final class ToastCenter {
    static let shared = ToastCenter()

    private(set) var current: Toast?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var remaining: Duration = .zero
    @ObservationIgnored private var armedAt: ContinuousClock.Instant?

    func show(_ toast: Toast) {
        current = toast
        arm(toast.lifetime)
    }

    func dismiss() {
        expiry?.cancel()
        armedAt = nil
        current = nil
    }

    /// Hover holds the toast; leaving gives back what was left, never less than a beat to read it.
    func hold() {
        guard let armedAt else { return }
        expiry?.cancel()
        remaining -= ContinuousClock.now - armedAt
        self.armedAt = nil
    }

    func release() {
        guard current != nil, armedAt == nil else { return }
        arm(max(remaining, .seconds(1.2)))
    }

    private func arm(_ duration: Duration) {
        expiry?.cancel()
        remaining = duration
        armedAt = .now
        let id = current?.id
        expiry = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, current?.id == id else { return }
            armedAt = nil
            current = nil
        }
    }
}
