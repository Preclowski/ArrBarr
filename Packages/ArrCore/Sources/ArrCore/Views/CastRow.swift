import SwiftUI

/// Source-neutral cast member for the detail cast strip. Movies map from
/// Radarr's `/credit` (no TMDB key needed); series map from TMDB credits.
public struct CastMember: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let role: String?
    public let imageURL: URL?

    public init(id: String, name: String, role: String?, imageURL: URL?) {
        self.id = id
        self.name = name
        self.role = role
        self.imageURL = imageURL
    }
}

/// Horizontally-scrolling cast strip for detail surfaces — circular headshot
/// + name + character per person. Movie cast comes from Radarr (`/credit`),
/// series cast from TMDB; both normalise to `CastMember`.
struct CastRow: View {
    let cast: [CastMember]
    /// Cap — providers return dozens; the first ~16 are the headline cast.
    var limit: Int = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cast", bundle: .module)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(cast.prefix(limit)) { person in
                        VStack(spacing: 4) {
                            avatar(person)
                            Text(person.name)
                                .scaledFont(size: 10, weight: .semibold)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            if let role = person.role, !role.isEmpty {
                                Text(role)
                                    .scaledFont(size: 9)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .frame(width: 64)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func avatar(_ person: CastMember) -> some View {
        let size: CGFloat = 52
        // RemotePoster routes through the shared ImageCache (memory + disk,
        // OS-purgeable) — same caching as posters — instead of AsyncImage's
        // default URLCache. cornerRadius = size/2 makes the headshot circular.
        RemotePoster(
            url: person.imageURL,
            apiKey: nil,
            size: CGSize(width: size, height: size),
            cornerRadius: size / 2,
            fallbackSymbol: "person.fill"
        )
    }
}

// MARK: - Mapping helpers

extension CastMember {
    /// Radarr `/credit` → cast members (cast only, ordered, headshots).
    static func from(radarrCredits credits: [ArrCredit]) -> [CastMember] {
        credits
            .filter { ($0.type ?? "").lowercased() == "cast" }
            .sorted { ($0.order ?? .max) < ($1.order ?? .max) }
            .compactMap { c in
                guard let name = c.personName, !name.isEmpty else { return nil }
                return CastMember(
                    id: "\(c.personTmdbId ?? 0)-\(name)-\(c.order ?? 0)",
                    name: name,
                    role: c.character,
                    imageURL: c.headshotURL
                )
            }
    }

    /// TMDB credits → cast members (used for series, which have no Radarr-style
    /// `/credit` endpoint).
    static func from(tmdbCast cast: [TMDBCreditPerson]) -> [CastMember] {
        cast.map { p in
            CastMember(id: "tmdb-\(p.id)", name: p.name, role: p.character, imageURL: p.posterURL)
        }
    }
}
