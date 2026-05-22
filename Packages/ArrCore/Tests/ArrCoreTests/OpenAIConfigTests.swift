import Testing
import Foundation
@testable import ArrCore

@Suite("OpenAIConfig")
struct OpenAIConfigTests {
    @Test("empty config is not configured")
    func emptyNotConfigured() {
        #expect(OpenAIConfig.empty.isConfigured == false)
    }

    @Test("default config has openrouter URL + model")
    func defaults() {
        #expect(OpenAIConfig.empty.baseURL == "https://openrouter.ai/api/v1")
        #expect(OpenAIConfig.empty.model == "openai/gpt-4o-mini")
    }

    @Test("filled config is configured")
    func filled() {
        let cfg = OpenAIConfig(baseURL: "https://openrouter.ai/api/v1", apiKey: "sk-or-x", model: "openai/gpt-4o-mini")
        #expect(cfg.isConfigured == true)
    }

    @Test("missing key rejected")
    func noKey() {
        var cfg = OpenAIConfig.empty
        cfg.model = "x"
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
