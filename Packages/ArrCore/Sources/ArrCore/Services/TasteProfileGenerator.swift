import Foundation

/// Distills the swipe log + recent watch history into the taste paragraph.
///
/// Runs on whatever LLM the user already trusts for chat — Apple Intelligence
/// stays fully on-device; an OpenAI-compatible endpoint is the same endpoint
/// their chat titles already travel to, so the profile adds no new exposure.
@MainActor
public enum TasteProfileGenerator {

    public enum GenerationError: LocalizedError {
        case noProvider
        case noSignal
        case emptyReply

        public var errorDescription: String? {
            switch self {
            case .noProvider:
                return String(localized: "No AI provider is available — configure the chat first.", bundle: .module)
            case .noSignal:
                return String(localized: "Nothing to learn from yet — swipe through a quiz or connect a media server.", bundle: .module)
            case .emptyReply:
                return String(localized: "The model returned nothing — try again.", bundle: .module)
            }
        }
    }

    /// Builds the generation prompt. Pure and internal so the shape is
    /// testable without a model.
    static func buildPrompt(kept: [String], skipped: [String], vetoed: [String],
                            watched: [String], languageName: String) -> String {
        var sections: [String] = []
        if !kept.isEmpty { sections.append("Titles they KEPT (right-swiped, want to watch):\n" + kept.joined(separator: ", ")) }
        if !skipped.isEmpty { sections.append("Titles they SKIPPED (not now):\n" + skipped.joined(separator: ", ")) }
        if !vetoed.isEmpty { sections.append("Titles they explicitly REJECTED (never show again):\n" + vetoed.joined(separator: ", ")) }
        if !watched.isEmpty { sections.append("Recently watched on their media server:\n" + watched.joined(separator: ", ")) }
        return """
        Write the user's movie/TV taste profile: 2-4 plain sentences, third person, \
        no preamble, no bullet points, no title lists — name genres, tones, eras and \
        patterns, including what they avoid. Write it in \(languageName). \
        Base it ONLY on the signals below; do not invent preferences.

        \(sections.joined(separator: "\n\n"))
        """
    }

    /// Generates and stores a fresh paragraph. Throws with a user-readable
    /// message when there is no provider or no signal.
    public static func regenerate(provider: LLMProvider, languageName: String) async throws {
        if provider is UnavailableLLMProvider { throw GenerationError.noProvider }
        let signals = SwipeSignalStore.shared.all
        let kept = signals.filter { $0.kind == .kept }.prefix(40).map(\.title)
        let skipped = signals.filter { $0.kind == .skipped }.prefix(40).map(\.title)
        let vetoed = signals.filter { $0.kind == .veto }.prefix(20).map(\.title)
        let watched = MediaServerIndex.shared.recentlyWatched().prefix(40).map { watch in
            watch.year.map { "\(watch.title) (\($0))" } ?? watch.title
        }
        guard !(kept.isEmpty && skipped.isEmpty && vetoed.isEmpty && watched.isEmpty) else {
            throw GenerationError.noSignal
        }
        let prompt = buildPrompt(kept: Array(kept), skipped: Array(skipped),
                                 vetoed: Array(vetoed), watched: Array(watched),
                                 languageName: languageName)
        let response = try await provider.respond(prompt: prompt, tools: [], history: [])
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GenerationError.emptyReply }
        TasteProfileStore.shared.setParagraph(text)
    }
}
