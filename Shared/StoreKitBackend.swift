#if APPSTORE
import Foundation
import StoreKit
import ArrCore
#if canImport(AppKit)
import AppKit
#endif

/// In the app targets so it compiles only with `APPSTORE`. Main-actor isolated because
/// `PurchaseBackend` is read synchronously by `StoreManager`, so an actor can't conform.
@MainActor
final class StoreKitBackend: @MainActor PurchaseBackend {
    /// Still "pro" though the tier is called Control: a product ID is immutable in
    /// App Store Connect, and changing it would orphan existing purchases.
    static let productID = "app.arrbarr.pro"

    private(set) var isEntitled: Bool = false
    private(set) var displayPrice: String?
    var onEntitlementChange: ((Bool) -> Void)?

    private var product: Product?
    private var updatesTask: Task<Void, Never>?

    func start() async {
        await refreshProduct()
        await refreshEntitlement()
        // Detached: the sequence never ends and mustn't be tied to the caller's task.
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
            // Without the 15.2 API the windowless form presents from the key window.
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
    private static func anchorWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible }
    }
    #endif
}
#endif
