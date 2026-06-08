import Foundation
import Combine

/// Abstracts the purchase/entitlement source so ArrCore carries NO StoreKit
/// code. The real implementation (`StoreKitBackend`) lives in the app targets
/// behind `#if APPSTORE` and is injected via `StoreManager.use(_:)`.
public protocol PurchaseBackend: AnyObject {
    var isEntitled: Bool { get }
    var displayPrice: String? { get }
    /// Called whenever entitlement changes (initial load, Transaction.updates).
    var onEntitlementChange: ((Bool) -> Void)? { get set }
    /// Load product metadata + current entitlements + start the update listener.
    func start() async
    /// Returns true if the user is now entitled.
    func purchase() async -> Bool
    func restore() async -> Bool
}

/// Single source of truth for Pro status + paywall presentation.
///
/// Defaults to UNLOCKED (`isPro == true`) when no backend is injected, so
/// Debug builds and the GitHub/OSS distribution are fully functional with no
/// payment code present.
@MainActor
public final class StoreManager: ObservableObject {
    public static let shared = StoreManager()

    /// Real entitlement from the backend (or `true` when no backend is injected
    /// — Debug / OSS builds are fully unlocked).
    @Published private var entitled: Bool = true

    /// Pro status as the UI sees it. Demo mode is always Pro so the preview can
    /// showcase every gated feature (chat, queue actions, add-title) without
    /// hitting the paywall. Outside demo it reflects the real entitlement.
    public var isPro: Bool { DemoMode.isActive || entitled }

    /// Non-nil drives the paywall sheet. The value is the feature the user
    /// just tried to use, for the contextual headline.
    @Published public var gatedFeature: ProFeature?
    @Published public private(set) var displayPrice: String?

    private var backend: PurchaseBackend?

    /// `forTesting` only skips the shared-singleton expectation; behaviour is
    /// identical. Production code uses `.shared`.
    public init(forTesting: Bool = false) {}

    /// Inject the concrete backend (called once at app launch under #if APPSTORE).
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

    /// Gate check. Returns true to proceed; false sets `gatedFeature` (→ paywall).
    @discardableResult
    public func requirePro(_ feature: ProFeature) -> Bool {
        if isPro { return true }
        gatedFeature = feature
        return false
    }

    /// Convenience for UI tap sites that don't branch on the result.
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
