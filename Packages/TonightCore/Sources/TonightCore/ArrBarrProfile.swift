import Foundation
import ArrCore

/// ArrBarr's configuration, decoded by ArrCore instead of by hand.
///
/// TonightBarr is the window-shaped face of the same app family, so it must not
/// keep a second idea of how a Radarr is stored. It used to parse
/// `group.pl.incred.ArrBarr.plist` itself — a private `Config: Decodable` per
/// service, a hardcoded `ArrBarr.config.<name>` key and a hardcoded
/// `ArrBarr.secret.<name>.apiKey` next to it. That is ArrCore's storage format,
/// and a second copy of it breaks the day ArrCore changes a key. Now the plist
/// is read as a plain dictionary and handed to `ConfigStore`'s own decoders and
/// `SecretKey.plaintextDefaultsKey`; nothing here knows a key name.
///
/// **The snapshot lives in memory and only in memory.** These values include
/// every API key ArrBarr holds. Writing them into a `UserDefaults` suite would
/// persist a second plaintext copy that outlives uninstalling ArrBarr;
/// `register(defaults:)` would instead put them in the process-wide
/// registration domain, where every other `UserDefaults` in the process would
/// read them back. A dictionary behind a lock is neither.
///
/// **Read-only, and it has to be.** A shared, writable config would need an App
/// Group container, which on macOS requires a team-signed build; ArrBarr ships
/// ad-hoc from the OSS pipeline (`CODE_SIGN_IDENTITY = "-"`, empty team), and
/// granting it that entitlement would MOVE every existing user's settings. So
/// nothing here writes back to ArrBarr; TonightBarr's own preferences stay in
/// `TonightConfig`.
///
/// Every member is `nonisolated`: `ExternalLibraryStore` and MediaKit's
/// providers ask "is this configured?" from their own executors, and hopping to
/// the main actor from there traps.
public enum ArrBarrProfile {
    /// ArrBarr's defaults, inside its sandbox container. Ad-hoc builds keep
    /// both config blobs and secrets here in plain `UserDefaults` — a
    /// team-signed build puts the secrets in the Keychain instead, where this
    /// cannot (and should not) reach them.
    public static let defaultsURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Library/Containers/pl.incred.ArrBarr/Data/Library/Preferences/group.pl.incred.ArrBarr.plist")

    /// The snapshot. Lock-guarded rather than actor-isolated so the reads below
    /// stay synchronous — MediaKit asks whether a provider is configured from
    /// inside its planner, which cannot await.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: [String: Any] = read(from: defaultsURL) ?? [:]

    /// Re-read ArrBarr's defaults. Called when the window comes forward: the
    /// user may have just added a server over in ArrBarr, and a stale snapshot
    /// would keep answering "not configured" until relaunch.
    @discardableResult
    public static func refresh() -> Bool {
        guard let values = read(from: defaultsURL) else { return false }
        lock.lock(); storage = values; lock.unlock()
        return true
    }

    private static func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// One arr's configuration, or nil when it isn't set up. The API key comes
    /// from the secret entry beside the config blob, exactly as `ConfigStore`
    /// assembles it — the blob itself carries a blank one.
    public static func serviceConfig(_ kind: ServiceKind, in values: [String: Any]? = nil) -> ServiceConfig? {
        let values = values ?? snapshot()
        var config = ConfigStore.decodeServiceConfig(kind, from: values)
        config.apiKey = secret(.apiKey(for: kind), in: values) ?? config.apiKey
        guard config.isConfigured, !config.apiKey.isEmpty else { return nil }
        return config
    }

    /// The same answer in the shape the arr sweeps want: a base URL that
    /// parsed, and a key that isn't blank.
    public static func service(_ kind: ServiceKind, in values: [String: Any]? = nil) -> (baseURL: URL, apiKey: String)? {
        guard let config = serviceConfig(kind, in: values),
              let url = URL(string: config.baseURL) else { return nil }
        return (url, config.apiKey)
    }

    /// The one media server ArrBarr is pointed at, token included.
    public static func mediaServerConfig(in values: [String: Any]? = nil) -> MediaServerConfig? {
        let values = values ?? snapshot()
        var config = ConfigStore.decodeMediaServerConfig(from: values)
        config.token = secret(.mediaServerToken, in: values) ?? config.token
        return config.isConfigured ? config : nil
    }

    /// ArrBarr's TMDB key, when it has one. TonightBarr keeps its own in
    /// `TonightConfig` and only falls back to this.
    public static func tmdbAPIKey(in values: [String: Any]? = nil) -> String? {
        secret(.tmdbKey, in: values ?? snapshot())
    }

    /// True when ArrBarr has anything TonightBarr can use. Not an error state:
    /// TonightBarr runs on its own TMDB key with no ArrBarr at all.
    public static var isAvailable: Bool {
        let values = snapshot()
        return mediaServerConfig(in: values) != nil
            || service(.radarr, in: values) != nil
            || service(.sonarr, in: values) != nil
    }

    private static func secret(_ key: SecretKey, in values: [String: Any]) -> String? {
        guard let value = values[key.plaintextDefaultsKey] as? String, !value.isEmpty
        else { return nil }
        return value
    }

    /// Every `ArrBarr.*` entry in the plist. Returns nil when the file is
    /// absent or holds none of them, which is how "ArrBarr isn't installed" is
    /// told apart from "ArrBarr is installed and empty".
    static func read(from source: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: source),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any]
        else { return nil }
        let values = dict.filter { $0.key.hasPrefix("ArrBarr.") }
        return values.isEmpty ? nil : values
    }
}
