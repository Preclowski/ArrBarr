import Testing
import Foundation
import MediaKit
@testable import ArrCore

/// Criterion 13: every `MediaKitError` case reaches the user through a catalogue key; SwiftPM does not compile the
/// catalogue, so the test reads it as JSON and checks the key per case.
@Suite("MediaKit error catalogue")
struct MediaKitErrorCatalogTests {
    static let cases: [MediaKitError] = {
        let host = Host(URL(string: "http://radarr.local:7878")!)
        let instance = InstanceID(.radarr)
        return [.notConfigured(instance), .unreachable(host, .refused), .breakerOpen(host, until: Date()), .rateLimited(host, retryAfter: nil),
                .unauthorized(instance, status: 401, serverMessage: nil), .rejected(instance, status: 404, serverMessage: nil),
                .serverFault(instance, status: 503, serverMessage: nil), .serviceError(instance, code: "x", message: nil),
                .decoding(OperationID(.radarr, "fetchQueue"), detail: "d"), .unsupported(instance, .whisparrV3), .persistence(detail: "p"),
                .notPermitted(OperationID(.radarr, "fetchQueue")), .fixtureMissing(OperationID(.radarr, "fetchQueue"))]
    }()

    @Test("Every error case has a catalogue key and a message")
    func everyCaseHasAKey() throws {
        let url = Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ArrCore/Resources/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        for error in Self.cases {
            let key = error.caseName == "notConfigured" ? "common.arrbarrIsNotConfigured.label" : "mediakit.error.\(error.caseName)"
            #expect(strings[key] != nil, Comment(rawValue: key))
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test("An auth failure names the fix and keeps the server's reason")
    func authFailureCarriesAHint() {
        let instance = InstanceID(.qbittorrent)
        let bare = MediaKitErrorPresenter.message(for: MediaKitError.unauthorized(instance, status: 401, serverMessage: nil))
        let withBody = MediaKitErrorPresenter.message(for: MediaKitError.unauthorized(instance, status: 403, serverMessage: "Fails."))
        #expect(bare.contains("401"))
        #expect(withBody.contains("403") && withBody.hasSuffix("(Fails.)"))
    }

    @Test("A rejection shows the arr's own reason")
    func rejectionShowsServerReason() {
        let error = MediaKitError.rejected(InstanceID(.sonarr), status: 400, serverMessage: "This series has already been added")
        #expect(error.localizedDescription == "This series has already been added")
    }

    @Test("Certificate and address failures name what to fix", arguments: [UnreachableKind.tls, .dns])
    func fixableUnreachableKindsAreSpecific(kind: UnreachableKind) {
        let host = Host(URL(string: "https://nas.lan:8989")!)
        let generic = MediaKitError.unreachable(host, .refused).localizedDescription
        let specific = MediaKitError.unreachable(host, kind).localizedDescription
        #expect(specific != generic && specific.contains("nas.lan:8989"))
    }
}
