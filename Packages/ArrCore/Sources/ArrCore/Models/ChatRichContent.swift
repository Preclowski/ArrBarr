import Foundation

/// Structured side-channel payload carried by a `.tool` `ChatMessage`. The
/// LLM never sees this — it's UI-only. The corresponding `toolResult` text
/// remains the canonical info the model gets in the conversation.
public enum ChatRichContent: Sendable, Equatable {
    case searchSeriesResults([SearchResult])
    case searchMovieResults([SearchResult])
    case searchArtistResults([SearchResult])
    case searchSceneResults([SearchResult])
    case librarySeries([SonarrLibraryRecord])
    case libraryMovies([RadarrLibraryRecord])
    case libraryArtists([LidarrLibraryRecord])
    case libraryScenes([WhisparrLibraryRecord])
    case calendar([UpcomingItem])
    /// Active download queue. Upgrade rows render as a side-by-side
    /// comparison (current library file vs incoming release) so the user
    /// can see at a glance what's improving.
    case downloadQueue([QueueItem])
    /// Resume card for the Discover quiz overlay. Shown in chat after a
    /// `discover_in_quiz` tool call so the user can re-enter the just-opened
    /// quiz without re-prompting the LLM.
    case discoverSession(mood: String, posterURLs: [URL])
}
