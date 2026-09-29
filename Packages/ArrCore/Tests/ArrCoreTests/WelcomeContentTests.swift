import Testing
import Foundation
@testable import ArrCore

@Suite("WelcomeContent decision logic")
struct WelcomeContentDecisionTests {
    @Test("Only a user who never saw the tour gets it, unless forced")
    func decision() {
        #expect(WelcomeContent.decide(seen: nil, forceShow: false))
        #expect(!WelcomeContent.decide(seen: "0.9.0", forceShow: false))
        #expect(!WelcomeContent.decide(seen: WelcomeContent.currentVersion, forceShow: false))
        #expect(WelcomeContent.decide(seen: WelcomeContent.currentVersion, forceShow: true))
    }

    private func makeDefaults() -> UserDefaults {
        TestDefaults.suite("welcome.\(UUID().uuidString)")
    }

    @Test("UserDefaults flag triggers force-show")
    func defaultsFlagTriggers() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: WelcomeContent.forceShowDefaultsKey)
        #expect(WelcomeContent.shouldForceShow(defaults: defaults))
    }

    @Test("shouldShow consumes the force flag so reopens don't loop")
    func shouldShowConsumesFlag() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: WelcomeContent.forceShowDefaultsKey)
        #expect(WelcomeContent.shouldShow(seen: "any", defaults: defaults))
        #expect(!defaults.bool(forKey: WelcomeContent.forceShowDefaultsKey))
        #expect(!WelcomeContent.shouldShow(seen: "any", defaults: defaults))
    }

    @Test("First-run pages list is non-empty")
    func firstRunPagesNonEmpty() {
        #expect(!WelcomeContent.firstRunPages.isEmpty)
    }
}
