import Foundation
import MediaKit

nonisolated public enum HTTPError: LocalizedError {
    case badURL
    case transport(Error)
    case status(Int, body: String?)
    case decoding(Error)
    case notConfigured
    case missingApiKey
    /// Boundary-check failure: caller tried to add a SearchResult to
    /// a client whose source can't resolve the result's MediaRef
    /// (e.g. a `.tvdb(_)` ref handed to a `.radarr` client). Used to
    /// be silently allowed at the SDK layer and reported as a vague
    /// HTTP 400 from the arr; this case surfaces the mismatch at the
    /// SDK boundary instead.
    case wrongSource(refKind: String, clientSource: String)

    public var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid URL"
        case .transport(let e): return "Network error: \(e.localizedDescription)"
        case .status(let code, let body):
            // arr APIs return the real reason in the body (e.g. Sonarr's
            // "This series has already been added", an invalid quality
            // profile, or a missing root folder). Surfacing just "HTTP 400"
            // hides all of that. Parse the server message and append it.
            let detail = Self.serverMessage(from: body)
            // …except on 401/403, where Servarr answers with an *empty* body:
            // a wrong or missing API key renders as a bare "HTTP 401" that
            // names neither the cause nor the fix. Say both, and keep any
            // detail the service did send (download clients usually do).
            if code == 401 || code == 403 {
                let hint = String(
                    localized: "Authentication failed. Check the API key or password in Settings.",
                    bundle: .module
                )
                if let detail { return "HTTP \(code): \(hint) (\(detail))" }
                return "HTTP \(code): \(hint)"
            }
            if let detail {
                return "HTTP \(code): \(detail)"
            }
            return "HTTP \(code)"
        case .decoding(let e): return "Decoding error: \(e.localizedDescription)"
        case .notConfigured: return "Service not configured"
        case .missingApiKey: return "API key is missing"
        case .wrongSource(let ref, let src):
            return "Can't add a \(ref) reference via \(src)."
        }
    }

    /// Extract a human-readable reason from an arr error-response body.
    /// arr stacks return validation failures in several shapes:
    ///   • Servarr array: `[{ "errorMessage": "…", "propertyName": "…" }]`
    ///   • Servarr object: `{ "message": "…" }`
    ///   • ASP.NET ProblemDetails: `{ "title": "…", "errors": { "field": ["…"] } }`
    /// Falls back to the trimmed raw body so nothing useful is ever dropped.
    /// Returns nil when there's nothing to show.
    static func serverMessage(from body: String?) -> String? {
        guard let body else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            // Servarr validation array: [{ "errorMessage": "…" }, …]
            if let arr = json as? [[String: Any]] {
                let messages = arr.compactMap { stringValue(in: $0) }
                if !messages.isEmpty { return messages.joined(separator: "; ") }
            }
            if let obj = json as? [String: Any] {
                // ASP.NET ProblemDetails: { "errors": { "field": ["msg", …] } }
                if let errors = obj["errors"] as? [String: Any] {
                    let messages = errors.values.flatMap { value -> [String] in
                        if let list = value as? [String] { return list }
                        if let one = value as? String { return [one] }
                        return []
                    }
                    if !messages.isEmpty { return messages.joined(separator: "; ") }
                }
                // Single-object forms: message / errorMessage / title / detail.
                if let msg = stringValue(in: obj) { return msg }
            }
        }
        // Non-JSON body (plain text / HTML error page): cap length so a stray
        // HTML dump doesn't swamp the UI.
        return String(trimmed.prefix(300))
    }

    /// Pull the first present message-bearing string out of one JSON object,
    /// trying the keys the various arr / ASP.NET error shapes use.
    private static func stringValue(in obj: [String: Any]) -> String? {
        for key in ["errorMessage", "message", "title", "detail", "error"] {
            if let s = obj[key] as? String,
               !s.trimmingCharacters(in: .whitespaces).isEmpty {
                return s
            }
        }
        return nil
    }
}

nonisolated public extension Error {
    /// The message to put in front of a user.
    ///
    /// `localizedDescription` alone is not it: for a `LocalizedError` it falls
    /// back to a generic "operation couldn't be completed" wrapper and drops
    /// the `errorDescription` the type went to the trouble of writing — which
    /// for `HTTPError` is where the *arr's* own reason lives. Eight call sites
    /// spelled this out identically before it lived here.
    var userFacingMessage: String {
        if let mk = self as? MediaKitError { return MediaKitErrorPresenter.message(for: mk) }
        return (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}
