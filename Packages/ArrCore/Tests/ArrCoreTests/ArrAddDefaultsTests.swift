import Testing
import Foundation
@testable import ArrCore

@Suite("ArrAddDefaults")
struct ArrAddDefaultsTests {
    @Test("A saved option the arr still offers wins")
    func savedWins() {
        #expect(ArrAddDefaults.pick(7, among: [1, 7, 9]) == 7)
    }

    @Test("Unset or stale falls back to the arr's first option")
    func fallsBackToFirst() {
        #expect(ArrAddDefaults.pick(nil as Int?, among: [1, 7]) == 1)
        #expect(ArrAddDefaults.pick(42, among: [1, 7]) == 1)
    }

    @Test("Nothing to pick from stays nil")
    func emptyOptions() {
        #expect(ArrAddDefaults.pick(7, among: []) == nil)
    }

    private func server(_ url: String) -> ServiceConfig {
        ServiceConfig(enabled: true, baseURL: url, apiKey: "key", username: "", password: "")
    }

    private var picked: ArrAddDefaults {
        var defaults = ArrAddDefaults()
        defaults.qualityProfileId = 4
        defaults.rootFolder = "/tv"
        defaults.seriesMonitor = .latest
        defaults.seriesType = .anime
        return defaults
    }

    @Test("Defaults persist per arr, each under its own key")
    @MainActor func roundTrip() {
        let defaults = TestDefaults.suite("test.addDefaults.\(UUID().uuidString)")
        let secrets = InMemorySecretStore()
        let store = ConfigStore(defaults: defaults, secrets: secrets)
        store.sonarr = server("http://a:8989")
        #expect(store.addDefaults.isEmpty)

        store.setAddDefaults(picked, for: .sonarr)

        #expect(defaults.data(forKey: "ArrBarr.addDefaults.sonarr") != nil)
        #expect(defaults.data(forKey: "ArrBarr.addDefaults.radarr") == nil)
        let reloaded = ConfigStore(defaults: defaults, secrets: secrets).addDefaults(for: .sonarr)
        #expect(reloaded.qualityProfileId == 4)
        #expect(reloaded.rootFolder == "/tv")
        #expect(reloaded.seriesMonitor == .latest)
        #expect(reloaded.seriesType == .anime)
    }

    @Test("Another server's ids are dropped and the modes stay")
    @MainActor func anotherServer() {
        let store = ConfigStore(defaults: TestDefaults.suite("test.addDefaults.\(UUID().uuidString)"),
                                secrets: InMemorySecretStore())
        store.sonarr = server("http://a:8989")
        store.setAddDefaults(picked, for: .sonarr)

        store.sonarr = server("http://b:8989")
        let onB = store.addDefaults(for: .sonarr)
        #expect(onB.qualityProfileId == nil)
        #expect(onB.rootFolder == nil)
        #expect(onB.seriesMonitor == .latest)

        store.sonarr = server("http://a:8989")
        #expect(store.addDefaults(for: .sonarr).qualityProfileId == 4)
    }

    @Test("An unknown value costs only its own field")
    func tolerantDecoding() throws {
        let json = #"{"qualityProfileId":4,"seriesMonitor":"fromANewerBuild","somethingNew":1}"#
        let decoded = try JSONDecoder().decode(ArrAddDefaults.self, from: Data(json.utf8))
        #expect(decoded.qualityProfileId == 4)
        #expect(decoded.seriesMonitor == .all)
        #expect(decoded.seriesType == .standard)
    }

    @Test("What was encoded decodes the same")
    func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(picked)
        #expect(try JSONDecoder().decode(ArrAddDefaults.self, from: data) == picked)
    }

    @Test("Every mode has a translation for the locale it is asked in")
    func labelsResolvePerLocale() {
        func keys<T: LocalizedPickerValue & CaseIterable>(_: T.Type) -> [T] { Array(T.allCases) }
        let polish = Locale(identifier: "pl")
        let names = keys(RadarrMonitorMode.self).map { ($0.labelKey, $0.displayName(locale: polish)) }
            + keys(SonarrMonitorMode.self).map { ($0.labelKey, $0.displayName(locale: polish)) }
            + keys(LidarrMonitorMode.self).map { ($0.labelKey, $0.displayName(locale: polish)) }
            + keys(SonarrSeriesType.self).map { ($0.labelKey, $0.displayName(locale: polish)) }
            + keys(RadarrMinimumAvailability.self).map { ($0.labelKey, $0.displayName(locale: polish)) }
        for (key, name) in names { #expect(name != key) }
        #expect(SonarrSeriesType.standard.displayName(locale: polish)
                != SonarrSeriesType.standard.displayName(locale: Locale(identifier: "en")))
    }
}
