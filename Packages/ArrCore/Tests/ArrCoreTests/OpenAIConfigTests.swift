import Testing
import Foundation
@testable import ArrCore

@Suite("OpenAIConfig")
struct OpenAIConfigTests {
    @Test("empty config is not configured")
    func emptyNotConfigured() {
        #expect(OpenAIConfig.empty.isConfigured == false)
    }

    @Test("default config has no provider-specific defaults")
    func defaults() {
        #expect(OpenAIConfig.empty.baseURL == "")
        #expect(OpenAIConfig.empty.apiKey == "")
        #expect(OpenAIConfig.empty.model == "")
    }

    @Test("filled config is configured")
    func filled() {
        let cfg = OpenAIConfig(baseURL: "https://api.example.com/v1", apiKey: "sk-x", model: "gpt-4o-mini")
        #expect(cfg.isConfigured == true)
    }

    @Test("missing key rejected")
    func noKey() {
        let cfg = OpenAIConfig(baseURL: "https://x/v1", apiKey: "", model: "x")
        #expect(cfg.isConfigured == false)
    }

    @Test("missing model rejected")
    func noModel() {
        let cfg = OpenAIConfig(baseURL: "https://x/v1", apiKey: "k", model: "")
        #expect(cfg.isConfigured == false)
    }

    @Test("ftp URL rejected")
    func badURL() {
        let cfg = OpenAIConfig(baseURL: "ftp://x", apiKey: "k", model: "m")
        #expect(cfg.isConfigured == false)
    }
}
