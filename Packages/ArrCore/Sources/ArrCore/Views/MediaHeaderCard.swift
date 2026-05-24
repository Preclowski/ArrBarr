import SwiftUI

// MARK: - Media header card
//
// Pulled out of MediaDetailComponents.swift — this single chrome
// component is used by every detail surface (movie / series / album
// detail, search-add panel). Owning its own file means the visual
// language can evolve without thumbing through a 1700-line file.

public struct RatingChip {
    let label: String
    let value: String
    let color: Color

    public init(label: String, value: String, color: Color) {
        self.label = label
        self.value = value
        self.color = color
    }
}

/// Shared header card used by the queue detail view, the search add
/// panel, and any other "what is this thing?" surface. Right column
/// scales by what's provided — every field is optional, callers pass
/// only the data their source can supply.
public struct MediaHeaderCard: View {
    let title: String
    var subtitle: String?
    var year: Int?
    var runtime: Int?
    var network: String?
    var certification: String?
    var genres: [String]
    var ratings: [RatingChip]
    let posterURL: URL?
    var posterRequiresAuth: Bool
    var apiKey: String?
    var fallbackSymbol: String
    var posterAspect: CGFloat
    var blurred: Bool
    var trailing: AnyView?
    /// Small tag rendered inline next to the title — e.g. an
    /// "Upgrade" pill. Used to float standalone beneath the rating
    /// chips before; pinned to the title now so it has a clear
    /// referent.
    var titleBadge: AnyView?
    /// Optional poster-tap handler — when present, the poster is
    /// wrapped in a button that fires this closure with its URL,
    /// letting the host raise a lightbox.
    var onPosterTap: ((URL?) -> Void)?

    public init(
        title: String,
        subtitle: String? = nil,
        year: Int? = nil,
        runtime: Int? = nil,
        network: String? = nil,
        certification: String? = nil,
        genres: [String] = [],
        ratings: [RatingChip] = [],
        posterURL: URL?,
        posterRequiresAuth: Bool = false,
        apiKey: String? = nil,
        fallbackSymbol: String = "film",
        posterAspect: CGFloat = 2.0/3.0,
        blurred: Bool = false,
        trailing: AnyView? = nil,
        titleBadge: AnyView? = nil,
        onPosterTap: ((URL?) -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.year = year
        self.runtime = runtime
        self.network = network
        self.certification = certification
        self.genres = genres
        self.ratings = ratings
        self.posterURL = posterURL
        self.posterRequiresAuth = posterRequiresAuth
        self.apiKey = apiKey
        self.fallbackSymbol = fallbackSymbol
        self.posterAspect = posterAspect
        self.blurred = blurred
        self.trailing = trailing
        self.titleBadge = titleBadge
        self.onPosterTap = onPosterTap
    }

    public var body: some View {
        let posterWidth: CGFloat = 110
        let posterHeight = posterWidth / posterAspect
        HStack(alignment: .top, spacing: 12) {
            posterView(width: posterWidth, height: posterHeight)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    titleWithYear
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(3)
                    if let titleBadge {
                        titleBadge
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if hasMetadataStrip {
                    metadataStrip
                        .font(.system(size: 11))
                }
                if !genres.isEmpty {
                    GenreChips(genres: genres)
                }
                if !ratings.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(ratings, id: \.label) { RatingPill(chip: $0) }
                    }
                    .padding(.top, 2)
                }
                if let trailing {
                    trailing
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var titleWithYear: Text {
        if let year {
            return Text(verbatim: "\(title) (\(year))")
        }
        return Text(verbatim: title)
    }

    private var hasMetadataStrip: Bool {
        (runtime ?? 0) > 0
            || (network.map { !$0.isEmpty } ?? false)
            || (certification.map { !$0.isEmpty } ?? false)
    }

    @ViewBuilder
    private func posterView(width: CGFloat, height: CGFloat) -> some View {
        let poster = PosterBlurContainer(blurred: blurred, cornerRadius: 6) {
            RemotePoster(
                url: posterURL,
                apiKey: posterRequiresAuth ? apiKey : nil,
                size: CGSize(width: width, height: height),
                cornerRadius: 6,
                fallbackSymbol: fallbackSymbol
            )
        }
        if let onPosterTap {
            Button { onPosterTap(posterURL) } label: { poster }
                .buttonStyle(.plain)
                .help(Text("Show poster", bundle: .module))
        } else {
            poster
        }
    }

    /// Metadata dots row — runtime · network · certification.
    @ViewBuilder
    private var metadataStrip: some View {
        HStack(spacing: 6) {
            let segments: [String] = [
                (runtime ?? 0) > 0 ? "\(runtime!) min" : nil,
                network.flatMap { $0.isEmpty ? nil : $0 },
                certification.flatMap { $0.isEmpty ? nil : $0 },
            ].compactMap { $0 }
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                if idx > 0 { Text("·").foregroundStyle(.tertiary) }
                Text(segment).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Poster lightbox
//
// Shared full-popover poster preview. Used by every detail surface
// that wants tap-to-enlarge on its poster — `DetailView`,
// `SearchAddPanel`, etc. Lifted out of `DetailView` so the chrome
// (frosted scrim, GeometryReader-fit poster, Apple-style xmark
// dismiss, tap-anywhere-to-close) lives in exactly one place.

public struct PosterLightbox: View {
    let url: URL
    var apiKey: String?
    /// Width / height ratio of the underlying art. Movie / series
    /// posters are 2:3 (≈0.667), album art is 1:1 (1.0). Hardcoding
    /// 2:3 made Lidarr lightboxes render too tall.
    var aspectRatio: CGFloat
    let onDismiss: () -> Void

    public init(
        url: URL,
        apiKey: String? = nil,
        aspectRatio: CGFloat = 2.0 / 3.0,
        onDismiss: @escaping () -> Void
    ) {
        self.url = url
        self.apiKey = apiKey
        self.aspectRatio = aspectRatio
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            // Frosted-glass scrim — `.regularMaterial` blurs the
            // popover chrome underneath without going solid black.
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            // Poster scales to fit the available popover space
            // (24 / 48pt margins) while respecting `aspectRatio`.
            GeometryReader { geo in
                let maxW = geo.size.width - 48
                let maxH = geo.size.height - 96
                let posterW = min(maxW, maxH * aspectRatio)
                let posterH = posterW / aspectRatio
                RemotePoster(
                    url: url,
                    apiKey: apiKey,
                    size: CGSize(width: posterW, height: posterH),
                    cornerRadius: 10,
                    fallbackSymbol: "photo"
                )
                .frame(width: posterW, height: posterH)
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }

            // Apple-style xmark — explicit affordance for keyboard
            // users (Esc shortcut) and people who don't realise the
            // scrim is tappable. Apple Photos / Quick Look / App
            // Store screenshots all keep one.
            // Bare xmark + soft shadow — Quick Look / Photos style.
            // Previous filled-circle treatment read as a chip / pill,
            // which is too noisy for a dismiss affordance sitting on
            // top of the user's content. The shadow keeps it legible
            // against both bright and dark posters without painting a
            // pill behind it.
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.trailing, 12)
            .help(Text("Close", bundle: .module))
            .keyboardShortcut(.cancelAction)
        }
    }
}

/// Coloured capsule for a rating value (IMDb, RT, MC, …).
struct RatingPill: View {
    let chip: RatingChip
    public var body: some View {
        HStack(spacing: 3) {
            Text(chip.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(chip.color)
            Text(chip.value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(chip.color.opacity(0.15), in: Capsule())
    }
}
