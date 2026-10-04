import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ArrCore

/// A flaky connection must not blacklist artwork; only the server saying it's gone may.
@Suite("Poster failures")
struct PosterFailureTests {

    @Test("A dropped connection is retried on the next request")
    func transientFailureRetries() async throws {
        let url = try #require(URL(string: "https://artwork.example/\(UUID().uuidString).jpg"))
        let image = try #require(Self.jpeg())
        ScriptedProtocol.script(url, [.error(URLError(.networkConnectionLost)), .status(200, image)])
        let store = PosterStore(session: Self.session())

        #expect(await store.image(for: url, tier: .icon) == nil)
        #expect(await store.image(for: url, tier: .icon) != nil)
        #expect(ScriptedProtocol.requests(for: url) == 2)
    }

    @Test("A 404 is remembered instead of asked again")
    func goneIsRemembered() async throws {
        let url = try #require(URL(string: "https://artwork.example/\(UUID().uuidString).jpg"))
        ScriptedProtocol.script(url, [.status(404, Data()), .status(404, Data())])
        let store = PosterStore(session: Self.session())

        #expect(await store.image(for: url, tier: .icon) == nil)
        #expect(await store.image(for: url, tier: .icon) == nil)
        #expect(ScriptedProtocol.requests(for: url) == 1)
        #expect(PosterStore.isFreshMiss(url, tier: .icon))
    }

    @Test("A server error is not remembered")
    func serverErrorRetries() async throws {
        let url = try #require(URL(string: "https://artwork.example/\(UUID().uuidString).jpg"))
        ScriptedProtocol.script(url, [.status(503, Data()), .status(503, Data())])
        let store = PosterStore(session: Self.session())

        #expect(await store.image(for: url, tier: .icon) == nil)
        #expect(await store.image(for: url, tier: .icon) == nil)
        #expect(ScriptedProtocol.requests(for: url) == 2)
        #expect(!PosterStore.isFreshMiss(url, tier: .icon))
    }

    /// Scoped to this session only: a globally registered stub would answer other suites.
    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedProtocol.self]
        return URLSession(configuration: config)
    }

    private static func jpeg() -> Data? {
        guard let ctx = CGContext(data: nil, width: 20, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

/// Answers each URL from its own queue of scripted responses, in order.
private final class ScriptedProtocol: URLProtocol, @unchecked Sendable {
    enum Reply { case error(URLError), status(Int, Data) }

    private static let state = NSLock()
    nonisolated(unsafe) private static var replies: [URL: [Reply]] = [:]
    nonisolated(unsafe) private static var counts: [URL: Int] = [:]

    static func script(_ url: URL, _ list: [Reply]) {
        state.withLock { replies[url] = list; counts[url] = 0 }
    }

    static func requests(for url: URL) -> Int {
        state.withLock { counts[url] ?? 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let reply: Reply? = Self.state.withLock {
            Self.counts[url, default: 0] += 1
            return Self.replies[url]?.isEmpty == false ? Self.replies[url]?.removeFirst() : nil
        }
        switch reply {
        case let .error(error):
            client?.urlProtocol(self, didFailWithError: error)
        case let .status(code, data):
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }

    override func stopLoading() {}
}
