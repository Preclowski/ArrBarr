import Testing
@testable import ArrCore

/// Every case is a real quiz pick that resolved to the wrong title when the
/// deck took the arr's first lookup hit (2026-09-26 eval).
@Suite("Pick matcher")
struct PickMatcherTests {

    private func c(_ title: String, _ year: Int?, votes: Int? = nil, alt: [String] = []) -> PickMatcher.Candidate {
        .init(titles: [title] + alt, year: year, votes: votes)
    }

    @Test("A longer namesake is not the pick")
    func namesake() {
        #expect(PickMatcher.bestIndex(title: "Burning", year: 2018,
                                      in: [c("Mississippi Burning", 1988), c("Burning", 2018)]) == 1)
        #expect(PickMatcher.bestIndex(title: "The Power", year: 2021,
                                      in: [c("The Power of the Dog", 2021), c("The Power", 2021)]) == 1)
    }

    @Test("A remake loses to the year the model named, disambiguator suffixes and diacritics fold")
    func remakes() {
        #expect(PickMatcher.bestIndex(title: "Bodies", year: 2023,
                                      in: [c("Bodies", 2004), c("Bodies (2023)", 2023)]) == 1)
        #expect(PickMatcher.bestIndex(title: "Shogun", year: 2024,
                                      in: [c("Shogun", 1980), c("Shōgun", 2024)]) == 1)
    }

    @Test("Festival vs release year: the known film wins a one-year tie")
    func offByOne() {
        #expect(PickMatcher.bestIndex(title: "Under the Skin", year: 2013,
                                      in: [c("Under the Skin", 2014, votes: 4_500), c("Under the Skin", 2013, votes: 3)]) == 0)
        #expect(PickMatcher.bestIndex(title: "Resolution", year: 2012, in: [c("Resolution", 2013, votes: 480)]) == 0)
    }

    @Test("Subtitles, possessive prefixes and alternate titles are the same work")
    func sameWorkOtherName() {
        #expect(PickMatcher.bestIndex(title: "Asura", year: 2016,
                                      in: [c("Asura", 2012), c("Asura: The City of Madness", 2016)]) == 1)
        #expect(PickMatcher.bestIndex(title: "Tim Burton's The Nightmare Before Christmas", year: 1993,
                                      in: [c("The Nightmare Before Christmas", 1993)]) == 0)
        #expect(PickMatcher.bestIndex(title: "Vidas Secas", year: 1963,
                                      in: [c("Barren Lives", 1963, alt: ["Vidas Secas"])]) == 0)
        #expect(PickMatcher.bestIndex(title: "Summer of Soul", year: nil,
                                      in: [c("Summer of Soul (...Or, When the Revolution Could Not Be Televised)", 2021)]) == 0)
    }

    @Test("Nothing that is the pick means no match, not the first hit")
    func noMatch() {
        #expect(PickMatcher.bestIndex(title: "Cheers to Reborn", year: 2021, in: [c("The Tower (2021)", 2021)]) == nil)
        #expect(PickMatcher.bestIndex(title: "The Americans", year: 2013, in: [c("The Americans", 1961)]) == nil)
    }

    @Test("Without a year, the better-known of equal titles wins")
    func yearless() {
        #expect(PickMatcher.bestIndex(title: "Who Wants to Be a Millionaire", year: nil,
                                      in: [c("Who Wants to Be a Millionaire (PL)", 1999, votes: 40),
                                           c("Who Wants to Be a Millionaire (US)", 1999, votes: 900)]) == 1)
    }
}
