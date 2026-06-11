import CryptoKit
import Foundation
import MCP

/// Rejects requests lacking a matching `Authorization: Bearer <token>` header.
/// Named to avoid colliding with the SDK's own OAuth-flavoured
/// `MCP.BearerTokenValidator`. Place AFTER `OriginValidator.localhost()` in the
/// validation pipeline.
struct StaticBearerValidator: HTTPRequestValidator {
    let token: String

    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        // An empty configured token means auth is enabled but not set up yet —
        // fail closed instead of matching a forged empty "Bearer " header.
        guard !token.isEmpty,
              let auth = request.header(HTTPHeaderName.authorization),
              auth.hasPrefix("Bearer "),
              Self.constantTimeEquals(String(auth.dropFirst("Bearer ".count)), token) else {
            return .error(statusCode: 401, .invalidRequest("Unauthorized"),
                          extraHeaders: [HTTPHeaderName.wwwAuthenticate: "Bearer"])
        }
        return nil
    }

    /// Compare SHA-256 digests so comparison time doesn't leak how much of
    /// the token prefix matched (String `==` short-circuits on the first
    /// mismatching character).
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        SHA256.hash(data: Data(a.utf8)) == SHA256.hash(data: Data(b.utf8))
    }
}
