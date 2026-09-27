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
struct MonitorBookmark: View {
    let isMonitored: Bool
    var size: CGFloat

    init(isMonitored: Bool, size: CGFloat = 10) {
        self.isMonitored = isMonitored
        self.size = size
    }

    var body: some View {
        Image(systemName: isMonitored ? "bookmark.fill" : "bookmark")
            .scaledFont(size: size, weight: .medium)
            .foregroundStyle(isMonitored ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
    }
}

/// Detail-header variant: the same toggle pinned to the poster's top-LEFT
/// corner, over the artwork, so the monitored flag sits on the thing it
/// describes instead of in a row of chrome — and in the same corner as the
/// watched wedge, which is the one place both marks now live.
///
/// Drawn as `MonitorRibbon`, flush with the artwork's top edge. Artwork is
/// arbitrary — a black poster and a white one both happen — so the mark can't
/// rely on the material underneath; the ribbon's own shadows do that job (see
/// `MonitorRibbon`).
struct MonitorPosterToggle: View {
    let isMonitored: Bool
    let entity: MonitorEntity
    let onToggle: ((Bool) async -> Void)?

    @State private var inFlight = false

    init(isMonitored: Bool, entity: MonitorEntity, onToggle: ((Bool) async -> Void)? = nil) {
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

    var body: some View {
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
        .padding(.leading, 5)
        .help(Text(LocalizedStringKey(helpKey), bundle: .module))
        .accessibilityLabel(Text(LocalizedStringKey(helpKey), bundle: .module))
        .accessibilityValue(
            Text(LocalizedStringKey(isMonitored ? "common.monitored.button" : "common.notMonitored.label"),
                 bundle: .module)
        )
    }

    private static let ribbonWidth: CGFloat = 12

    private var plate: some View {
        // Hit area larger than the ribbon (a 12pt strip is unhittable on a
        // phone), top-leading aligned so the mark itself stays flush with the
        // artwork's corner.
        MonitorRibbon(width: Self.ribbonWidth, filled: isMonitored)
            .frame(width: 26, height: 30, alignment: .topLeading)
            .contentShape(Rectangle())
    }
}

/// Row variant of the toggle: the same bookmark a dense list row already shows,
/// but a real button when the row's owner hands down a flip. `nil` keeps the
/// glyph inert, so a caller without a callback renders exactly what
/// `MonitorBookmark` used to.
///
/// The hit area is wider and taller than the 10pt glyph — a bookmark that size
/// is unhittable on a phone — which is why rows place this as an `.overlay`
/// rather than inline: the padding can't push the row's own layout around, and
/// the tap lands here instead of on the row's drill-in button underneath.
/// Leading-aligned inside that area so the glyph still sits exactly where the
/// row's state column starts.
struct MonitorRowToggle: View {
    let isMonitored: Bool
    let entity: MonitorEntity
    var size: CGFloat
    /// Which edge of the hit area the glyph sits on. Rows that put the toggle
    /// on their trailing edge pass `.trailing`, so the mark lands against the
    /// row's edge instead of leaving a gap that reads as a margin.
    var alignment: Alignment = .leading
    let onToggle: ((Bool) async -> Void)?

    @State private var inFlight = false

    init(isMonitored: Bool, entity: MonitorEntity, size: CGFloat = 10,
                alignment: Alignment = .leading,
                onToggle: ((Bool) async -> Void)? = nil) {
        self.isMonitored = isMonitored
        self.entity = entity
        self.size = size
        self.alignment = alignment
        self.onToggle = onToggle
    }

    private var helpKey: String {
        guard onToggle != nil else {
            return isMonitored ? "common.monitored.button" : "common.notMonitored.label"
        }
        return isMonitored ? entity.disableKey : entity.enableKey
    }

    var body: some View {
        Group {
            if let onToggle {
                Button {
                    guard !inFlight else { return }
                    Task {
                        inFlight = true
                        await onToggle(!isMonitored)
                        inFlight = false
                    }
                } label: { glyph }
                .buttonStyle(.plain)
                .disabled(inFlight)
                .opacity(inFlight ? 0.5 : 1)
                #if os(macOS)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                #endif
                .help(Text(LocalizedStringKey(helpKey), bundle: .module))
                .accessibilityLabel(Text(LocalizedStringKey(helpKey), bundle: .module))
                .accessibilityValue(
                    Text(LocalizedStringKey(isMonitored ? "common.monitored.button"
                                                        : "common.notMonitored.label"),
                         bundle: .module)
                )
            } else {
                glyph
                    // The row already speaks its monitored state as its own
                    // accessibility value — an inert glyph adds nothing.
                    .accessibilityHidden(true)
            }
        }
    }

    private var glyph: some View {
        MonitorBookmark(isMonitored: isMonitored, size: size)
            .frame(width: 16, height: 20, alignment: alignment)
            .contentShape(Rectangle())
    }
}
