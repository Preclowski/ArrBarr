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
//   • `MonitorToggleButton` — header / toolbar action with a 22pt hit
//                             area, matching `IconButton`'s chrome.
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

/// Interactive variant for the detail headers (macOS self-drawn bar) and
/// the iOS `.toolbar` cluster. Chrome is copied from `IconButton` so the
/// bookmark sits flush next to Safari / trash instead of reading as a
/// foreign control.
///
/// `onToggle == nil` renders the glyph read-only — that's how the entities
/// whose client API doesn't exist yet ship without a dead button.
public struct MonitorToggleButton: View {
    let isMonitored: Bool
    let entity: MonitorEntity
    let onToggle: ((Bool) async -> Void)?

    /// While a flip is in flight the glyph has ALREADY moved (optimistic
    /// update upstream), so a spinner here would contradict what the user
    /// is looking at. Dim + disable instead.
    @State private var inFlight = false

    public init(isMonitored: Bool, entity: MonitorEntity, onToggle: ((Bool) async -> Void)? = nil) {
        self.isMonitored = isMonitored
        self.entity = entity
        self.onToggle = onToggle
    }

    private var helpKey: String { isMonitored ? entity.disableKey : entity.enableKey }

    public var body: some View {
        if let onToggle {
            Button {
                guard !inFlight else { return }
                Task {
                    inFlight = true
                    await onToggle(!isMonitored)
                    inFlight = false
                }
            } label: {
                glyph
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(inFlight)
            .opacity(inFlight ? 0.5 : 1)
            .help(Text(LocalizedStringKey(helpKey), bundle: .module))
            .accessibilityLabel(Text(LocalizedStringKey(helpKey), bundle: .module))
            // State *and* verb: VoiceOver reads "Monitored, Stop monitoring
            // this season, button" — one pass, no ambiguity about which way
            // the toggle is pointing.
            .accessibilityValue(
                Text(LocalizedStringKey(isMonitored ? "common.monitored.button" : "common.notMonitored.label"),
                     bundle: .module)
            )
        } else {
            glyph
                .frame(width: 22, height: 22)
                .help(Text(LocalizedStringKey(isMonitored ? "common.monitored.button" : "common.notMonitored.label"),
                           bundle: .module))
                .accessibilityLabel(
                    Text(LocalizedStringKey(isMonitored ? "common.monitored.button" : "common.notMonitored.label"),
                         bundle: .module)
                )
        }
    }

    /// Header-sized glyph. Matches `IconButton`'s 13pt / `.medium` so the
    /// bookmark and the Safari glyph beside it are optically the same size.
    private var glyph: some View {
        Image(systemName: isMonitored ? "bookmark.fill" : "bookmark")
            .scaledFont(size: 13, weight: .medium)
            .foregroundStyle(Color.primary.opacity(isMonitored ? 0.72 : 0.45))
    }
}
