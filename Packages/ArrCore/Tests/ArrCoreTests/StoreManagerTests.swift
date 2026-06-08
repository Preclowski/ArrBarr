import Testing
@testable import ArrCore

/// A controllable backend so the gate logic is testable without StoreKit.
final class FakeBackend: PurchaseBackend {
    var isEntitled: Bool
    var displayPrice: String? = "$9.99"
    var onEntitlementChange: ((Bool) -> Void)?
    var purchaseResult = true
    init(entitled: Bool) { self.isEntitled = entitled }
    func start() async {}
    func purchase() async -> Bool {
        if purchaseResult { isEntitled = true; onEntitlementChange?(true) }
        return purchaseResult
    }
    func restore() async -> Bool {
        if purchaseResult { isEntitled = true; onEntitlementChange?(true) }
        return purchaseResult
    }
}

@Suite("StoreManager gate logic")
@MainActor
struct StoreManagerTests {
    @Test("No backend injected → fully unlocked (OSS build behaviour)")
    func defaultsUnlocked() {
        let m = StoreManager(forTesting: true)
        #expect(m.isPro == true)
        #expect(m.requirePro(.chat) == true)
        #expect(m.gatedFeature == nil)
    }

    @Test("Entitled backend → requirePro passes, no paywall")
    func entitledPasses() {
        let m = StoreManager(forTesting: true)
        m.use(FakeBackend(entitled: true))
        #expect(m.isPro == true)
        #expect(m.requirePro(.queueAction) == true)
        #expect(m.gatedFeature == nil)
    }

    @Test("Unentitled backend → requirePro fails and sets gatedFeature")
    func unentitledGates() {
        let m = StoreManager(forTesting: true)
        m.use(FakeBackend(entitled: false))
        #expect(m.isPro == false)
        #expect(m.requirePro(.addTitle) == false)
        #expect(m.gatedFeature == .addTitle)
    }

    @Test("Successful purchase unlocks and clears the paywall")
    func purchaseUnlocks() async {
        let m = StoreManager(forTesting: true)
        m.use(FakeBackend(entitled: false))
        _ = m.requirePro(.chat)
        #expect(m.gatedFeature == .chat)
        await m.purchase()
        #expect(m.isPro == true)
        #expect(m.gatedFeature == nil)
    }
}
