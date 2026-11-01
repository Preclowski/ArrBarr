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
    /// Hover on a toggle: a small lift, which must not look like the click's result.
    var hovering = false
    /// Each increment plays the click's pop.
    var pops = 0

    init(isMonitored: Bool, size: CGFloat = 10, hovering: Bool = false, pops: Int = 0) {
        self.isMonitored = isMonitored
        self.size = size
        self.hovering = hovering
        self.pops = pops
    }

    private var style: AnyShapeStyle {
        switch (isMonitored, hovering) {
        case (true, true): AnyShapeStyle(.primary)
        case (true, false), (false, true): AnyShapeStyle(.secondary)
        case (false, false): AnyShapeStyle(.tertiary)
        }
    }

    var body: some View {
        Image(systemName: isMonitored ? "bookmark.fill" : "bookmark")
            .scaledFont(size: size, weight: .medium)
            .symbolSwap()
            .foregroundStyle(style)
            .scaleEffect(hovering ? 1.1 : 1)
            .animation(.monitorHover, value: isMonitored)
            .animation(.monitorHover, value: hovering)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: pops) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(1.5, duration: 0.12)
                SpringKeyframe(1, duration: 0.35, spring: .bouncy)
            }
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
    /// Only the value a click asked for pops, not one that loaded or a failure snapping back.
    @State private var requested: Bool?
    @State private var pops = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    requested = !isMonitored
                    Task {
                        inFlight = true
                        await onToggle(!isMonitored)
                        inFlight = false
                    }
                } label: { plate }
                .buttonStyle(.plain)
                .disabled(inFlight)
                .onHover { over in
                    withAnimation(.monitorHover) { hovering = over }
                }
                #if os(macOS)
                .pointerStyle(.link)
                #endif
            } else {
                plate
            }
        }
        .onChange(of: isMonitored) { _, now in
            if now == requested, !reduceMotion { pops += 1 }
            requested = nil
        }
        .preference(key: PosterCornerHoverKey.self, value: hovering)
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
        MonitorRibbon(width: Self.ribbonWidth, filled: isMonitored, hovering: hovering)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: pops) { content, stretch in
                content.scaleEffect(x: 1, y: stretch, anchor: .top)
            } keyframes: { _ in
                SpringKeyframe(1.4, duration: 0.14)
                SpringKeyframe(1, duration: 0.4, spring: .bouncy)
            }
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
    let onToggle: ((Bool) async -> Void)?

    @State private var inFlight = false
    @State private var hovering = false
    /// Only the value a click asked for pops, not one that loaded or a failure snapping back.
    @State private var requested: Bool?
    @State private var pops = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isMonitored: Bool, entity: MonitorEntity, size: CGFloat = 10,
                onToggle: ((Bool) async -> Void)? = nil) {
        self.isMonitored = isMonitored
        self.entity = entity
        self.size = size
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
                    requested = !isMonitored
                    Task {
                        inFlight = true
                        await onToggle(!isMonitored)
                        inFlight = false
                    }
                } label: { glyph }
                .buttonStyle(.plain)
                .disabled(inFlight)
                .onHover { over in
                    withAnimation(.monitorHover) { hovering = over }
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
        .onChange(of: isMonitored) { _, now in
            if now == requested, !reduceMotion { pops += 1 }
            requested = nil
        }
    }

    private var glyph: some View {
        MonitorBookmark(isMonitored: isMonitored, size: size, hovering: hovering, pops: pops)
            .frame(width: 16, height: 20, alignment: .leading)
            .contentShape(Rectangle())
    }
}
