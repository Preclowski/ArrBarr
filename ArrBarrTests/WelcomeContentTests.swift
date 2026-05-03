import Testing
import Foundation
@testable import ArrBarr

@Suite("WelcomeContent decision logic")
struct WelcomeContentDecisionTests {
    private let item = WelcomeContent.FeatureItem(
        id: "x", symbol: "star", titleKey: "T", bodyKey: "B"
    )

    @Test("First-run users see firstRun variant")
    func firstRun() {
        let v = WelcomeContent.decide(
            seen: nil,
            current: "0.9.0",
            entries: ["0.9.0": [item]],
            forceShow: false
        )
        #expect(v == .firstRun)
    }

    @Test("Same-version users see nothing")
    func sameVersion() {
        let v = WelcomeContent.decide(
            seen: "0.9.0",
            current: "0.9.0",
            entries: ["0.9.0": [item]],
            forceShow: false
        )
        #expect(v == nil)
    }

    @Test("Older-version users with entries see whatsNew")
    func newerVersionWithEntries() {
        let v = WelcomeContent.decide(
            seen: "0.8.8",
            current: "0.9.0",
            entries: ["0.9.0": [item]],
            forceShow: false
        )
        #expect(v == .whatsNew(version: "0.9.0"))
    }

    @Test("Older-version users with no entries see nothing")
    func newerVersionWithoutEntries() {
        let v = WelcomeContent.decide(
            seen: "0.8.8",
            current: "0.9.0",
            entries: [:],
            forceShow: false
        )
        #expect(v == nil)
    }

    @Test("Older-version users with empty entries array see nothing")
    func newerVersionWithEmptyEntries() {
        let v = WelcomeContent.decide(
            seen: "0.8.8",
            current: "0.9.0",
            entries: ["0.9.0": []],
            forceShow: false
        )
        #expect(v == nil)
    }

    @Test("Force-show shows firstRun for never-seen users")
    func forceShowFirstRun() {
        let v = WelcomeContent.decide(
            seen: nil,
            current: "0.9.0",
            entries: [:],
            forceShow: true
        )
        #expect(v == .firstRun)
    }

    @Test("Force-show shows whatsNew for returning users even with no entries")
    func forceShowWhatsNew() {
        let v = WelcomeContent.decide(
            seen: "0.9.0",
            current: "0.9.0",
            entries: [:],
            forceShow: true
        )
        #expect(v == .whatsNew(version: "0.9.0"))
    }
}

@Suite("WelcomeContent force-show flag")
struct WelcomeContentForceShowTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "ArrBarrTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("UserDefaults flag triggers force-show")
    func defaultsFlagTriggers() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        defaults.set(true, forKey: WelcomeContent.forceShowDefaultsKey)
        #expect(WelcomeContent.shouldForceShow(defaults: defaults) == true)
    }

    @Test("UserDefaults flag is one-shot — cleared after consumption")
    func defaultsFlagIsOneShot() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        defaults.set(true, forKey: WelcomeContent.forceShowDefaultsKey)
        WelcomeContent.consumeForceShowFlag(defaults: defaults)
        #expect(WelcomeContent.shouldForceShow(defaults: defaults) == false)
    }

    @Test("variant() consumes the force-show flag so reopens don't loop")
    func variantConsumes() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        defaults.set(true, forKey: WelcomeContent.forceShowDefaultsKey)
        _ = WelcomeContent.variant(seen: "any", defaults: defaults)
        #expect(defaults.bool(forKey: WelcomeContent.forceShowDefaultsKey) == false)
    }

    @Test("variant() without force flag respects normal logic")
    func variantNoForce() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        // seen == currentVersion + no force => nothing
        let v = WelcomeContent.variant(seen: WelcomeContent.currentVersion, defaults: defaults)
        #expect(v == nil)
    }
}

@Suite("WelcomeContent shipped data")
struct WelcomeContentShippedDataTests {
    @Test("currentVersion has a non-empty whatsNew entry list")
    func currentVersionHasEntries() {
        let entries = WelcomeContent.whatsNewEntries[WelcomeContent.currentVersion]
        #expect(entries != nil, "currentVersion \(WelcomeContent.currentVersion) has no whatsNewEntries — bump or remove the version")
        #expect((entries ?? []).isEmpty == false)
    }

    @Test("First-run features list is non-empty")
    func firstRunFeaturesNonEmpty() {
        #expect(WelcomeContent.firstRunFeatures.isEmpty == false)
    }

    @Test("features(for:) returns the right list per variant")
    func featuresForVariant() {
        #expect(WelcomeContent.features(for: .firstRun) == WelcomeContent.firstRunFeatures)
        let whatsNew = WelcomeContent.features(for: .whatsNew(version: WelcomeContent.currentVersion))
        #expect(whatsNew == WelcomeContent.whatsNewEntries[WelcomeContent.currentVersion])
    }
}
