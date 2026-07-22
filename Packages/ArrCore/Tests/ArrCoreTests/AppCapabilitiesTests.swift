import Testing
import Foundation
import Security
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

    /// The probe used to short-circuit to false outside the App Store, which is
    /// what kept OSS builds on plaintext UserDefaults. It now asks the Keychain
    /// in every flavor, so the build flag must not move the answer.
    @Test("keychainSharingAvailable no longer depends on the build flavor")
    func probeIgnoresBuildFlavor() {
        let original = AppCapabilities.isAppStore
        defer { AppCapabilities.configure(isAppStore: original); AppCapabilities.resetProbeForTesting() }

        AppCapabilities.configure(isAppStore: false)
        AppCapabilities.resetProbeForTesting()
        let asOSS = AppCapabilities.keychainSharingAvailable
        AppCapabilities.configure(isAppStore: true)
        AppCapabilities.resetProbeForTesting()
        #expect(AppCapabilities.keychainSharingAvailable == asOSS)
        // …and the real probe still says no here: the test runner is ad-hoc
        // signed, so it cannot carry a provisioned keychain-access-group.
        #expect(asOSS == false)
    }

    /// Where secrets physically live is decided by the signature, not the build
    /// flavor — `KeychainSecretStore.baseQuery` must follow the probe alone.
    /// Applying the group without the entitlement makes every call fail with
    /// `errSecMissingEntitlement`; omitting it when entitled splits the app and
    /// its widget extension across two different Keychain items.
    @Test("The shared access group rides on the probe, not on isAppStore")
    func accessGroupFollowsProbe() {
        let original = AppCapabilities.isAppStore
        defer {
            AppCapabilities.configure(isAppStore: original)
            AppCapabilities.keychainProbeOverride = nil
            AppCapabilities.resetProbeForTesting()
        }
        AppCapabilities.configure(isAppStore: false)   // OSS flavor throughout

        AppCapabilities.keychainProbeOverride = { true }
        AppCapabilities.resetProbeForTesting()
        #expect(KeychainSecretStore.baseQuery(for: .openAIKey)[kSecAttrAccessGroup as String] as? String
                == KeychainSecretStore.accessGroup)

        AppCapabilities.keychainProbeOverride = { false }
        AppCapabilities.resetProbeForTesting()
        #expect(KeychainSecretStore.baseQuery(for: .openAIKey)[kSecAttrAccessGroup as String] == nil)
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
