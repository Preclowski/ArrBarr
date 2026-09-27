import Foundation

extension ConfigStore {
    /// The data-protection Keychain when the signature provisions the access group
    /// (silent probe); ad-hoc builds fall back to UserDefaults, since the file Keychain would prompt on every rebuild.
    nonisolated static func makeDefaultSecretStore(defaults: UserDefaults) -> SecretStore {
        // The Keychain is process-wide, so demo needs its own suite-backed store
        // or demo edits would overwrite (and blank) the real profile's secrets.
        if DemoMode.isActive { return UserDefaultsSecretStore(defaults: defaults) }
        return AppCapabilities.keychainSharingAvailable
            ? KeychainSecretStore()
            : UserDefaultsSecretStore(defaults: defaults)
    }

    /// Cannot prompt: an unentitled read just fails and leaves the flag for the next launch.
    nonisolated static func recoverSecretsFromKeychainIfNeeded(defaults: UserDefaults, secrets: SecretStore) {
        guard defaults.bool(forKey: secretsMigratedKey) else { return }
        let keychain = KeychainSecretStore()
        var recoveredAny = false
        func move(_ key: SecretKey) {
            if let v = keychain.read(key), !v.isEmpty {
                secrets.set(v, for: key)
                keychain.delete(key)
                recoveredAny = true
            }
        }
        for kind in ServiceKind.allCases {
            move(.apiKey(for: kind))
            move(.password(for: kind))
        }
        move(.openAIKey)
        move(.tmdbKey)
        move(.mediaServerToken)
        if recoveredAny { defaults.set(false, forKey: secretsMigratedKey) }
    }

    // MARK: - One-shot migration of plaintext secrets into the SecretStore

    nonisolated static func migrateSecretsToKeychain(defaults: UserDefaults, secrets: SecretStore) {
        guard !defaults.bool(forKey: secretsMigratedKey) else { return }
        var allVerified = true

        /// A failed read-back keeps the plaintext copy and marks the migration incomplete.
        func store(_ value: String, _ key: SecretKey) -> Bool {
            guard !value.isEmpty else { return true }
            secrets.set(value, for: key)
            if secrets.read(key) == value { return true }
            allVerified = false
            return false
        }

        for kind in ServiceKind.allCases {
            guard let data = defaults.data(forKey: key(kind)),
                  var cfg = try? JSONDecoder().decode(ServiceConfig.self, from: data)
            else { continue }
            var changed = false
            if !cfg.apiKey.isEmpty, store(cfg.apiKey, .apiKey(for: kind)) {
                cfg.apiKey = ""; changed = true
            }
            if !cfg.password.isEmpty, store(cfg.password, .password(for: kind)) {
                cfg.password = ""; changed = true
            }
            if changed, let updated = try? JSONEncoder().encode(cfg) {
                defaults.set(updated, forKey: key(kind))
            }
        }

        if let data = defaults.data(forKey: openaiConfigKey),
           var cfg = try? JSONDecoder().decode(OpenAIConfig.self, from: data),
           !cfg.apiKey.isEmpty, store(cfg.apiKey, .openAIKey) {
            cfg.apiKey = ""
            if let updated = try? JSONEncoder().encode(cfg) {
                defaults.set(updated, forKey: openaiConfigKey)
            }
        }

        if let tmdb = defaults.string(forKey: tmdbApiKeyKey), !tmdb.isEmpty,
           store(tmdb, .tmdbKey) {
            defaults.removeObject(forKey: tmdbApiKeyKey)
        }

        if let data = defaults.data(forKey: mediaServerKey),
           var cfg = try? JSONDecoder().decode(MediaServerConfig.self, from: data),
           !cfg.token.isEmpty, store(cfg.token, .mediaServerToken) {
            cfg.token = ""
            if let updated = try? JSONEncoder().encode(cfg) {
                defaults.set(updated, forKey: mediaServerKey)
            }
        }

        if allVerified { defaults.set(true, forKey: secretsMigratedKey) }
    }

    /// Not flag-guarded: idempotent and free in steady state, so it self-heals a failed write.
    /// Also sweeps `.standard`, where `MCPTokenStore` keeps its token, except in demo mode.
    nonisolated static func migratePlaintextSecretsIntoKeychain(defaults: UserDefaults,
                                                               keychain: SecretStore) {
        var suites: [UserDefaults] = [defaults]
        if !DemoMode.isActive, defaults !== UserDefaults.standard { suites.append(.standard) }

        func lift(_ key: SecretKey, from plaintext: UserDefaultsSecretStore) {
            guard let value = plaintext.read(key) else { return }
        // Keychain already authoritative: the plaintext copy is a stale duplicate.
            if let existing = keychain.read(key), !existing.isEmpty {
                plaintext.delete(key)
                return
            }
            keychain.set(value, for: key)
            guard keychain.read(key) == value else { return }
            plaintext.delete(key)
        }

        for suite in suites {
            let plaintext = UserDefaultsSecretStore(defaults: suite)
            for kind in ServiceKind.allCases {
                lift(.apiKey(for: kind), from: plaintext)
                lift(.password(for: kind), from: plaintext)
            }
            lift(.openAIKey, from: plaintext)
            lift(.tmdbKey, from: plaintext)
            lift(.mediaServerToken, from: plaintext)
            lift(.mcpBearer, from: plaintext)
        }
    }
}
