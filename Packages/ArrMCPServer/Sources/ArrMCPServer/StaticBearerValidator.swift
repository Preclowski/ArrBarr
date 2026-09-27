import CryptoKit
import Foundation
import Logging
import MCP

/// Named to avoid the SDK's OAuth-flavoured `MCP.BearerTokenValidator`. Place after
/// `OriginValidator.localhost()` in the pipeline.
struct StaticBearerValidator: HTTPRequestValidator {
    let token: String
    var logger = Logger(label: "arrbarr.mcp.auth")

    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        // Fail closed on an empty token rather than match a forged empty "Bearer " header.
        guard !token.isEmpty,
              let auth = request.header(HTTPHeaderName.authorization),
              auth.hasPrefix("Bearer "),
              Self.constantTimeEquals(String(auth.dropFirst("Bearer ".count)), token) else {
            // Notice-level so "misconfigured client" vs "something else knocking" can
            // be read back. The presented token is never logged, not even a prefix.
            let reason = token.isEmpty ? "no token configured"
                : (request.header(HTTPHeaderName.authorization) == nil ? "no Authorization header" : "token mismatch")
            logger.notice("MCP request rejected: 401", metadata: ["reason": .string(reason)])
            return .error(statusCode: 401, .invalidRequest("Unauthorized"),
                          extraHeaders: [HTTPHeaderName.wwwAuthenticate: "Bearer"])
        }
        return nil
    }

    /// Digests, because String `==` short-circuits and leaks the matching prefix length.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        SHA256.hash(data: Data(a.utf8)) == SHA256.hash(data: Data(b.utf8))
    }
}
