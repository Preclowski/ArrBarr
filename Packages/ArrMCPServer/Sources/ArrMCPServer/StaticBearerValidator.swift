import MCP

/// Rejects requests lacking a matching `Authorization: Bearer <token>` header.
/// Named to avoid colliding with the SDK's own OAuth-flavoured
/// `MCP.BearerTokenValidator`. Place AFTER `OriginValidator.localhost()` in the
/// validation pipeline.
struct StaticBearerValidator: HTTPRequestValidator {
    let token: String
    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard let auth = request.header(HTTPHeaderName.authorization),
              auth.hasPrefix("Bearer "),
              String(auth.dropFirst("Bearer ".count)) == token else {
            return .error(statusCode: 401, .invalidRequest("Unauthorized"),
                          extraHeaders: [HTTPHeaderName.wwwAuthenticate: "Bearer"])
        }
        return nil
    }
}
