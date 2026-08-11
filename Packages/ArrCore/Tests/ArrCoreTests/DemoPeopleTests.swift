import Testing
@testable import ArrCore

@Suite("Demo people fixtures")
struct DemoPeopleTests {
    @Test("searchPeople matches by substring, case-insensitive")
    func searchMatches() {
        #expect(DemoMocks.searchPeople(query: "derek").map(\.name) == ["Derek de Lint"])
        #expect(DemoMocks.searchPeople(query: "RICH").count == 1)
        #expect(DemoMocks.searchPeople(query: "").isEmpty)
    }

    @Test("every demo person has details and at least one filmography row")
    func fixturesComplete() {
        for person in DemoMocks.DemoPerson.allCases {
            let id = person.rawValue
            #expect(DemoMocks.personDetails(personId: id) != nil)
            let rows = DemoMocks.personMovies(personId: id) + DemoMocks.personSeries(personId: id)
            #expect(!rows.isEmpty)
        }
    }

    @Test("owned fixtures point at demo library entity ids")
    func ownedRowsTagged() {
        let tears = DemoMocks.personMovies(personId: DemoMocks.DemoPerson.derekDeLint.rawValue)
        #expect(tears.first { $0.title == "Tears of Steel" }?.inLibraryArrId == 203)
        #expect(tears.first { $0.title == "Elephants Dream" }?.inLibraryArrId == nil)
        let pioneer = DemoMocks.personSeries(personId: DemoMocks.DemoPerson.jamesRich.rawValue)
        #expect(pioneer.first?.inLibraryArrId == 101)
    }
}
