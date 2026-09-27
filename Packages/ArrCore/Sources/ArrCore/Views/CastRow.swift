import SwiftUI
import MediaKit

/// Movies map from Radarr's `/credit` (no TMDB key needed); series from TMDB credits.
nonisolated public struct CastMember: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let role: String?
    public let imageURL: URL?
    /// Both providers carry it, so a tile can open the person with no extra call. nil = inert tile.
    public let tmdbPersonId: Int?

    public init(id: String, name: String, role: String?, imageURL: URL?, tmdbPersonId: Int? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.imageURL = imageURL
        self.tmdbPersonId = tmdbPersonId
    }
}

struct CastRow: View {
    let cast: [CastMember]
    var limit: Int = 16
    /// nil (no host to push into) leaves heads inert.
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

/// Shared with the Quiz card, which shows the same credit in the same slot.
struct DirectedByLine: View {
    let people: [CastMember]
    var labelKey: LocalizedStringKey = "detail.directedBy.label"
    /// Plain text in the Quiz deck, where a card is a swipe target.
    var onTapPerson: ((CastMember) -> Void)? = nil

    var body: some View {
        if !people.isEmpty {
            HStack(spacing: 4) {
                Text(labelKey, bundle: .module)
                    .foregroundStyle(.secondary)
                ForEach(Array(people.prefix(2).enumerated()), id: \.element.id) { idx, person in
                    if idx > 0 {
                        Text(verbatim: "&").foregroundStyle(.secondary)
                    }
                    creditName(person)
                }
                Spacer(minLength: 0)
            }
            .scaledFont(size: 11)
        }
    }

    /// An id-less credit has no page to open, so it stays plain text.
    @ViewBuilder
    private func creditName(_ person: CastMember) -> some View {
        if let onTapPerson, person.tmdbPersonId != nil {
            Button { onTapPerson(person) } label: {
                HStack(spacing: 2) {
                    Text(verbatim: person.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    LinkChevron(size: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            #endif
        } else {
            Text(verbatim: person.name)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// The 600 ms hover gate keeps a sweep across the strip from fetching per head.
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
            // The anchor owns only `showTooltip`: a fetch landing here would re-render it
            // and blink the popover's `isPresented` binding.
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                isHovering = hovering
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task {
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
private struct CastTooltip: View {
    let person: CastMember
    let tmdbKey: String
    /// Loaded here, not in the anchor, so the anchor's `isPresented` never blinks.
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
                    Text(bio).scaledFont(size: 11).foregroundStyle(.primary)
                        .lineLimit(4).fixedSize(horizontal: false, vertical: true).padding(.top, 1)
                } else if !loaded {
                    SkeletonLines(count: 2).padding(.top, 1)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        // Fixed size: growing to fit the late details made NSPopover re-lay-out, which flickers.
        .frame(width: 320, height: 148, alignment: .topLeading)
        .task {
            guard !loaded, let id = person.tmdbPersonId else { return }
            details = try? await People.details(personId: id, tmdbKey: tmdbKey)
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

nonisolated extension CastMember {
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

    /// Series have no Radarr-style `/credit` endpoint.
    static func from(tmdbCast cast: [TMDBPerson]) -> [CastMember] {
        cast.map { p in
            CastMember(id: "tmdb-\(p.id)", name: p.name, role: p.characterName,
                       imageURL: p.profileURL, tmdbPersonId: p.id)
        }
    }

    /// Radarr mirrors TMDB's crew rows; a person credited twice appears once.
    static func directors(radarrCredits credits: [ArrCredit]) -> [CastMember] {
        dedupe(credits
            .filter { ($0.type ?? "").lowercased() == "crew" && isDirecting(department: $0.department, job: $0.job) }
            .compactMap { c in
                guard let name = c.personName, !name.isEmpty else { return nil }
                return CastMember(
                    id: "dir-\(c.personTmdbId ?? 0)-\(name)",
                    name: name,
                    role: jobLabel(c.job),
                    imageURL: c.headshotURL,
                    tmdbPersonId: c.personTmdbId
                )
            })
    }

    static func directors(tmdbCrew crew: [TMDBPerson]) -> [CastMember] {
        dedupe(crew
            .filter { isDirecting(department: $0.department, job: $0.job) }
            .map { p in
                CastMember(id: "dir-tmdb-\(p.id)", name: p.name, role: jobLabel(p.job),
                           imageURL: p.profileURL, tmdbPersonId: p.id)
            })
    }

    /// `created_by` carries no job field; being listed is the credit.
    static func from(tmdbCreators creators: [TMDBPerson]) -> [CastMember] {
        dedupe(creators.map { p in
            CastMember(id: "creator-tmdb-\(p.id)", name: p.name, role: nil,
                       imageURL: p.profileURL, tmdbPersonId: p.id)
        })
    }

    /// The job token, not the department, which would include assistant directors and script supervisors.
    private static func isDirecting(department: String?, job: String?) -> Bool {
        guard department == nil || department == TMDBDepartment.directing else { return false }
        return job == TMDBDepartment.directorJob || job == TMDBDepartment.coDirectorJob
    }

    /// Plain "Director" repeats the header, so only variants show. TMDB job tokens are fixed English.
    private static func jobLabel(_ job: String?) -> String? {
        guard let job, !job.isEmpty, job != TMDBDepartment.directorJob else { return nil }
        return job
    }

    /// Radarr repeats the row per job variant, which would duplicate the head and break ForEach identity.
    private static func dedupe(_ members: [CastMember]) -> [CastMember] {
        var seen = Set<String>()
        return members.filter { seen.insert($0.tmdbPersonId.map(String.init) ?? $0.name).inserted }
    }
}
