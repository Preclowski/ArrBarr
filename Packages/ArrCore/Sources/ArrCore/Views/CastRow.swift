import SwiftUI

/// Source-neutral cast member for the detail cast strip. Movies map from
/// Radarr's `/credit` (no TMDB key needed); series map from TMDB credits.
public struct CastMember: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let role: String?
    public let imageURL: URL?
    /// TMDB person id — both providers already carry it (Radarr credits ship
    /// `personTmdbId`, TMDB credits their own id), so the tile can deep-link
    /// to the person's TMDB page with no extra API calls. nil = plain tile.
    public let tmdbPersonId: Int?

    public init(id: String, name: String, role: String?, imageURL: URL?, tmdbPersonId: Int? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.imageURL = imageURL
        self.tmdbPersonId = tmdbPersonId
    }
}

/// Horizontally-scrolling cast strip for detail surfaces — circular headshot
/// + name + character per person. Movie cast comes from Radarr (`/credit`),
/// series cast from TMDB; both normalise to `CastMember`.
struct CastRow: View {
    let cast: [CastMember]
    /// Cap — providers return dozens; the first ~16 are the headline cast.
    var limit: Int = 16
    /// Tapping a head opens the in-app person view. When nil (no host to push
    /// into) heads are inert. Replaces the old open-TMDB-in-browser behaviour —
    /// the external links live in the person view now.
    var onTapPerson: ((CastMember) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailSectionHeader("detail.cast.button", count: cast.count)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(cast.prefix(limit)) { person in
                        CastTile(person: person, onTapPerson: onTapPerson)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// One head+name+role tile. Opens the in-app person view when a tap handler is
/// wired and the person has a TMDB id; inert otherwise. On macOS a 600ms hover
/// reveals a rich tooltip (bio / age / birthplace) fetched lazily through
/// `PersonStore` — the hover gate means sweeping the cursor across the strip
/// doesn't fire a fetch per head.
private struct CastTile: View {
    let person: CastMember
    var onTapPerson: ((CastMember) -> Void)?
    @EnvironmentObject private var configStore: ConfigStore

    #if os(macOS)
    @State private var isHovering = false
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?
    #endif

    private var tile: some View {
        VStack(spacing: 4) {
            RemotePoster(
                url: person.imageURL,
                apiKey: nil,
                tier: .icon,
                size: CGSize(width: 52, height: 52),
                cornerRadius: 26,
                fallbackSymbol: "person.fill"
            )
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

    var body: some View {
        if let onTapPerson, person.tmdbPersonId != nil {
            Button { onTapPerson(person) } label: {
                tile.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            // The anchor owns ONLY `showTooltip`; the tooltip loads its own
            // details. Keeping the async fetch out of the anchor is what stops
            // the first-hover flicker — a `details` update here would re-render
            // the anchor and blink the popover's `isPresented` binding.
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                isHovering = hovering
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard !Task.isCancelled, isHovering else { return }
                        showTooltip = true
                    }
                } else {
                    showTooltip = false
                }
            }
            .tooltipPopover(isPresented: $showTooltip, arrowEdge: .top) {
                CastTooltip(person: person, tmdbKey: configStore.tmdbApiKey)
            }
            #else
            .help(Text(verbatim: person.name))
            #endif
        } else {
            tile
        }
    }
}

#if os(macOS)
/// Hover card for a cast head. Instant layer (headshot, name, role) plus a
/// lazily-fetched layer (age · birthplace, biography). One TMDB call, cached
/// in `PersonStore`.
private struct CastTooltip: View {
    let person: CastMember
    let tmdbKey: String
    /// Loaded HERE, not by the anchor — see the anchor's onHover note. This
    /// re-renders only the popover content when the fetch lands, so the
    /// anchor's `isPresented` binding never blinks.
    @State private var details: TMDBPersonDetails?
    @State private var loaded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemotePoster(
                url: person.imageURL, apiKey: nil, tier: .card,
                size: CGSize(width: 72, height: 72), cornerRadius: 36,
                fallbackSymbol: "person.fill"
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(person.name).scaledFont(size: 13, weight: .semibold).lineLimit(2)
                if let role = person.role, !role.isEmpty {
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("person.asCharacter", bundle: .module, comment: ""), role))
                        .scaledFont(size: 11).foregroundStyle(.secondary).lineLimit(1)
                }
                if let sub = ageBirthplace {
                    Text(sub).scaledFont(size: 11).foregroundStyle(.secondary).lineLimit(2)
                }
                if let bio = details?.biography, !bio.isEmpty {
                    Text(bio).scaledFont(size: 11).foregroundStyle(.primary.opacity(0.9))
                        .lineLimit(4).fixedSize(horizontal: false, vertical: true).padding(.top, 1)
                } else if !loaded {
                    SkeletonLines(count: 2).padding(.top, 1)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        // FIXED size — the async details (age · birthplace + bio) land after
        // the popover is already up, and letting the card grow to fit them made
        // NSPopover re-lay-out, which read as a flicker. A fixed box absorbs the
        // fill-in with no resize; the header sits top-left and the detail lines
        // populate the reserved space.
        .frame(width: 320, height: 148, alignment: .topLeading)
        .task {
            guard !loaded, let id = person.tmdbPersonId else { return }
            details = await PersonStore.shared.details(personId: id, tmdbKey: tmdbKey)
            loaded = true
        }
    }

    private var ageBirthplace: String? {
        guard let details else { return nil }
        var bits: [String] = []
        if let age = details.age {
            bits.append(String.localizedStringWithFormat(
                NSLocalizedString("person.ageYears", bundle: .module, comment: ""), age))
        }
        if let place = details.placeOfBirth, !place.isEmpty { bits.append(place) }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }
}
#endif

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
                    imageURL: c.headshotURL,
                    tmdbPersonId: c.personTmdbId
                )
            }
    }

    /// TMDB credits → cast members (used for series, which have no Radarr-style
    /// `/credit` endpoint).
    static func from(tmdbCast cast: [TMDBCreditPerson]) -> [CastMember] {
        cast.map { p in
            CastMember(id: "tmdb-\(p.id)", name: p.name, role: p.character,
                       imageURL: p.posterURL, tmdbPersonId: p.id)
        }
    }
}
