import Foundation

/// A counter stamped next to every secret write. MediaKit fingerprints an instance by base URL +
/// generation, so a rotated key of the same length still invalidates the cache without any hash of it.
public enum SecretGenerations {
    private static func key(_ secret: SecretKey) -> String { "ArrBarr.secretGeneration.\(secret.account)" }

    public static func generation(for secret: SecretKey, in defaults: UserDefaults) -> String {
        String(defaults.integer(forKey: key(secret)))
    }

    public static func bump(_ secret: SecretKey, in defaults: UserDefaults) {
        defaults.set(defaults.integer(forKey: key(secret)) + 1, forKey: key(secret))
    }
}
