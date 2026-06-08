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
    /// Synopsis text. When present it renders in the right column
    /// beside the poster (tooltip layout) instead of below the whole
    /// card, so the description starts next to the artwork rather than
    /// under it. Wraps in an `ExpandableOverview` (4-line clamp + Show
    /// more) so a long synopsis still flows below the poster.
    var overview: String?
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
    /// Hides the title + year line. DetailView sets this when the
    /// NavigationStack toolbar carries `Title (Year)` so the hero card
    /// doesn't duplicate it. Tooltips / popovers keep the in-card title
    /// (no nav chrome there to host it).
    var showTitle: Bool = true

    public init(
        title: String,
        subtitle: String? = nil,
        year: Int? = nil,
        runtime: Int? = nil,
        network: String? = nil,
        certification: String? = nil,
        genres: [String] = [],
        ratings: [RatingChip] = [],
        overview: String? = nil,
        posterURL: URL?,
        posterRequiresAuth: Bool = false,
        apiKey: String? = nil,
        fallbackSymbol: String = "film",
        posterAspect: CGFloat = 2.0/3.0,
        blurred: Bool = false,
        trailing: AnyView? = nil,
        titleBadge: AnyView? = nil,
        onPosterTap: ((URL?) -> Void)? = nil,
        showTitle: Bool = true
    ) {
        self.title = title
        self.subtitle = subtitle
        self.year = year
        self.runtime = runtime
        self.network = network
        self.certification = certification
        self.genres = genres
        self.ratings = ratings
        self.overview = overview
        self.posterURL = posterURL
        self.posterRequiresAuth = posterRequiresAuth
        self.apiKey = apiKey
        self.fallbackSymbol = fallbackSymbol
        self.posterAspect = posterAspect
        self.blurred = blurred
        self.trailing = trailing
        self.titleBadge = titleBadge
        self.onPosterTap = onPosterTap
        self.showTitle = showTitle
    }

    public var body: some View {
        let posterWidth: CGFloat = 110
        let posterHeight = posterWidth / posterAspect
        HStack(alignment: .top, spacing: 12) {
            posterView(width: posterWidth, height: posterHeight)
            VStack(alignment: .leading, spacing: 4) {
                if showTitle {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        titleWithYear
                            .scaledFont(size: 15, weight: .semibold)
                            .lineLimit(3)
                        if let titleBadge {
                            titleBadge
                        }
                    }
                } else if let titleBadge {
                    // Badge still has a home — pulled out of the title row
                    // and floated above the metadata so it doesn't get
                    // lost when the title moves to the nav bar.
                    titleBadge
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                if !genres.isEmpty {
                    GenreChips(genres: genres)
                }
                // Row 1 — metadata: runtime · network · certification.
                if hasMetadataRow {
                    metadataRow
                }
                // Row 2 — ratings (IMDb / TMDB / RT / MC for movies, the
                // single Rating pill for series), on their OWN row UNDER
                // the metadata so movie + series headers read identically.
                if !ratings.isEmpty {
                    // Horizontal scroll instead of wrapping: in the narrow
                    // detail column four rating pills (IMDb/TMDB/RT/MC) would
                    // otherwise break onto a second line. The ScrollView clips
                    // to the right column (NO scrollClipDisabled) so scrolled
                    // pills hide at the column edge instead of bleeding left
                    // over the poster.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(ratings, id: \.label) { RatingPill(chip: $0) }
                        }
                    }
                }
                // Synopsis sits beside the poster (tooltip layout) so the
                // description starts next to the artwork; a long one wraps
                // down below the poster on its own.
                if let overview, !overview.isEmpty {
                    ExpandableOverview(text: overview)
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

    private var hasMetadataRow: Bool {
        (runtime ?? 0) > 0
            || (network.map { !$0.isEmpty } ?? false)
            || (certification.map { !$0.isEmpty } ?? false)
    }

    @ViewBuilder
    private func posterView(width: CGFloat, height: CGFloat) -> some View {
        let poster = PosterBlurContainer(blurred: blurred, cornerRadius: Tokens.Radius.card) {
            RemotePoster(
                url: posterURL,
                apiKey: posterRequiresAuth ? apiKey : nil,
                size: CGSize(width: width, height: height),
                cornerRadius: Tokens.Radius.card,
                fallbackSymbol: fallbackSymbol
            )
        }
        if let onPosterTap {
            Button { onPosterTap(posterURL) } label: { poster }
                .buttonStyle(.plain)
                .help(Text("Show poster", bundle: .module))
                .accessibilityLabel(Text("Show poster", bundle: .module))
        } else {
            poster
        }
    }

    /// Metadata row under the genres: runtime · network · certification
    /// (dot-joined plain text). Ratings get their own row below this.
    @ViewBuilder
    private var metadataRow: some View {
        HStack(spacing: 6) {
            let segments: [String] = [
                (runtime ?? 0) > 0 ? "\(runtime!) min" : nil,
                network.flatMap { $0.isEmpty ? nil : $0 },
                certification.flatMap { $0.isEmpty ? nil : $0 },
            ].compactMap { $0 }
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                if idx > 0 { SeparatorDot() }
                Text(segment).foregroundStyle(.secondary)
            }
        }
        .scaledFont(size: 11)
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

    /// Live zoom (1 = fit). Updated continuously during the pinch via
    /// `.onChanged` (more reliable than `@GestureState` here), clamped 1…5.
    /// `baseZoom`/`baseOffset` hold the committed value between gestures so
    /// successive pinches/drags compound instead of snapping back.
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

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
                // Tighter insets than before — the poster filled only the
                // middle of the popover with a big margin all round. Trim
                // the cushion so it reads close to full-bleed but keeps a
                // thin breathing edge.
                let maxW = geo.size.width - 28
                let maxH = geo.size.height - 48
                let posterW = min(maxW, maxH * aspectRatio)
                let posterH = posterW / aspectRatio
                RemotePoster(
                    url: url,
                    apiKey: apiKey,
                    size: CGSize(width: posterW, height: posterH),
                    cornerRadius: Tokens.Radius.panel,
                    fallbackSymbol: "photo"
                )
                .frame(width: posterW, height: posterH)
                .scaleEffect(zoom)
                .offset(offset)
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                // Pinch to zoom (iOS finger / macOS trackpad), drag to pan
                // once zoomed. `.onChanged` drives the live scale; the two
                // gestures run simultaneously so you can pinch-and-pan.
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            zoom = min(max(baseZoom * value, 1), 5)
                        }
                        .onEnded { _ in
                            baseZoom = zoom
                            if zoom <= 1.01 {
                                withAnimation(.smooth(duration: 0.2)) { offset = .zero; baseOffset = .zero }
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard zoom > 1 else { return }
                            offset = CGSize(width: baseOffset.width + value.translation.width,
                                            height: baseOffset.height + value.translation.height)
                        }
                        .onEnded { _ in baseOffset = offset }
                )
                .contentShape(Rectangle())
                // Tap: zoom back out when zoomed, otherwise dismiss.
                .onTapGesture {
                    if zoom > 1 {
                        withAnimation(.smooth(duration: 0.2)) {
                            zoom = 1; baseZoom = 1; offset = .zero; baseOffset = .zero
                        }
                    } else {
                        onDismiss()
                    }
                }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }

            // xmark dropped on both platforms — MenuBarExtra(.window)
            // gives macOS a native back chevron just like iOS, and
            // the scrim tap still covers tap-anywhere dismiss. Esc
            // keyboard shortcut moved to a hidden Button below so it
            // survives without painting a visible affordance.
            #if os(macOS)
            Button("", action: onDismiss)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            #endif
        }
    }
}

/// Coloured capsule for a rating value (IMDb, RT, MC, …).
struct RatingPill: View {
    let chip: RatingChip
    public var body: some View {
        HStack(spacing: 3) {
            Text(chip.label)
                .scaledFont(size: 9, weight: .semibold)
                .foregroundStyle(chip.color)
            Text(chip.value)
                .scaledFont(size: 10, weight: .semibold, monospacedDigit: true)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.chip).stroke(chip.color.opacity(0.30), lineWidth: 0.75))
    }
}

// MARK: - Poster lightbox presentation

public extension View {
    /// Present `PosterLightbox` truly full-screen. iOS uses `.fullScreenCover`
    /// so it covers the nav bar + tab bar (no header, no back button — dismiss
    /// by tapping the poster). macOS overlays it inside the popover.
    @ViewBuilder
    func posterLightbox(url: Binding<URL?>, apiKey: String?, aspectRatio: CGFloat) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: Binding(
            get: { url.wrappedValue != nil },
            set: { if !$0 { url.wrappedValue = nil } }
        )) {
            if let u = url.wrappedValue {
                PosterLightbox(url: u, apiKey: apiKey, aspectRatio: aspectRatio,
                               onDismiss: { url.wrappedValue = nil })
            }
        }
        #else
        overlay {
            if let u = url.wrappedValue {
                PosterLightbox(url: u, apiKey: apiKey, aspectRatio: aspectRatio,
                               onDismiss: { url.wrappedValue = nil })
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        #endif
    }
}
