import Foundation
import Testing
@testable import ArrCore

@Suite("Pool-then-draw deck randomness")
struct PoolThenDrawTests {

    @Test("Every drawn card comes from the top pool, and the deck size holds")
    func drawsFromPoolOnly() {
        let ranked = Array(1...200)
        let deck = LocalToolBackend.poolThenDraw(ranked, pool: 60, deck: 20)
        #expect(deck.count == 20)
        #expect(deck.allSatisfy { $0 <= 60 }, "a draw outside the pool leaks low-ranked cards in")
        #expect(Set(deck).count == 20, "the draw must not repeat a card")
    }

    @Test("Short inputs survive: pool and deck clamp to what exists")
    func shortInputs() {
        #expect(LocalToolBackend.poolThenDraw([1, 2, 3], pool: 60, deck: 20).sorted() == [1, 2, 3])
        #expect(LocalToolBackend.poolThenDraw([Int](), pool: 60, deck: 20).isEmpty)
    }
}
