import Foundation
import os

/// The single send path. A value over actors; a service holds one for free.
public struct RequestPipeline: Sendable {
    public let transport: any Transport
    public let sockets: (any SocketTransport)?
    public let governor: HostGovernor
    public let sessions: SessionBroker
    public let credentials: any CredentialProvider
    public let registry: InstanceRegistry
    public let telemetry: any TelemetrySink
    public let log: any LogSink
    public let signposts: OSSignposter?
    public let clock: any MediaClock

    public init(transport: any Transport, sockets: (any SocketTransport)?, governor: HostGovernor, sessions: SessionBroker,
                credentials: any CredentialProvider, registry: InstanceRegistry, telemetry: any TelemetrySink,
                log: any LogSink, signposts: OSSignposter? = nil, clock: any MediaClock) {
        self.transport = transport; self.sockets = sockets; self.governor = governor; self.sessions = sessions
        self.credentials = credentials; self.registry = registry; self.telemetry = telemetry; self.log = log
        self.signposts = signposts; self.clock = clock
    }

    public func send(_ plan: RequestPlan) async throws -> HTTPResponse {
        guard let descriptor = registry.descriptor(plan.instance), descriptor.enabled else {
            throw MediaKitError.notConfigured(plan.instance)
        }
        guard let credentials = await credentials.credentials(for: plan.instance) else {
            throw MediaKitError.notConfigured(plan.instance)
        }
        let host = Host(credentials.baseURL)
        var attempt = 0
        var handshakeUsed = false
        while true {
            attempt += 1
            let observedGeneration = await sessions.generation(plan.instance)
            let request = try await sessions.authorize(plan, credentials: credentials)
            let slot = try await governor.enter(host, kind: plan.instance.kind, priority: plan.priority)
            telemetry.record(.request(plan.operation, host, plan.priority))
            log.log(.debug, category: "Transport", "\(plan.method) \(plan.operation) attempt \(attempt)",
                    privateFields: ["url": Redaction.standard.loggableURL(request.url)])
            let started = clock.now
            let response: HTTPResponse
            do {
                response = try await timed("mediakit.request") { try await transport.send(request) }
            } catch is CancellationError {
                await governor.leave(slot, outcome: .cancelled)
                throw CancellationError()
            } catch let error as MediaKitError {
                await governor.leave(slot, outcome: .cancelled)
                telemetry.record(.failure(plan.operation, host, error))
                throw error
            } catch {
                let failure = MediaKitError.unreachable(host, Self.classify(error))
                let retrying = plan.retry == .idempotent && attempt < 3
                // One breaker strike per logical request: a retried read must not trip the host on its own.
                await governor.leave(slot, outcome: retrying ? .cancelled : .transportFailure(failure))
                telemetry.record(.failure(plan.operation, host, failure))
                if retrying {
                    try await backoff(attempt: attempt, retryAfter: nil)
                    continue
                }
                throw failure
            }
            telemetry.record(.response(plan.operation, host, status: response.status, bytes: response.body.count,
                                       duration: .seconds(clock.now.timeIntervalSince(started))))
            if response.isSuccess {
                await governor.leave(slot, outcome: .success)
                if let rejection = await sessions.rejection(for: response, kind: plan.instance.kind), rejection == .unauthenticated {
                    // In-band rejection on HTTP 200 (Deluge, SABnzbd).
                    if try await recover(plan, rejection: rejection, credentials: credentials, observedGeneration: observedGeneration, used: &handshakeUsed) { continue }
                    throw MediaKitError.unauthorized(plan.instance, status: response.status, serverMessage: RequestBuilder.serverMessage(from: response.body))
                }
                return response
            }
            if let rejection = await sessions.rejection(for: response, kind: plan.instance.kind) {
                await governor.leave(slot, outcome: .success)
                if try await recover(plan, rejection: rejection, credentials: credentials, observedGeneration: observedGeneration, used: &handshakeUsed) { continue }
                throw MediaKitError.unauthorized(plan.instance, status: response.status, serverMessage: RequestBuilder.serverMessage(from: response.body))
            }
            // A bare 503 is one app behind a shared reverse proxy restarting, not the host asking for quiet.
            if response.status == 429 || (response.status == 503 && response.headers["Retry-After"] != nil) {
                let delay = Self.retryAfter(response.headers["Retry-After"], now: clock.now) ?? .seconds(30)
                await governor.leave(slot, outcome: .retryAfter(delay))
                let error = MediaKitError.rateLimited(host, retryAfter: delay)
                telemetry.record(.failure(plan.operation, host, error))
                if plan.retry == .idempotent, attempt < 3, delay <= .seconds(8) {
                    try await backoff(attempt: attempt, retryAfter: delay)
                    continue
                }
                throw error
            }
            await governor.leave(slot, outcome: .success)
            let message = RequestBuilder.serverMessage(from: response.body)
            let error: MediaKitError = response.status >= 500
                ? .serverFault(plan.instance, status: response.status, serverMessage: message)
                : .rejected(plan.instance, status: response.status, serverMessage: message)
            telemetry.record(.failure(plan.operation, host, error))
            if error.isTransient, plan.retry == .idempotent, attempt < 3 {
                try await backoff(attempt: attempt, retryAfter: nil)
                continue
            }
            throw error
        }
    }

    public func socket(_ plan: RequestPlan) async throws -> any WireSocket {
        guard let sockets else { throw MediaKitError.unsupported(plan.instance, Capability(rawValue: "sockets")) }
        guard let descriptor = registry.descriptor(plan.instance), descriptor.enabled,
              let credentials = await credentials.credentials(for: plan.instance) else {
            throw MediaKitError.notConfigured(plan.instance)
        }
        let request = try await sessions.authorize(plan, credentials: credentials)
        let host = Host(credentials.baseURL)
        telemetry.record(.request(plan.operation, host, plan.priority))
        do {
            return try await sockets.open(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MediaKitError {
            throw error
        } catch {
            let failure = MediaKitError.unreachable(host, Self.classify(error))
            telemetry.record(.failure(plan.operation, host, failure))
            throw failure
        }
    }

    /// Decodes off the caller's actor; the one place JSON becomes a value.
    @concurrent
    public func decode<T: Decodable & Sendable>(_ type: T.Type, from response: HTTPResponse, operation: OperationID) async throws -> T {
        try await timed("mediakit.decode") {
            do { return try WireCodec.decoder.decode(T.self, from: response.body) }
            catch { throw MediaKitError.decoding(operation, detail: WireCodec.describe(error)) }
        }
    }

    // MARK: - Internals

    private func recover(_ plan: RequestPlan, rejection: SessionRejection, credentials: Credentials,
                         observedGeneration: Int, used: inout Bool) async throws -> Bool {
        guard !used else { return false }
        used = true
        let send: SessionSend = { request in
            let slot = try await governor.enter(Host(credentials.baseURL), kind: plan.instance.kind, priority: .session)
            do {
                let response = try await transport.send(request)
                await governor.leave(slot, outcome: .success)
                return response
            } catch {
                await governor.leave(slot, outcome: error is CancellationError ? .cancelled : .transportFailure(.unreachable(Host(credentials.baseURL), Self.classify(error))))
                throw error
            }
        }
        return try await sessions.refresh(plan.instance, after: rejection, credentials: credentials, observedGeneration: observedGeneration, send: send)
    }

    private func backoff(attempt: Int, retryAfter: Duration?) async throws {
        let delay = retryAfter ?? .milliseconds(min(250 * Int(pow(2.0, Double(attempt - 1))) * Int.random(in: 80...120) / 100, 8000))
        try await clock.sleep(for: delay)
    }

    private func timed<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        guard let signposts else { return try await body() }
        let state = signposts.beginInterval(name)
        defer { signposts.endInterval(name, state) }
        return try await body()
    }

    static func classify(_ error: any Error) -> UnreachableKind {
        guard let urlError = error as? URLError else { return .other }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed: return .dns
        case .cannotConnectToHost, .networkConnectionLost: return .refused
        case .timedOut: return .timeout
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected: return .tls
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed: return .offline
        default: return .other
        }
    }

    static func retryAfter(_ header: String?, now: Date) -> Duration? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = Double(header) { return .seconds(max(seconds, 0)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        guard let date = formatter.date(from: header) else { return nil }
        return .seconds(max(date.timeIntervalSince(now), 0))
    }
}

public enum WireCodec {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = (try? Date(s, strategy: iso8601Fractional)) ?? (try? Date(s, strategy: iso8601)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    /// TMDB and the media servers spell keys in snake_case / PascalCase; services pick the decoder.
    public static let snakeCaseDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(iso8601Fractional))
        }
        return e
    }()

    static let iso8601Fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static let iso8601 = Date.ISO8601FormatStyle()

    static func describe(_ error: any Error) -> String {
        guard let e = error as? DecodingError else { return String(describing: error) }
        switch e {
        case let .keyNotFound(key, ctx): return "missing \(key.stringValue) at \(path(ctx))"
        case let .typeMismatch(type, ctx): return "type \(type) at \(path(ctx))"
        case let .valueNotFound(type, ctx): return "null \(type) at \(path(ctx))"
        case let .dataCorrupted(ctx): return "corrupt at \(path(ctx)): \(ctx.debugDescription)"
        @unknown default: return String(describing: e)
        }
    }

    private static func path(_ ctx: DecodingError.Context) -> String { ctx.codingPath.map(\.stringValue).joined(separator: ".") }
}
