import Foundation

public struct Credentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Material: Sendable {
        case apiKey(String)
        case bearer(String)
        case userPassword(user: String, password: String)
        case token(String)
        case none
    }

    public let baseURL: URL
    public let material: Material
    /// Rotated by the provider whenever the secret is written; drives the fingerprint.
    public let generation: String

    public init(baseURL: URL, material: Material, generation: String) {
        self.baseURL = baseURL
        self.material = material
        self.generation = generation
    }

    public var description: String { "Credentials(•••)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// Asked per request; MediaKit never stores a secret.
public protocol CredentialProvider: Sendable {
    func credentials(for instance: InstanceID) async -> Credentials?
}

public struct StaticCredentials: CredentialProvider {
    private let table: [InstanceID: Credentials]
    public init(_ table: [InstanceID: Credentials]) { self.table = table }
    public func credentials(for instance: InstanceID) async -> Credentials? { table[instance] }
}

/// Base URL + credential generation. Never the secret, never a hash of it.
public struct Fingerprint: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(baseURL: URL, generation: String) {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        rawValue = "\(components.string ?? "")|\(generation)"
    }

    public var description: String { rawValue }
}
