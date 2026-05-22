import Foundation

public enum ChatProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case foundationModels = "fm"
    case openai = "openai"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .foundationModels: return "Apple Intelligence"
        case .openai: return "OpenAI-compatible API"
        }
    }
}

public struct OpenAIConfig: Codable, Equatable, Sendable {
    public var baseURL: String
    public var apiKey: String
    public var model: String

    public init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    public var isConfigured: Bool {
        guard !apiKey.isEmpty else { return false }
        guard let url = URL(string: baseURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return false }
        return !model.isEmpty
    }

    public static let empty = OpenAIConfig(baseURL: "", apiKey: "", model: "")
}
