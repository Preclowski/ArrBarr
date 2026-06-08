import Testing
import Foundation
@testable import ArrCore

@Suite("Widget deep link parsing")
struct WidgetDeepLinkTests {
    @Test("arrbarr://library parses to .library")
    func library() {
        #expect(WidgetDeepLink(url: URL(string: "arrbarr://library")!) == .library)
    }

    @Test("Unknown host parses to nil")
    func unknown() {
        #expect(WidgetDeepLink(url: URL(string: "arrbarr://nope")!) == nil)
    }

    @Test("Wrong scheme parses to nil")
    func wrongScheme() {
        #expect(WidgetDeepLink(url: URL(string: "https://library")!) == nil)
    }
}
