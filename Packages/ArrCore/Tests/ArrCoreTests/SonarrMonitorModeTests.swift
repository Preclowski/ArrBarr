import Testing
@testable import ArrCore

@Suite("SonarrMonitorMode API mapping")
struct SonarrMonitorModeTests {
    @Test("Season modes map to Sonarr's camelCase MonitorTypes")
    func seasonModes() {
        #expect(SonarrMonitorMode.first.apiValue == "firstSeason")
        #expect(SonarrMonitorMode.latest.apiValue == "latestSeason")
    }

    @Test("Other modes map 1:1 to their raw value")
    func passthroughModes() {
        for mode in [SonarrMonitorMode.all, .future, .missing, .existing, .none] {
            #expect(mode.apiValue == mode.rawValue)
        }
    }
}
