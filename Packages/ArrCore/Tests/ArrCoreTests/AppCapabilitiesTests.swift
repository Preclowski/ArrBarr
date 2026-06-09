import Testing
import Foundation
@testable import ArrCore

@Suite("AppCapabilities", .serialized)
struct AppCapabilitiesSuite {

    @Test("isAppStore defaults false and configure flips it")
    func configureFlipsFlag() {
        let original = AppCapabilities.isAppStore
        defer { AppCapabilities.configure(isAppStore: original) }
        AppCapabilities.configure(isAppStore: false)
        #expect(AppCapabilities.isAppStore == false)
        AppCapabilities.configure(isAppStore: true)
        #expect(AppCapabilities.isAppStore == true)
    }

    @Test("keychainSharingAvailable is false when not an App Store build")
    func probeFalseWhenNotAppStore() {
        let original = AppCapabilities.isAppStore
        defer { AppCapabilities.configure(isAppStore: original); AppCapabilities.resetProbeForTesting() }
        AppCapabilities.configure(isAppStore: false)
        AppCapabilities.resetProbeForTesting()
        #expect(AppCapabilities.keychainSharingAvailable == false)
    }

    @Test("keychainSharingAvailable honors an injected probe override")
    func probeOverride() {
        let original = AppCapabilities.isAppStore
        defer {
            AppCapabilities.configure(isAppStore: original)
            AppCapabilities.keychainProbeOverride = nil
            AppCapabilities.resetProbeForTesting()
        }
        AppCapabilities.configure(isAppStore: true)
        AppCapabilities.keychainProbeOverride = { true }
        AppCapabilities.resetProbeForTesting()
        #expect(AppCapabilities.keychainSharingAvailable == true)
        AppCapabilities.keychainProbeOverride = { false }
        AppCapabilities.resetProbeForTesting()
        #expect(AppCapabilities.keychainSharingAvailable == false)
    }
}
