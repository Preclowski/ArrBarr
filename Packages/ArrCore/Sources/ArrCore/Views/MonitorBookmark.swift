import SwiftUI

// MARK: - Monitored-state bookmark
//
// The *arr web UIs mark every monitorable entity with a bookmark glyph —
// filled when monitored, outline when not. ArrBarr mirrors that language
// across all six entities (movie / series / season / episode / artist /
// album) so the two apps read the same.
//
// Two components, one visual vocabulary:
//   • `MonitorBookmark`     — inert glyph for list rows (state only).
//   • `MonitorPosterToggle` — the interactive one, on the detail hero's
//                             poster corner (see `DetailHeroPoster`).
//
// Deliberately NOT wired to any search: flipping the bookmark flips the
// flag and nothing else. (The chat / MCP tool path always searches after
// monitoring — see `LocalToolBackend+ArrTools`. That's a chat idiom, not
// a UI one; a bookmark that silently starts grabbing releases would be a
// nasty surprise.) Searching stays on the explicit CTAs.

/// Which entity a bookmark refers to. Only drives help / VoiceOver copy —
/// the glyph itself is identical everywhere.
public enum MonitorEntity: Sendable {
    case movie, series, season, episode, artist, album

    /// Help + accessibility text for the action the toggle would perform.
    /// A glyph button announces its *verb*, so a monitored entity reads
    /// "Stop monitoring this season", not "Monitored".
    var enableKey: String {
        switch self {
        case .movie:   return "detail.monitorThisMovie.button"
        case .series:  return "detail.monitorThisSeries.button"
        case .season:  return "detail.monitorThisSeason.button"
        case .episode: return "detail.monitorThisEpisode.button"
        case .artist:  return "detail.monitorThisArtist.button"
        case .album:   return "detail.monitorThisAlbum.button"
        }
    }

    var disableKey: String {
        switch self {
        case .movie:   return "detail.stopMonitoringThisMovie.button"
        case .series:  return "detail.stopMonitoringThisSeries.button"
        case .season:  return "detail.stopMonitoringThisSeason.label"
        case .episode: return "detail.stopMonitoringThisEpisode.button"
        case .artist:  return "detail.stopMonitoringThisArtist.button"
        case .album:   return "detail.stopMonitoringThisAlbum.button"
        }
    }
}

/// Inert state glyph for list rows. No hit area, no hover, no button —
/// the row it sits in owns the tap. Rows pair it with a dimmed label so
/// "unmonitored" reads at a glance without hunting for a 10pt icon.
public struct MonitorBookmark: View {
    let isMonitored: Bool
    var size: CGFloat

    public init(isMonitored: Bool, size: CGFloat = 10) {
        self.isMonitored = isMonitored
        self.size = size
    }

    public var body: some View {
        Image(systemName: isMonitored ? "bookmark.fill" : "bookmark")
            .scaledFont(size: size, weight: .medium)
            .foregroundStyle(isMonitored ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
    }
}

/// Detail-header variant: the same toggle pinned to the poster's top-right
/// corner, over the artwork, so the monitored flag sits on the thing it
/// describes instead of in a row of chrome.
///
/// Artwork is arbitrary — a black poster and a white one both happen — so the
/// glyph can't rely on the material underneath. No plate behind it (a chip in
/// the corner reads as chrome bolted onto the art); contrast comes from the
/// mark itself: white body, with a tight black halo plus a softer spread under
/// it. The halo is what draws it on a white poster, the white body is what
/// draws it on a black one. Same trick as `TrailerPosterBadge`, which is bare
/// on the artwork for the same reason.
public struct MonitorPosterToggle: View {
    let isMonitored: Bool
    let entity: MonitorEntity
    let onToggle: ((Bool) async -> Void)?

    @State private var inFlight = false

    public init(isMonitored: Bool, entity: MonitorEntity, onToggle: ((Bool) async -> Void)? = nil) {
        self.isMonitored = isMonitored
        self.entity = entity
        self.onToggle = onToggle
    }

    private var helpKey: String {
        guard onToggle != nil else {
            return isMonitored ? "common.monitored.button" : "common.notMonitored.label"
        }
        return isMonitored ? entity.disableKey : entity.enableKey
    }

    public var body: some View {
        Group {
            if let onToggle {
                Button {
                    guard !inFlight else { return }
                    Task {
                        inFlight = true
                        await onToggle(!isMonitored)
                        inFlight = false
                    }
                } label: { plate }
                .buttonStyle(.plain)
                .disabled(inFlight)
                .opacity(inFlight ? 0.5 : 1)
                #if os(macOS)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                #endif
            } else {
                plate
            }
        }
        .padding(6)
        .help(Text(LocalizedStringKey(helpKey), bundle: .module))
        .accessibilityLabel(Text(LocalizedStringKey(helpKey), bundle: .module))
        .accessibilityValue(
            Text(LocalizedStringKey(isMonitored ? "common.monitored.button" : "common.notMonitored.label"),
                 bundle: .module)
        )
    }

    private var plate: some View {
        Image(systemName: isMonitored ? "bookmark.fill" : "bookmark")
            .scaledFont(size: 14, weight: .semibold)
            .foregroundStyle(.white)
            // Two passes: the tight one is the outline that keeps the glyph
            // off a white poster, the soft one lifts it off a busy one.
            .shadow(color: .black.opacity(0.75), radius: 1)
            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            // Unmonitored sits back a touch — still legible, clearly the
            // "off" state next to the solid filled glyph.
            .opacity(isMonitored ? 1 : 0.85)
            // Trailing-aligned inside the hit area: a bookmark is far narrower
            // than the 22pt square, so centering it left the mark ~6pt shy of
            // the trailer badge's right edge below. The glyph now sits flush
            // against the padding, matching that badge's 6pt inset; the hit
            // area still extends left of it.
            .frame(width: 22, height: 22, alignment: .trailing)
            .contentShape(Rectangle())
    }
}
