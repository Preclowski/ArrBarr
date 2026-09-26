import Testing
import Foundation
@testable import ArrCore

@Suite("SuggestionCarousel")
@MainActor
struct SuggestionCarouselTests {

    private let pool = ["a", "b", "c", "d", "e", "f", "g"]

    private func carousel(window: Int) -> SuggestionCarousel {
        SuggestionCarousel(pool: pool, window: window, shuffled: false)
    }

    @Test("The window is a prefix of the pool")
    func windowIsAPrefix() {
        #expect(carousel(window: 4).visible == ["a", "b", "c", "d"])
    }

    @Test("A window wider than the pool takes what there is")
    func windowWiderThanPool() {
        let c = SuggestionCarousel(pool: ["a", "b"], window: 5, shuffled: false)
        #expect(c.visible == ["a", "b"])
    }

    @Test("Each advance changes one slot, walking down the list")
    func advanceWalksDownTheList() {
        let c = carousel(window: 4)
        c.advance(within: 4)
        #expect(c.visible[0] != "a", "the first slot changed")
        #expect(Array(c.visible[1...]) == ["b", "c", "d"], "and only the first")
        c.advance(within: 4)
        #expect(c.visible[1] != "b")
        #expect(c.visible[2...].elementsEqual(["c", "d"]))
    }

    @Test("A suggestion already on screen is never dealt again")
    func neverRepeatsWhatIsOnScreen() {
        let c = carousel(window: 4)
        for _ in 0..<20 {
            c.advance(within: 4)
            #expect(Set(c.visible).count == c.visible.count, "duplicate on screen: \(c.visible)")
        }
    }

    @Test("Rotation stays inside the rows the layout actually placed")
    func staysWithinTheDisplayedRows() {
        // The regression this guards: `ViewThatFits` drops rows on a short
        // panel, and a rotation keyed on the full window spent its beats
        // changing rows nobody could see — the surface looked frozen.
        let c = carousel(window: 4)
        let tailBefore = Array(c.visible[2...])
        for _ in 0..<10 { c.advance(within: 2) }
        #expect(Array(c.visible[2...]) == tailBefore)
    }

    @Test("Nothing to place, nothing to do")
    func displayedZeroIsANoOp() {
        let c = carousel(window: 4)
        let before = c.visible
        c.advance(within: 0)
        #expect(c.visible == before)
    }

    @Test("A pool with no spare suggestions leaves the window alone")
    func exhaustedPoolKeepsTheWindow() {
        let c = SuggestionCarousel(pool: ["a", "b"], window: 2, shuffled: false)
        c.advance(within: 2)
        #expect(c.visible == ["a", "b"])
    }
}
