import Foundation

/// Structured side-channel payload carried by a `.tool` `ChatMessage`. The
/// LLM never sees this — it's UI-only. The corresponding `toolResult` text
/// remains the canonical info the model gets in the conversation.
public enum ChatRichContent: Sendable, Equatable {
    case searchSeriesResults([SearchResult])
    case searchMovieResults([SearchResult])
    case librarySeries([SonarrLibraryRecord])
    case libraryMovies([RadarrLibraryRecord])
    case calendar([UpcomingItem])
}
