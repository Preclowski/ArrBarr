import Testing
import Foundation
@testable import ArrCore

@Suite("MCPTypes")
struct MCPTypesTests {
    @Test("JSONValue round-trips nested object")
    func jsonValueRoundTrip() throws {
        let original: JSONValue = .object([
            "n": .number(42),
            "s": .string("hi"),
            "arr": .array([.bool(true), .null]),
        ])
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(back == original)
    }
}
