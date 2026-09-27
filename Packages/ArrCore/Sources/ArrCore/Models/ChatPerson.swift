import Foundation
import MediaKit

/// Just enough for the profile card above a filmography carousel; the rest is one tap away in `PersonView`.
nonisolated public struct ChatPerson: Sendable, Equatable, Identifiable {
    public let tmdbId: Int
    public let name: String
    public let knownForDepartment: String?
    public let profilePath: String?
    public let birthYear: Int?
    public let deathYear: Int?

    public var id: Int { tmdbId }

    public init(tmdbId: Int, name: String, knownForDepartment: String? = nil,
                profilePath: String? = nil, birthYear: Int? = nil, deathYear: Int? = nil) {
        self.tmdbId = tmdbId
        self.name = name
        self.knownForDepartment = knownForDepartment
        self.profilePath = profilePath
        self.birthYear = birthYear
        self.deathYear = deathYear
    }

    public init(_ p: TMDBPerson) {
        self.init(tmdbId: p.id, name: p.name,
                  knownForDepartment: p.knownForDepartment,
                  profilePath: p.profilePath)
    }

    public init(_ d: TMDBPersonDetails) {
        self.init(tmdbId: d.id, name: d.name,
                  knownForDepartment: d.knownForDepartment,
                  profilePath: d.profilePath,
                  birthYear: Self.year(d.birthday),
                  deathYear: Self.year(d.deathday))
    }

    /// Same w185 variant as the person view's header, so opening the profile hits a warm cache.
    public var profileURL: URL? { TMDBClient.imageURL(path: profilePath, size: "w185") }

    public var ref: PersonRef {
        PersonRef(tmdbId: tmdbId, name: name, profilePath: profilePath)
    }

    /// "1966" / "1966–2019" / nil.
    public var lifespan: String? {
        guard let birthYear else { return nil }
        guard let deathYear else { return String(birthYear) }
        return "\(birthYear)–\(deathYear)"
    }

    /// Anything but "YYYY-MM-DD" yields nil rather than a half-parsed year.
    static func year(_ date: String?) -> Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }
}
