import SwiftUI

/// Navigation payload for a cast/crew head — everything the person page
/// needs without refetching who they are.
public struct PersonRef: Hashable, Sendable {
    public let id: Int
    public let name: String
}

/// One half of a person's filmography, shown whole — where the "Movies ›" /
/// "Series ›" chevron on the person page leads.
public struct PersonCreditsRef: Hashable, Sendable {
    public let person: PersonRef
    public let type: MediaType
}

/// A person page in the Apple TV mold: blurred backdrop marquee, big photo,
/// bio and facts, filmography split into movie and series shelves.
struct PersonView: View {
    let person: PersonRef
    @EnvironmentObject private var config: TonightConfig

    @State private var details: PersonDetails?
    @State private var error: String?
    @State private var bioExpanded = false
    /// Bio height with and without the 7-line clamp — the gap is what the
    /// More button is for.
    @State private var fullBioHeight: CGFloat = 0
    @State private var clampedBioHeight: CGFloat = 0
    @State private var showPhoto = false

    /// How many credits a filmography row shows before the chevron.
    private let rowLimit = 10

    var body: some View {
        Group {
            if let details {
                loaded(details)
            } else if let error {
                QuietMessage(systemImage: "wifi.slash",
                             title: String(localized: "Can't reach TMDB", bundle: .module),
                             subtitle: error,
                             action: (String(localized: "Retry", bundle: .module),
                                      { Task { await load() } }))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .floatingBackButton()
        .task(id: person.id) { await load() }
        .sheet(isPresented: $showPhoto) {
            PosterLightbox(url: details?.profilePath.flatMap {
                URL(string: "https://image.tmdb.org/t/p/w780\($0)")
            }, title: person.name)
        }
    }

    /// One filmography row: the ten most popular credits, with the headline
    /// as the way into the whole, filterable collection.
    private func creditsRow(_ key: LocalizedStringKey, type: MediaType,
                            items: [MediaItem], roles: [String: String]) -> some View {
        let shown = Array(items.prefix(rowLimit))
        return VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: PersonCreditsRef(person: person, type: type)) {
                HStack(spacing: 5) {
                    Text(key, bundle: .module)
                        .font(.title3.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if items.count > shown.count {
                        Text(String(items.count))
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(shown) { item in
                        PosterCard(item: item, width: 150, siblings: shown,
                                   subtitle: roles[item.id])
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 10) // room for the hover lift shadow
            }
            .scrollClipDisabled()
        }
    }

    private func load() async {
        error = nil
        let tmdb = TMDBService(apiKey: config.tmdbApiKey, region: config.watchRegion)
        do {
            details = try await tmdb.person(personId: person.id)
        } catch {
            self.error = shortDescription(of: error)
        }
    }

    private func loaded(_ d: PersonDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header(d)
                if !d.movies.isEmpty {
                    creditsRow("Movies", type: .movie, items: d.movies, roles: d.roles)
                }
                if !d.shows.isEmpty {
                    creditsRow("Series", type: .tv, items: d.shows, roles: d.roles)
                }
            }
            .padding(.bottom, 40)
        }
    }

    /// People get no marquee at all — a credit's backdrop reads as the wrong
    /// movie's artwork. Just the portrait and the facts on the plain page.
    private func header(_ d: PersonDetails) -> some View {
        headerContent(d)
            // Clear of the traffic lights AND of the floating back button,
            // which sits in the same lane as the portrait.
            .padding(.top, titleBarHeight + 14)
    }

    private func headerContent(_ d: PersonDetails) -> some View {
            HStack(alignment: .top, spacing: 24) {
                RemoteImage(url: d.photoURL)
                    .frame(width: 170, height: 255)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                    .layoutPriority(1)
                    .onTapGesture { showPhoto = true }
                    .pointerStyle(.zoomIn)

                VStack(alignment: .leading, spacing: 8) {
                    Text(d.name)
                        .font(.system(size: 36, weight: .bold))
                    if let facts = factsLine(d) {
                        Text(facts)
                            .font(.callout.weight(.medium))
                            .opacity(0.9)
                    }
                    Text(String(format: String(localized: "%d titles", bundle: .module),
                                d.movies.count + d.shows.count))
                        .font(.callout)
                        .opacity(0.75)
                    if let biography = d.biography {
                        biographyText(biography)
                            .padding(.top, 10)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.primary)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
    }

    /// "Actor · Born 1974, Berlin · Died 2020" — only what's known.
    private func factsLine(_ d: PersonDetails) -> String? {
        var parts: [String] = []
        if let department = d.knownForDepartment { parts.append(department) }
        if let birthday = d.birthday, birthday.count >= 4 {
            var born = "\(String(localized: "Born", bundle: .module)) \(birthday.prefix(4))"
            if let place = d.placeOfBirth {
                born += ", \(place)"
            }
            parts.append(born)
        }
        if let deathday = d.deathday, deathday.count >= 4 {
            parts.append("\(String(localized: "Died", bundle: .module)) \(deathday.prefix(4))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The bio, clamped to 7 lines — with More/Less only when there is
    /// actually something hidden. A three-word biography gets no button.
    private func biographyText(_ biography: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(biography)
                .font(.body)
                .lineSpacing(3)
                .lineLimit(bioExpanded ? nil : 7)
                .frame(maxWidth: 720, alignment: .leading)
                .background(alignment: .top) {
                    // The same text with no limit, laid out invisibly at the
                    // same width: taller than the clamped one means the
                    // clamp is hiding lines.
                    Text(biography)
                        .font(.body)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { full in
                            fullBioHeight = full
                        }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shown in
                    if !bioExpanded { clampedBioHeight = shown }
                }
            if fullBioHeight > clampedBioHeight + 1 {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { bioExpanded.toggle() }
                } label: {
                    bioExpanded ? Text("Less", bundle: .module) : Text("More", bundle: .module)
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// A person's whole filmography for one media type, as a customizable
/// collection (posters or list) — the destination of the person page's
/// "Movies ›" / "Series ›" chevrons.
struct PersonCreditsView: View {
    let ref: PersonCreditsRef
    @EnvironmentObject private var config: TonightConfig

    @State private var items: [MediaItem] = []
    @State private var error: String?
    @State private var loading = true

    private var spec: MediaCollectionSpec { .personCredits(ref.type) }

    var body: some View {
        MediaCollectionView(spec, items: items, loading: loading)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 10) {
                    BackButton()
                    Text(ref.person.name).font(.headline)
                    Text(ref.type == .movie ? "Movies" : "Series", bundle: .module)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    QuizThisControl(spec, items: items, name: ref.person.name)
                    CollectionSortMenu(spec)
                    MediaLayoutPicker(spec)
                }
                .padding(.horizontal, 28)
                .padding(.top, pageChromeTop)
                .padding(.bottom, 10)
                .background(.bar)
            }
            .overlay {
                if items.isEmpty {
                    if loading {
                        ProgressView()
                    } else if let error {
                        QuietMessage(systemImage: "wifi.slash",
                                     title: String(localized: "Can't reach TMDB", bundle: .module),
                                     subtitle: error,
                                     action: (String(localized: "Retry", bundle: .module),
                                              { Task { await load() } }))
                    }
                }
            }
            .pushedPage()
            .task(id: ref) { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        let tmdb = TMDBService(apiKey: config.tmdbApiKey, region: config.watchRegion)
        do {
            let details = try await tmdb.person(personId: ref.person.id)
            items = ref.type == .movie ? details.movies : details.shows
        } catch {
            self.error = shortDescription(of: error)
        }
    }
}

/// Items of a public TMDB list — the Lists row on Discover, and a title's
/// own "featured in" links. The ordinary library view, with the list's name
/// in the header strip.
struct TMDBListView: View {
    let list: TMDBListRef
    @EnvironmentObject private var config: TonightConfig

    @State private var items: [MediaItem] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        MediaCollectionView(.tmdbList, items: items, loading: loading)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 10) {
                    BackButton()
                    Text(list.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(String(format: String(localized: "%d titles", bundle: .module),
                                list.itemCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    QuizThisControl(.tmdbList, items: items, name: list.name)
                    CollectionSortMenu(.tmdbList)
                    MediaLayoutPicker(.tmdbList)
                }
                .padding(.horizontal, 28)
                .padding(.top, pageChromeTop)
                .padding(.bottom, 10)
                .background(.bar)
            }
        .overlay {
            if loading && items.isEmpty {
                ProgressView()
            } else if let error, items.isEmpty {
                QuietMessage(systemImage: "wifi.slash",
                             title: String(localized: "Can't reach TMDB", bundle: .module),
                             subtitle: error,
                             action: (String(localized: "Retry", bundle: .module),
                                      { Task { await load() } }))
            }
        }
        .pushedPage()
        .task(id: list.id) { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        let tmdb = TMDBService(apiKey: config.tmdbApiKey, region: config.watchRegion)
        do {
            items = try await tmdb.listItems(listId: list.id)
        } catch {
            self.error = shortDescription(of: error)
        }
    }
}
