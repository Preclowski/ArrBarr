import Foundation

public struct MCPConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var baseURL: String
    public var bearerToken: String

    public init(enabled: Bool, baseURL: String, bearerToken: String) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.bearerToken = bearerToken
    }

    public var isConfigured: Bool {
        guard let url = URL(string: baseURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return false }
        return true
    }

    public static let empty = MCPConfig(enabled: false, baseURL: "", bearerToken: "")
}
