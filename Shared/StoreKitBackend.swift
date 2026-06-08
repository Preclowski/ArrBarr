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
final class StoreKitBackend: PurchaseBackend, @unchecked Sendable {
    static let productID = "app.arrbarr.pro"

    private(set) var isEntitled: Bool = false
    private(set) var displayPrice: String?
    var onEntitlementChange: ((Bool) -> Void)?

    private var product: Product?
    private var updatesTask: Task<Void, Never>?

    func start() async {
        await refreshProduct()
        await refreshEntitlement()
        // Listen for renewals/refunds/cross-device unlocks.
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
            if #available(macOS 15.2, *), let window = await Self.anchorWindow() {
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
    /// taps Buy in the paywall window, that window is key.
    @MainActor
    private static func anchorWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible }
    }
    #endif
}
#endif
