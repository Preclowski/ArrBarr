import Foundation

// Media-server tool implementations (Plex / Jellyfin / Emby). Kept in their own
// extension for the same reason the arr tools are: the core actor stays init +
// dispatch, and these three touch no arr at all.
//
// All three answer in plain text — a watch list and a session list are prose
// the model relays, not cards the user taps.

extension LocalToolBackend {

    /// Default and ceiling for `media_server_watch_history`. The ceiling exists
    /// because the model will happily ask for "all of it", and a full Plex
    /// history is thousands of rows of tokens for a question that never needed
    /// more than a page.
    private static var watchHistoryDefaultLimit: Int { 20 }
    private static var watchHistoryMaxLimit: Int { 100 }

    /// The client, or a thrown error. `callTool` already turns an unconfigured
    /// media server into a canned line before dispatch, so this is a backstop
    /// rather than a path anyone reaches — which is exactly why it should not
    /// be three copies of the same string.
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
            return ToolCallOutput(text: "Couldn't read watch history: \(error.userFacingMessage)")
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
            return ToolCallOutput(text: "Couldn't read active sessions: \(error.userFacingMessage)")
        }
        guard !sessions.isEmpty else {
            return ToolCallOutput(text: "Nothing is playing on \(mediaServer.kind.displayName) right now.")
        }

        let lines = sessions.map { session -> String in
            var line = session.title
            if let subtitle = session.subtitle { line += " — \(subtitle)" }
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
            return ToolCallOutput(text: "FAILED: the scan request was rejected — \(error.userFacingMessage)")
        }
        // Deliberately does not claim the scan finished: every one of the three
        // servers accepts the request and works through it on its own schedule,
        // so "done" would be a claim we cannot back up.
        return ToolCallOutput(
            text: "OK: asked \(mediaServer.kind.displayName) to rescan its libraries. "
                + "It runs in the background — newly imported titles appear once it finishes."
        )
    }
}
