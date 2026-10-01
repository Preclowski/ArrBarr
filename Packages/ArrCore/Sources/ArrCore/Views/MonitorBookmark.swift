import SwiftUI

// MARK: - Monitored-state bookmark
//
// Deliberately not wired to any search: a bookmark that silently starts grabbing releases would be a nasty surprise.
// (The chat / MCP tools search after monitoring; that's a chat idiom.)

/// Only drives help / VoiceOver copy.
enum MonitorEntity: Sendable {
    case movie, series, season, episode, artist, album

    /// A glyph button announces its verb: "Stop monitoring this season", not "Monitored".
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

/// Inert: the row owns the tap.
struct MonitorBookmark: View {
    let isMonitored: Bool
    var size: CGFloat
    /// Hover on a toggle: the glyph grows and previews the state a click sets.
    var hovering = false

    init(isMonitored: Bool, size: CGFloat = 10, hovering: Bool = false) {
        self.isMonitored = isMonitored
        self.size = size
        self.hovering = hovering
    }

    private var showsFilled: Bool { hovering ? !isMonitored : isMonitored }

    var body: some View {
        Image(systemName: showsFilled ? "bookmark.fill" : "bookmark")
            .scaledFont(size: size, weight: .medium)
            .foregroundStyle(hovering ? AnyShapeStyle(.primary)
                             : isMonitored ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .scaleEffect(hovering ? 1.25 : 1)
    }
}

extension Animation {
    /// The bookmark and ribbon hover.
    static let monitorHover: Animation = .spring(duration: 0.25, bounce: 0.35)
}

/// Pinned to the poster's top-leading corner as `MonitorRibbon`; the ribbon's shadows keep it readable
/// on any artwork.
struct MonitorPosterToggle: View {
    let isMonitored: Bool
    let entity: MonitorEntity
    let onToggle: ((Bool) async -> Void)?

    @State private var inFlight = false
    @State private var hovering = false
    /// Set by a click, cleared on exit: the pointer still over it must not preview the old state back.
    @State private var toggledUnderPointer = false

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
                        toggledUnderPointer = true
                    }
                } label: { plate }
                .buttonStyle(.plain)
                .disabled(inFlight)
                .opacity(inFlight ? 0.5 : 1)
                .onHover { over in
                    withAnimation(.monitorHover) { hovering = over }
                    if !over { toggledUnderPointer = false }
                }
                #if os(macOS)
                .pointerStyle(.link)
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
        // Larger than the ribbon (a 12pt strip is unhittable on a phone), top-leading so the mark stays flush.
        MonitorRibbon(width: Self.ribbonWidth, filled: isMonitored, hovering: hovering && !inFlight && !toggledUnderPointer)
            .frame(width: 26, height: 30, alignment: .topLeading)
            .contentShape(Rectangle())
    }
}

/// An `.overlay`, not inline: the enlarged hit area around the 10pt glyph mustn't push the row's layout,
/// and the tap must land here rather than on the row's drill-in button.
struct MonitorRowToggle: View {
    let isMonitored: Bool
    let entity: MonitorEntity
    var size: CGFloat
    var alignment: Alignment = .leading
    let onToggle: ((Bool) async -> Void)?

    @State private var inFlight = false
    @State private var hovering = false
    /// Set by a click, cleared on exit: the pointer still over it must not preview the old state back.
    @State private var toggledUnderPointer = false

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
                        toggledUnderPointer = true
                    }
                } label: { glyph }
                .buttonStyle(.plain)
                .disabled(inFlight)
                .opacity(inFlight ? 0.5 : 1)
                .onHover { over in
                    withAnimation(.monitorHover) { hovering = over }
                    if !over { toggledUnderPointer = false }
                }
                #if os(macOS)
                .pointerStyle(.link)
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
                    // The row already speaks its monitored state as its accessibility value.
                    .accessibilityHidden(true)
            }
        }
    }

    private var glyph: some View {
        MonitorBookmark(isMonitored: isMonitored, size: size, hovering: hovering && !inFlight && !toggledUnderPointer)
            .frame(width: 16, height: 20, alignment: alignment)
            .contentShape(Rectangle())
    }
}
