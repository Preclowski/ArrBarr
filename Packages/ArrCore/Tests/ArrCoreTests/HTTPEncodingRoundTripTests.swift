import Foundation
import Testing
@testable import ArrCore

/// Encoding regressions, asserted by *decoding* rather than by string compare.
/// A round-trip is what the far end actually does, and it fails for the right
/// reason: if a separator leaks through unescaped the field simply splits, and
/// the recovered value is wrong — which is exactly how these bugs presented
/// (a qBittorrent login that 403'd forever, a search for "Disney+" that
/// silently queried "Disney ").
@Suite("Form + query encoding round-trips")
struct HTTPEncodingRoundTripTests {

    /// Decode an `application/x-www-form-urlencoded` body the way any server
    /// does: split on "&", then on the first "=", then "+" means space and the
    /// rest is percent-decoded.
    private func decodeForm(_ body: String) -> [String: String] {
        var fields: [String: String] = [:]
        for field in body.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            fields[Self.decodeComponent(parts[0])] = Self.decodeComponent(parts[1])
        }
        return fields
    }

    /// Decode a URL's query with ASP.NET semantics — the runtime every arr
    /// hosts on, and the reason a literal "+" is not merely ugly but wrong.
    private func decodeQuery(_ url: URL) -> [String: String] {
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        return decodeForm(raw)
    }

    private static func decodeComponent(_ raw: Substring) -> String {
        let spaced = raw.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    // MARK: - Form bodies

    /// A password may legally contain every character that also separates the
    /// body. Under `.urlQueryAllowed` this one was spliced into three fields
    /// ("password=p", "ss=w+rd") and qBittorrent answered 403 with no
    /// explanation — the login looked wrong, the credentials weren't.
    @Test("A password full of separators survives the round trip intact")
    func passwordWithSeparatorsSurvives() {
        let body = HTTPClient.encodeForm(["username": "admin", "password": "p&ss=w+rd"])

        // The structural half: exactly two fields, no matter what's in them.
        #expect(body.split(separator: "&").count == 2)

        let fields = decodeForm(body)
        #expect(fields.count == 2)
        #expect(fields["username"] == "admin")
        #expect(fields["password"] == "p&ss=w+rd")
    }

    /// "+" alone is the subtlest of the three: it survives an unescaped body
    /// as a *character*, then decodes to a space at the far end. Nothing errors
    /// — the password is just quietly wrong.
    @Test("A plus in a password is not delivered as a space")
    func plusIsNotASpace() {
        let fields = decodeForm(HTTPClient.encodeForm(["password": "a+b"]))
        #expect(fields["password"] == "a+b")
        #expect(fields["password"] != "a b")
    }

    @Test("Field names are escaped too, not just values")
    func namesAreEscapedAsWell() {
        let fields = decodeForm(HTTPClient.encodeForm(["od&d=name": "v"]))
        #expect(fields.count == 1)
        #expect(fields["od&d=name"] == "v")
    }

    @Test("Spaces and non-ASCII round-trip unchanged")
    func spacesAndUnicodeSurvive() {
        let fields = decodeForm(HTTPClient.encodeForm(["q": "café au lait"]))
        #expect(fields["q"] == "café au lait")
    }

    // MARK: - Query strings

    /// The user-visible bug: searching "Disney+" in the Search tab returned
    /// results for "Disney ", because URLComponents leaves "+" literal (it is a
    /// legal sub-delim) and ASP.NET decodes a literal "+" as a space.
    @Test("A search term ending in '+' arrives as typed", arguments: ["Disney+", "Apple TV+", "C++", "1+1"])
    func plusInSearchTermSurvives(_ term: String) throws {
        let url = try HTTPClient().url(
            base: "https://arr.test",
            path: "/api/v3/movie/lookup",
            query: [URLQueryItem(name: "term", value: term)]
        )
        #expect(decodeQuery(url)["term"] == term)

        let raw = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        #expect(raw.contains("%2B"))
        // No literal "+" may remain anywhere in the query — that character is
        // the entire defect.
        #expect(!raw.contains("+"))
    }

    /// The fix rewrites the already-encoded query, so it has to be surgical:
    /// everything URLComponents got right must come through untouched.
    @Test("Escaping '+' leaves spaces, '&', '=' and unicode exactly as they were")
    func plusFixDoesNotDisturbTheRest() throws {
        let term = "a b&c=d é+f"
        let url = try HTTPClient().url(
            base: "https://arr.test",
            path: "/api/v3/series/lookup",
            query: [URLQueryItem(name: "term", value: term)]
        )
        let fields = decodeQuery(url)
        // One field: an unescaped "&" or "=" would have split it into three.
        #expect(fields.count == 1)
        #expect(fields["term"] == term)
    }

    /// Two query items, one of them carrying a "+": the re-encode walks the
    /// whole query string, so it must not disturb the real separators between
    /// items.
    @Test("Multiple query items keep their own separators")
    func multipleQueryItems() throws {
        let url = try HTTPClient().url(
            base: "https://arr.test",
            path: "/api/v3/movie/lookup",
            query: [
                URLQueryItem(name: "term", value: "Disney+"),
                URLQueryItem(name: "apikey", value: "abc123"),
            ]
        )
        let fields = decodeQuery(url)
        #expect(fields.count == 2)
        #expect(fields["term"] == "Disney+")
        #expect(fields["apikey"] == "abc123")
    }
}
