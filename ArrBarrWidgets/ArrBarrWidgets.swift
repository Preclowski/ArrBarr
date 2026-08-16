import WidgetKit
import SwiftUI
import AppIntents
import ArrCore
import os

// MARK: - Bundle entry point

@main
struct ArrBarrWidgetsBundle: WidgetBundle {
    init() {
        #if APPSTORE
        AppCapabilities.configure(isAppStore: true)
        #endif
    }

    var body: some Widget {
        LibraryStatusGridWidget()
        LibraryServiceWidget()
        UpNextWidget()
    }
}

// MARK: - Configuration intent (which services to show)

/// Which service the small widget features. `.automatic` falls back to the
/// first enabled service.
enum FeaturedService: String, AppEnum {
    case automatic, radarr, sonarr, lidarr, whisparr

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Featured service")
    static let caseDisplayRepresentations: [FeaturedService: DisplayRepresentation] = [
        .automatic: "Automatic",
        .radarr: "Movies (Radarr)",
        .sonarr: "TV (Sonarr)",
        .lidarr: "Music (Lidarr)",
        .whisparr: "Adult (Whisparr)",
    ]

    var source: LibrarySummary.Source? {
        switch self {
        case .automatic: return nil
        case .radarr: return .radarr
        case .sonarr: return .sonarr
        case .lidarr: return .lidarr
        case .whisparr: return .whisparr
        }
    }
}

/// Small widget config: just pick which single service to show.
struct ServiceWidgetConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Library Service"
    static let description = IntentDescription("Pick which service the widget shows.")

    @Parameter(title: "Service", default: .automatic) var service: FeaturedService
}

/// Medium widget config: enable/disable each service (no single-service pick).
struct GridWidgetConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Library Status"
    static let description = IntentDescription("Choose which services to show.")

    @Parameter(title: "Movies (Radarr)", default: true) var showRadarr: Bool
    @Parameter(title: "TV (Sonarr)", default: true) var showSonarr: Bool
    @Parameter(title: "Music (Lidarr)", default: true) var showLidarr: Bool
    // Whisparr is OFF by default — discretion on a visible home screen.
    @Parameter(title: "Adult (Whisparr)", default: false) var showWhisparr: Bool
}

// MARK: - Timeline

struct LibraryStatusEntry: TimelineEntry {
    let date: Date
    let summaries: [LibrarySummary]
    let anyConfigured: Bool
    /// Which source the small widget should feature (nil = first available).
    var featured: LibrarySummary.Source? = nil

    /// The summary the small widget shows: the featured source if present,
    /// otherwise the first available.
    var featuredSummary: LibrarySummary? {
        if let featured, let match = summaries.first(where: { $0.source == featured }) {
            return match
        }
        return summaries.first
    }
}

/// Shared timeline-entry builder for both widgets. Fetches only the requested
/// sources; `featured` is carried through for the small widget's hero pick.
enum LibraryWidgetData {
    /// The extension is a separate process the user never sees running: a
    /// timeline that comes back empty renders as "no data" with no error, no
    /// UI to inspect and no way to attach a debugger after the fact. The log is
    /// the only instrument it has, so both providers say what they asked for
    /// and what came back.
    static let log = Logger(category: "Widget")

    static func entry(sources: Set<LibrarySummary.Source>,
                      featured: LibrarySummary.Source?) async -> LibraryStatusEntry {
        // Demo mode: the app mirrors the flag into the group suite, so the
        // widget renders the curated demo library instead of hitting servers.
        if WidgetDataStore.isDemoActive {
            let demo = DemoMocks.librarySummaries().filter { sources.contains($0.source) }
            return LibraryStatusEntry(date: Date(), summaries: demo, anyConfigured: true, featured: featured)
        }

        func config(_ s: LibrarySummary.Source) -> ServiceConfig {
            sources.contains(s) ? WidgetDataStore.serviceConfig(s.kind) : .empty
        }
        let radarr = config(.radarr), sonarr = config(.sonarr)
        let lidarr = config(.lidarr), whisparr = config(.whisparr)

        // isVisible (requires an API key, matching the app's own visibility
        // gate) so a keyless-but-enabled service shows the empty state rather
        // than a blank widget.
        let anyConfigured = [radarr, sonarr, lidarr, whisparr].contains { $0.isVisible }
        let summaries = await LibrarySummaryService().summaries(
            radarr: radarr, sonarr: sonarr, lidarr: lidarr, whisparr: whisparr)
        // Configured-but-empty is the interesting shape: it means the fetch
        // reached nothing, which on a widget looks the same as "not set up".
        if anyConfigured && summaries.isEmpty {
            log.notice("library timeline: \(sources.count, privacy: .public) source(s) configured, none answered")
        } else {
            log.debug("library timeline: \(summaries.count, privacy: .public) of \(sources.count, privacy: .public) source(s) answered")
        }
        return LibraryStatusEntry(date: Date(), summaries: summaries, anyConfigured: anyConfigured, featured: featured)
    }

    /// Library grows slowly — refresh roughly every 6 hours.
    static func timeline(_ entry: LibraryStatusEntry) -> Timeline<LibraryStatusEntry> {
        Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(6 * 3600)))
    }
}

// MARK: - Small widget provider (single service)

struct ServiceWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LibraryStatusEntry {
        LibraryStatusEntry(date: Date(),
                           summaries: [LibrarySummary(source: .radarr, count: 1204, totalBytes: 8_400_000_000_000)],
                           anyConfigured: true, featured: .radarr)
    }

    func snapshot(for configuration: ServiceWidgetConfigIntent, in context: Context) async -> LibraryStatusEntry {
        await entry(for: configuration)
    }

    func timeline(for configuration: ServiceWidgetConfigIntent, in context: Context) async -> Timeline<LibraryStatusEntry> {
        LibraryWidgetData.timeline(await entry(for: configuration))
    }

    private func entry(for configuration: ServiceWidgetConfigIntent) async -> LibraryStatusEntry {
        let featured = configuration.service.source
        // A specific pick fetches only that service; Automatic fetches the
        // non-adult arrs and shows the first available.
        let sources: Set<LibrarySummary.Source> = featured.map { [$0] } ?? [.radarr, .sonarr, .lidarr]
        return await LibraryWidgetData.entry(sources: sources, featured: featured)
    }
}

// MARK: - Medium widget provider (enabled services)

struct GridWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LibraryStatusEntry {
        LibraryStatusEntry(date: Date(), summaries: [
            LibrarySummary(source: .radarr, count: 1204, totalBytes: 8_400_000_000_000),
            LibrarySummary(source: .sonarr, count: 58, totalBytes: 12_100_000_000_000),
        ], anyConfigured: true)
    }

    func snapshot(for configuration: GridWidgetConfigIntent, in context: Context) async -> LibraryStatusEntry {
        await entry(for: configuration)
    }

    func timeline(for configuration: GridWidgetConfigIntent, in context: Context) async -> Timeline<LibraryStatusEntry> {
        LibraryWidgetData.timeline(await entry(for: configuration))
    }

    private func entry(for configuration: GridWidgetConfigIntent) async -> LibraryStatusEntry {
        var sources: Set<LibrarySummary.Source> = []
        if configuration.showRadarr { sources.insert(.radarr) }
        if configuration.showSonarr { sources.insert(.sonarr) }
        if configuration.showLidarr { sources.insert(.lidarr) }
        if configuration.showWhisparr { sources.insert(.whisparr) }
        return await LibraryWidgetData.entry(sources: sources, featured: nil)
    }
}

// MARK: - View presentation per source

private extension LibrarySummary.Source {
    /// Maps to the ArrCore service kind so we can reuse `ServiceIcon`'s brand art.
    var kind: ServiceKind {
        switch self {
        case .radarr: return .radarr
        case .sonarr: return .sonarr
        case .lidarr: return .lidarr
        case .whisparr: return .whisparr
        }
    }

    var label: String {
        switch self {
        case .radarr: return "Movies"
        case .sonarr: return "Series"
        case .lidarr: return "Artists"
        case .whisparr: return "Scenes"
        }
    }

    /// Brand accent (full-colour mode only; the system tints in accented mode).
    var brandColor: Color {
        switch self {
        case .radarr: return Color(red: 1.00, green: 0.76, blue: 0.18) // gold
        case .sonarr: return Color(red: 0.20, green: 0.66, blue: 0.90) // sky blue
        case .lidarr: return Color(red: 0.16, green: 0.71, blue: 0.43) // green
        case .whisparr: return Color(red: 0.86, green: 0.21, blue: 0.43) // crimson
        }
    }
}

// MARK: - View

struct LibraryStatusView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var rendering
    let entry: LibraryStatusEntry

    var body: some View {
        content
            .containerBackground(for: .widget) { background }
    }

    @ViewBuilder private var content: some View {
        if !entry.anyConfigured {
            emptyState
        } else if family == .systemSmall {
            small
        } else {
            medium
        }
    }

    /// Background fill: a brand-tinted glass for the small widget (the colour of
    /// the featured arr), a neutral liquid-glass base everywhere else. In
    /// accented/tinted mode the system supplies the tint, so stay neutral.
    @ViewBuilder private var background: some View {
        if family == .systemSmall, rendering == .fullColor,
           let c = entry.featuredSummary?.source.brandColor {
            // Brand-tinted liquid glass: a frosted material under a soft
            // diagonal colour wash plus a top sheen highlight.
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(colors: [c.opacity(0.42), c.opacity(0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [.white.opacity(0.22), .clear],
                               startPoint: .top, endPoint: .center)
            }
        } else {
            // Tinted frosted glass that picks up the services' brand hues, so
            // it reads as coloured glass rather than a flat white panel.
            // (Standard home-screen widgets are opaque — the wallpaper can't
            // show through — so this simulates glass with a translucent
            // material + colour wash + sheen.)
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(colors: tintColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: .center)
            }
        }
    }

    /// Brand-coloured wash for the medium glass. Uses the leading service's
    /// hue prominently (like the small widget) so it reads as coloured glass
    /// rather than a flat white panel; a faint second hue adds depth.
    private var tintColors: [Color] {
        guard let first = entry.summaries.first?.source.brandColor else {
            return [.blue.opacity(0.40), .indigo.opacity(0.24)]
        }
        let second = entry.summaries.dropFirst().first?.source.brandColor ?? first
        return [first.opacity(0.48), second.opacity(0.22)]
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Set up a server in ArrBarr")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Small: a single hero service on a brand-coloured glass, with the brand
    // icon as a faded background watermark (matching the medium tiles).
    private var small: some View {
        ZStack(alignment: .topLeading) {
            if let s = entry.featuredSummary {
                ServiceIcon(kind: s.source.kind, size: 96)
                    .foregroundStyle(smallWatermarkStyle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .offset(x: 22, y: 22)

                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    Text("\(s.count)")
                        .font(.system(size: 54, weight: .heavy, design: .rounded))
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(s.source.label)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(byteString(s.totalBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Watermark icon for the small widget — a light emboss on the brand glass.
    private var smallWatermarkStyle: AnyShapeStyle {
        rendering == .fullColor ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.secondary)
    }

    // Medium: header (label + total size) over a row of per-service tiles.
    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical.fill")
                    .font(.caption)
                Text("Library")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(byteString(entry.summaries.reduce(0) { $0 + $1.totalBytes }))
                    .font(.caption.weight(.medium).monospacedDigit())
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(entry.summaries) { s in
                    tile(s)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // Tile: a big brand icon as a faded background watermark, with bold
    // count + label + size on top.
    private func tile(_ s: LibrarySummary) -> some View {
        ZStack(alignment: .topLeading) {
            ServiceIcon(kind: s.source.kind, size: 66)
                .foregroundStyle(watermarkStyle(s.source))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 16, y: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(s.count)")
                    .font(.system(size: 30, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(s.source.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Text(byteString(s.totalBytes))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tileFill(s.source), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Faded brand icon behind the tile content.
    private func watermarkStyle(_ source: LibrarySummary.Source) -> AnyShapeStyle {
        rendering == .fullColor
            ? AnyShapeStyle(source.brandColor.opacity(0.30))
            : AnyShapeStyle(.tertiary)
    }

    private func tileFill(_ source: LibrarySummary.Source) -> AnyShapeStyle {
        rendering == .fullColor
            ? AnyShapeStyle(source.brandColor.opacity(0.16))
            : AnyShapeStyle(.fill.tertiary)
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Widgets

/// Small (single-service) widget. Config: pick the service only.
struct LibraryServiceWidget: Widget {
    let kind = "LibraryServiceWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: ServiceWidgetConfigIntent.self,
            provider: ServiceWidgetProvider()
        ) { entry in
            LibraryStatusView(entry: entry)
                .widgetURL(URL(string: "arrbarr://library"))
        }
        .configurationDisplayName("Library Service")
        .description("One service at a glance.")
        .supportedFamilies([.systemSmall])
    }
}

/// Medium (multi-service) widget. Config: enable/disable services only.
struct LibraryStatusGridWidget: Widget {
    let kind = "LibraryStatusGridWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: GridWidgetConfigIntent.self,
            provider: GridWidgetProvider()
        ) { entry in
            LibraryStatusView(entry: entry)
                .widgetURL(URL(string: "arrbarr://library"))
        }
        .configurationDisplayName("Library Status")
        .description("Your library across services.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Up Next widget (upcoming calendar)

private extension UpcomingItem.Source {
    var kind: ServiceKind {
        switch self {
        case .radarr: return .radarr
        case .sonarr: return .sonarr
        case .lidarr: return .lidarr
        case .whisparr: return .whisparr
        }
    }
    var brandColor: Color {
        switch self {
        case .radarr: return Color(red: 1.00, green: 0.76, blue: 0.18)
        case .sonarr: return Color(red: 0.20, green: 0.66, blue: 0.90)
        case .lidarr: return Color(red: 0.16, green: 0.71, blue: 0.43)
        case .whisparr: return Color(red: 0.86, green: 0.21, blue: 0.43)
        }
    }
}

/// Config: which services feed the upcoming list (same for both families,
/// since both just show the soonest items — no single-service pick needed).
struct UpcomingConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Up Next"
    static let description = IntentDescription("Choose which services to include.")

    @Parameter(title: "Movies (Radarr)", default: true) var showRadarr: Bool
    @Parameter(title: "TV (Sonarr)", default: true) var showSonarr: Bool
    @Parameter(title: "Music (Lidarr)", default: true) var showLidarr: Bool
    @Parameter(title: "Adult (Whisparr)", default: false) var showWhisparr: Bool
}

struct UpcomingEntry: TimelineEntry {
    let date: Date
    let items: [UpcomingItem]
    let anyConfigured: Bool
}

struct UpNextProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UpcomingEntry {
        UpcomingEntry(date: Date(), items: UpcomingService.curate(DemoMocks.upcoming, limit: 4), anyConfigured: true)
    }

    func snapshot(for configuration: UpcomingConfigIntent, in context: Context) async -> UpcomingEntry {
        await entry(for: configuration)
    }

    func timeline(for configuration: UpcomingConfigIntent, in context: Context) async -> Timeline<UpcomingEntry> {
        let e = await entry(for: configuration)
        // The calendar shifts daily — refresh roughly every 3 hours.
        return Timeline(entries: [e], policy: .after(e.date.addingTimeInterval(3 * 3600)))
    }

    private func entry(for c: UpcomingConfigIntent) async -> UpcomingEntry {
        var enabled: Set<UpcomingItem.Source> = []
        if c.showRadarr { enabled.insert(.radarr) }
        if c.showSonarr { enabled.insert(.sonarr) }
        if c.showLidarr { enabled.insert(.lidarr) }
        if c.showWhisparr { enabled.insert(.whisparr) }

        if WidgetDataStore.isDemoActive {
            let items = UpcomingService.curate(DemoMocks.upcoming.filter { enabled.contains($0.source) }, limit: 8)
            return UpcomingEntry(date: Date(), items: items, anyConfigured: true)
        }

        func cfg(_ s: UpcomingItem.Source) -> ServiceConfig {
            enabled.contains(s) ? WidgetDataStore.serviceConfig(s.kind) : .empty
        }
        let r = cfg(.radarr), s = cfg(.sonarr), l = cfg(.lidarr), w = cfg(.whisparr)
        let anyConfigured = [r, s, l, w].contains { $0.isVisible }
        let items = await UpcomingService().upcoming(radarr: r, sonarr: s, lidarr: l, whisparr: w)
        if anyConfigured && items.isEmpty {
            LibraryWidgetData.log.notice("up-next timeline: \(enabled.count, privacy: .public) source(s) configured, nothing upcoming returned")
        } else {
            LibraryWidgetData.log.debug("up-next timeline: \(items.count, privacy: .public) item(s)")
        }
        return UpcomingEntry(date: Date(), items: items, anyConfigured: anyConfigured)
    }
}

struct UpNextView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var rendering
    let entry: UpcomingEntry

    var body: some View {
        content
            .containerBackground(for: .widget) { background }
    }

    /// Small = brand-coloured glass of the soonest item (like the library
    /// small widget); medium = neutral frosted glass.
    @ViewBuilder private var background: some View {
        if family == .systemSmall, rendering == .fullColor, let c = entry.items.first?.source.brandColor {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(colors: [c.opacity(0.42), c.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center)
            }
        } else {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .top, endPoint: .center)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !entry.anyConfigured {
            message("Set up a server in ArrBarr", icon: "externaldrive.badge.questionmark")
        } else if entry.items.isEmpty {
            message("Nothing coming up", icon: "calendar")
        } else if family == .systemSmall {
            small
        } else {
            medium
        }
    }

    private func message(_ text: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Small: the single soonest item, with the brand icon as a faded
    // background watermark (matching the library small widget).
    private var small: some View {
        ZStack(alignment: .topLeading) {
            if let it = entry.items.first {
                ServiceIcon(source: it.source, size: 90)
                    .foregroundStyle(rendering == .fullColor ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .offset(x: 22, y: 22)

                VStack(alignment: .leading, spacing: 2) {
                    header
                    Spacer(minLength: 0)
                    Text(it.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let sub = it.subtitle {
                        Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(it.airDateFormatted())
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .padding(.top, 1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // Medium: a list of the soonest items.
    private var medium: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            ForEach(entry.items.prefix(4)) { row($0) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
            Text("Up Next").font(.caption.weight(.semibold))
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func row(_ it: UpcomingItem) -> some View {
        HStack(spacing: 9) {
            ServiceIcon(source: it.source, size: 16)
                .foregroundStyle(it.source.brandColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(it.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let sub = it.subtitle {
                    Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(it.airDateFormatted())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct UpNextWidget: Widget {
    let kind = "UpNextWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: UpcomingConfigIntent.self,
            provider: UpNextProvider()
        ) { entry in
            UpNextView(entry: entry)
                .widgetURL(URL(string: "arrbarr://library"))
        }
        .configurationDisplayName("Up Next")
        .description("Your next releases and episodes.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
