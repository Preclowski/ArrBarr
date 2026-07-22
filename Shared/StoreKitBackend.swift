#if APPSTORE
import Foundation
import StoreKit
import ArrCore
#if canImport(AppKit)
import AppKit
#endif

/// Concrete StoreKit 2 backend. Lives in the app targets (not ArrCore) so it is
/// compiled ONLY when the `APPSTORE` flag is set. Injected into
/// `StoreManager.shared` at launch.
///
/// Main-actor isolated, conformance included. `PurchaseBackend` hands
/// `isEntitled` / `displayPrice` to `StoreManager` (itself `@MainActor`) as
/// plain synchronous reads, so an actor can't satisfy it and the only options
/// were hand-synchronising every field or isolating the whole thing. Isolation
/// is what makes the two writers safe: the `Transaction.updates` listener runs
/// detached but hops back in before touching state, and the
/// read-modify-write in `refreshEntitlement` has no suspension point in it, so
/// two overlapping refreshes can't interleave.
@MainActor
final class StoreKitBackend: @MainActor PurchaseBackend {
    /// The App Store product identifier. It still reads "pro" even though the
    /// tier is called **Control** everywhere the user can see it: a product ID
    /// is immutable once a product exists in App Store Connect, and changing it
    /// would orphan every purchase already made against the old one. Rename the
    /// display name in App Store Connect (and in `ArrBarr.storekit`), never this.
    static let productID = "app.arrbarr.pro"

    private(set) var isEntitled: Bool = false
    private(set) var displayPrice: String?
    var onEntitlementChange: ((Bool) -> Void)?

    private var product: Product?
    private var updatesTask: Task<Void, Never>?

    func start() async {
        await refreshProduct()
        await refreshEntitlement()
        // Listen for renewals/refunds/cross-device unlocks. Detached because
        // the sequence never ends and must not be tied to the caller's task;
        // every state change goes back through the main actor.
        updatesTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let txn) = update {
                    await txn.finish()
                    await self?.refreshEntitlement()
                }
            }
        }
    }

    private func refreshProduct() async {
        product = try? await Product.products(for: [Self.productID]).first
        displayPrice = product?.displayPrice
    }

    private func refreshEntitlement() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let txn) = result,
               txn.productID == Self.productID,
               txn.revocationDate == nil {
                owned = true
            }
        }
        let changed = owned != isEntitled
        isEntitled = owned
        if changed { onEntitlementChange?(owned) }
    }

    func purchase() async -> Bool {
        if product == nil { await refreshProduct() }
        guard let product else { return false }
        do {
            let result: Product.PurchaseResult
            #if os(macOS)
            // Anchor the purchase sheet to our paywall window when the API is
            // available (macOS 15.2+); otherwise fall back to the windowless
            // form, which presents from the key window (our paywall window).
            if #available(macOS 15.2, *), let window = Self.anchorWindow() {
                result = try await product.purchase(confirmIn: window)
            } else {
                result = try await product.purchase()
            }
            #else
            result = try await product.purchase()
            #endif
            switch result {
            case .success(let verification):
                if case .verified(let txn) = verification {
                    await txn.finish()
                    await refreshEntitlement()
                    return isEntitled
                }
                return false
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            return false
        }
    }

    func restore() async -> Bool {
        try? await AppStore.sync()
        await refreshEntitlement()
        return isEntitled
    }

    #if os(macOS)
    /// The window StoreKit should anchor its purchase sheet to. When the user
    /// taps Buy in the paywall window, that window is key. (Main-actor isolated
    /// via the type, which is what AppKit needs here.)
    private static func anchorWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible }
    }
    #endif
}
#endif
