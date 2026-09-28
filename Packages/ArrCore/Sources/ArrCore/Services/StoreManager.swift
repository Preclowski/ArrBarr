import Foundation
import Combine

/// Keeps StoreKit out of ArrCore: `StoreKitBackend` lives in the app targets behind
/// `#if APPSTORE` and is injected via `StoreManager.use(_:)`.
public protocol PurchaseBackend: AnyObject {
    var isEntitled: Bool { get }
    var displayPrice: String? { get }
    /// Called on the initial load and on every Transaction.updates change.
    var onEntitlementChange: ((Bool) -> Void)? { get set }
    func start() async
    func purchase() async -> Bool
    func restore() async -> Bool
}

/// Unlocked when no backend is injected, so Debug and OSS builds carry no payment code.
public final class StoreManager: ObservableObject {
    public static let shared = StoreManager()

    @Published private var entitled: Bool = true

    /// Demo mode is always unlocked so it can showcase every gated feature.
    public var isPro: Bool { DemoMode.isActive || entitled }

    /// Non-nil drives the paywall; the feature just tried, for the contextual headline.
    @Published public var gatedFeature: ProFeature?
    @Published public private(set) var displayPrice: String?

    private var backend: PurchaseBackend?

    public init(forTesting: Bool = false) {}

    // periphery:ignore
    public func use(_ backend: PurchaseBackend) {
        self.backend = backend
        backend.onEntitlementChange = { [weak self] entitled in
            Task { @MainActor in self?.entitled = entitled }
        }
        entitled = backend.isEntitled
        Task {
            await backend.start()
            self.entitled = backend.isEntitled
            self.displayPrice = backend.displayPrice
        }
    }

    /// Returns true to proceed; false sets `gatedFeature` (→ paywall).
    @discardableResult
    public func requirePro(_ feature: ProFeature) -> Bool {
        if isPro { return true }
        gatedFeature = feature
        return false
    }

    public func gate(_ feature: ProFeature) { _ = requirePro(feature) }

    public func dismissPaywall() { gatedFeature = nil }

    public func purchase() async {
        guard let backend else { return }
        if await backend.purchase() {
            entitled = backend.isEntitled
            if isPro { gatedFeature = nil }
        }
    }

    public func restore() async {
        guard let backend else { return }
        if await backend.restore() {
            entitled = backend.isEntitled
            if isPro { gatedFeature = nil }
        }
    }
}
