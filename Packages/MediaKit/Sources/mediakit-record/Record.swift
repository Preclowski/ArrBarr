import Foundation
import MediaKit
import MediaKitRecording

/// `swift run mediakit-record <instances.json> <output-dir>` — records the reads the app makes, through the allow-list.
///
/// `instances.json`: `[{"kind": "radarr", "url": "http://…", "apiKey": "…"}, {"kind": "qbittorrent", "url": "…",
/// "user": "…", "password": "…"}, {"kind": "plex", "url": "…", "token": "…"}, {"kind": "tmdb", "apiKey": "…"}]`.
/// Recordings carry the real library: keep them in a scratch directory, then `Tools/fixtures/anonymize_fixtures.py`
/// and `pack_fixtures.py pack` before anything reaches the repo.
@main
struct Record {
    struct Entry: Decodable {
        let kind: String
        let url: String?
        let apiKey: String?
        let user: String?
        let password: String?
        let token: String?
    }

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            FileHandle.standardError.write(Data("usage: mediakit-record <instances.json> <output-dir>\n".utf8))
            exit(64)
        }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let output = URL(fileURLWithPath: args[2], isDirectory: true)

        var credentials: [InstanceID: Credentials] = [:]
        var descriptors: [InstanceDescriptor] = []
        for entry in entries {
            guard let kind = InstanceKind(rawValue: entry.kind) else { throw RecordError.unknownKind(entry.kind) }
            let fallback = kind == .tmdb ? "https://api.themoviedb.org" : ""
            guard let url = URL(string: entry.url ?? fallback), url.scheme != nil else { throw RecordError.missingURL(entry.kind) }
            let material: Credentials.Material =
                if let key = entry.apiKey { .apiKey(key) }
                else if let token = entry.token { .token(token) }
                else if let user = entry.user { .userPassword(user: user, password: entry.password ?? "") }
                else { .none }
            let id = InstanceID(kind)
            credentials[id] = Credentials(baseURL: url, material: material, generation: "record")
            descriptors.append(InstanceDescriptor(id: id, baseURL: url, generation: "record"))
        }

        let live = URLSessionTransport(session: URLSession(configuration: .ephemeral))
        let recorder = RecordingTransport(wrapping: live, output: output)
        let stack = try MediaStack(MediaStack.Configuration(transport: recorder, sockets: nil, credentials: StaticCredentials(credentials)))
        await stack.start(instances: descriptors)
        for descriptor in descriptors { await record(descriptor.id, in: stack) }
        await stack.stop()
        print("recorded into \(output.path)")
    }

    private static func record(_ instance: InstanceID, in stack: MediaStack) async {
        let store = stack.store
        func read<V>(_ resource: Resource<V>) async -> V? {
            do { return try await store.read(resource, policy: .mustRevalidate).value } catch {
                print("\(instance) \(resource.plan.operation.name): \(error)")
                return nil
            }
        }
        if let s = stack.servarr(instance) {
            _ = await read(s.status()); _ = await read(s.health()); _ = await read(s.diskSpace())
            _ = try? await stack.pipeline.send(s.queuePlan())
            _ = await read(s.calendar(start: Date().addingTimeInterval(-7 * 86_400), end: Date().addingTimeInterval(30 * 86_400)))
            _ = await read(s.history()); _ = await read(s.qualityProfiles()); _ = await read(s.rootFolders())
            _ = await read(s.customFormats()); _ = await read(s.downloadClients()); _ = await read(s.commands())
            switch instance.kind {
            case .radarr, .whisparr:
                _ = await read(s.alternateTitles())
                if let id = await read(s.movies())?.first?.id { _ = await read(s.movie(id: id)); _ = await read(s.credits(movieID: id)) }
            case .sonarr:
                if let id = await read(s.series())?.first?.id { _ = await read(s.seriesDetails(id: id)); _ = await read(s.episodes(seriesID: id)) }
            case .lidarr:
                _ = await read(s.metadataProfiles())
                if let id = await read(s.artists())?.first?.id,
                   let album = await read(s.albums(artistID: id))?.first?.id {
                    _ = await read(s.artist(id: id)); _ = await read(s.album(id: album)); _ = await read(s.tracks(albumID: album))
                }
            default: break
            }
        } else if let d = stack.download(instance) {
            _ = await read(d.version()); _ = await read(d.defaultAddPaused())
            _ = try? await d.fetchTasks(ids: [], pipeline: stack.pipeline)
        } else if let m = stack.mediaServer(instance) {
            _ = await read(m.identity()); _ = await read(m.sessions()); _ = await read(m.watchHistory()); _ = await read(m.users())
            if let section = await read(m.libraries())?.first?.key { _ = await read(m.libraryIndex(section: section)) }
        } else if instance.kind == .tmdb {
            let t = stack.tmdb
            _ = await read(t.configuration()); _ = await read(t.discoverMovies()); _ = await read(t.discoverTV())
        }
    }

    enum RecordError: Error { case unknownKind(String), missingURL(String) }
}
