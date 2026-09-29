import Foundation
import MediaKit

// Media-server tools (Plex / Jellyfin / Emby). Plain-text answers: prose the model relays, not tappable cards.

extension LocalToolBackend {

    /// Capped because the model will ask for "all of it", and a full Plex history is thousands of rows of tokens.
    nonisolated private static var watchHistoryDefaultLimit: Int { 20 }
    nonisolated private static var watchHistoryMaxLimit: Int { 100 }

    /// A backstop: `callTool` already answers an unconfigured media server before dispatch.
    private func mediaServerClient() throws -> MediaServerClient {
        guard let client = MediaServerClientFactory.make(config: mediaServer) else {
            throw MediaServerError.notConfigured
        }
        return client
    }

    func mediaServerWatchHistory(_ args: JSONValue) async throws -> ToolCallOutput {
        let client = try mediaServerClient()
        let requested = Self.optionalIntArg(args, key: "limit") ?? Self.watchHistoryDefaultLimit
        let limit = min(max(requested, 1), Self.watchHistoryMaxLimit)

        let watches: [MediaServerWatch]
        do {
            watches = try await client.recentlyWatched(limit: limit)
        } catch {
            return ToolCallOutput(text: "Couldn't read watch history: \(error.localizedDescription)")
        }
        guard !watches.isEmpty else {
            return ToolCallOutput(text: "Nothing has been watched on \(mediaServer.kind.displayName) yet.")
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        let lines = watches.map { watch -> String in
            var line = watch.title
            if let year = watch.year { line += " (\(year))" }
            line += watch.kind == .show ? " — series" : " — movie"
            if let watchedAt = watch.watchedAt {
                line += ", watched \(formatter.string(from: watchedAt))"
            }
            return "• \(line)"
        }
        return ToolCallOutput(
            text: "Recently watched on \(mediaServer.kind.displayName), newest first:\n"
                + lines.joined(separator: "\n")
        )
    }

    func mediaServerNowPlaying() async throws -> ToolCallOutput {
        let client = try mediaServerClient()
        let sessions: [MediaServerSession]
        do {
            sessions = try await client.nowPlaying()
        } catch {
            return ToolCallOutput(text: "Couldn't read active sessions: \(error.localizedDescription)")
        }
        guard !sessions.isEmpty else {
            return ToolCallOutput(text: "Nothing is playing on \(mediaServer.kind.displayName) right now.")
        }

        let lines = sessions.map { session -> String in
            var line = session.headline
            if let episode = session.episodeLine { line += " — \(episode)" }
            if let user = session.user { line += ", \(user)" }
            if let device = session.device { line += " on \(device)" }
            line += session.isTranscoding ? ", transcoding" : ", direct play"
            if let progress = session.progress {
                line += ", \(Int((progress * 100).rounded()))% in"
            }
            return "• \(line)"
        }
        return ToolCallOutput(
            text: "Playing now on \(mediaServer.kind.displayName):\n" + lines.joined(separator: "\n")
        )
    }

    func mediaServerScanLibrary() async throws -> ToolCallOutput {
        let client = try mediaServerClient()
        do {
            try await client.scanLibraries()
        } catch {
            return ToolCallOutput(text: "FAILED: the scan request was rejected — \(error.localizedDescription)")
        }
        // Doesn't claim the scan finished: every server works through it on its own schedule.
        return ToolCallOutput(
            text: "OK: asked \(mediaServer.kind.displayName) to rescan its libraries. "
                + "It runs in the background — newly imported titles appear once it finishes."
        )
    }
}
