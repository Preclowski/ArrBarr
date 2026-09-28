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

enum FeaturedService: String, AppEnum {
    case automatic, radarr, sonarr, lidarr, whisparr

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Featured service")
    static let caseDisplayRepresentations: [FeaturedService: DisplayRepresentation] = [
        .automatic: DisplayRepresentation(title: "Automatic"),
        .radarr: DisplayRepresentation(title: "Movies (Radarr)"),
        .sonarr: DisplayRepresentation(title: "TV (Sonarr)"),
        .lidarr: DisplayRepresentation(title: "Music (Lidarr)"),
        .whisparr: DisplayRepresentation(title: "Adult (Whisparr)"),
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

struct ServiceWidgetConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Library Service"
    static let description = IntentDescription("Pick which service the widget shows.")

    @Parameter(title: "Service", default: .automatic) var service: FeaturedService
}

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
    var featured: LibrarySummary.Source? = nil

    var featuredSummary: LibrarySummary? {
        if let featured, let match = summaries.first(where: { $0.source == featured }) {
            return match
        }
        return summaries.first
    }
}

enum LibraryWidgetData {
    /// The extension's only instrument: an empty timeline renders as "no data" with nothing to inspect.
    static let log = Logger(category: "Widget")

    static func entry(sources: Set<LibrarySummary.Source>,
                      featured: LibrarySummary.Source?) async -> LibraryStatusEntry {
        // The app mirrors the demo flag into the group suite.
        if WidgetDataStore.isDemoActive {
            let demo = await LibrarySummaryService.demo(sources: sources)
            return LibraryStatusEntry(date: Date(), summaries: demo, anyConfigured: true, featured: featured)
        }

        func config(_ s: LibrarySummary.Source) -> ServiceConfig {
            sources.contains(s) ? WidgetDataStore.serviceConfig(s.serviceKind) : .empty
        }
        let radarr = config(.radarr), sonarr = config(.sonarr)
        let lidarr = config(.lidarr), whisparr = config(.whisparr)

        // `isVisible` requires an API key, matching the app's own gate, so a keyless service shows the empty state.
        let anyConfigured = [radarr, sonarr, lidarr, whisparr].contains { $0.isVisible }
        let summaries = await LibrarySummaryService().summaries(
            radarr: radarr, sonarr: sonarr, lidarr: lidarr, whisparr: whisparr)
        // Configured-but-empty means the fetch reached nothing, which looks the same as "not set up".
        if anyConfigured && summaries.isEmpty {
            log.notice("library timeline: \(sources.count, privacy: .public) source(s) configured, none answered")
        } else {
            log.debug("library timeline: \(summaries.count, privacy: .public) of \(sources.count, privacy: .public) source(s) answered")
        }
        return LibraryStatusEntry(date: Date(), summaries: summaries, anyConfigured: anyConfigured, featured: featured)
    }

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
    var label: String {
        switch self {
        case .radarr: return String(localized: "Movies", bundle: .arrCore)
        case .sonarr: return String(localized: "Series", bundle: .arrCore)
        case .lidarr: return String(localized: "Artists", bundle: .arrCore)
        case .whisparr: return String(localized: "Scenes", bundle: .arrCore)
        }
    }

    /// Full-colour mode only; in accented mode the system tints.
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

    /// In accented/tinted mode the system supplies the tint, so stay neutral.
    @ViewBuilder private var background: some View {
        if family == .systemSmall, rendering == .fullColor,
           let c = entry.featuredSummary?.source.brandColor {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(colors: [c.opacity(0.42), c.opacity(0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [.white.opacity(0.22), .clear],
                               startPoint: .top, endPoint: .center)
            }
        } else {
            // Home-screen widgets are opaque, so this simulates glass with material, colour wash and sheen.
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(colors: tintColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: .center)
            }
        }
    }

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
            Text("Set up a server in ArrBarr", bundle: .arrCore)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var small: some View {
        ZStack(alignment: .topLeading) {
            if let s = entry.featuredSummary {
                ServiceIcon(kind: s.source.serviceKind, size: 96)
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

    private var smallWatermarkStyle: AnyShapeStyle {
        rendering == .fullColor ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.secondary)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical.fill")
                    .font(.caption)
                Text("Library", bundle: .arrCore)
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

    private func tile(_ s: LibrarySummary) -> some View {
        ZStack(alignment: .topLeading) {
            ServiceIcon(kind: s.source.serviceKind, size: 66)
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
        .configurationDisplayName(Text("Library Service", bundle: .arrCore))
        .description(Text("One service at a glance.", bundle: .arrCore))
        .supportedFamilies([.systemSmall])
    }
}

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
        .configurationDisplayName(Text("Library Status", bundle: .arrCore))
        .description(Text("Your library across services.", bundle: .arrCore))
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Up Next widget (upcoming calendar)

private extension UpcomingItem.Source {
    var brandColor: Color {
        switch self {
        case .radarr: return Color(red: 1.00, green: 0.76, blue: 0.18)
        case .sonarr: return Color(red: 0.20, green: 0.66, blue: 0.90)
        case .lidarr: return Color(red: 0.16, green: 0.71, blue: 0.43)
        case .whisparr: return Color(red: 0.86, green: 0.21, blue: 0.43)
        }
    }
}

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
        UpcomingEntry(date: Date(), items: [
            UpcomingItem(id: "placeholder-movie", source: .radarr, title: "Big Buck Bunny", subtitle: nil,
                         airDate: Date().addingTimeInterval(3600), releaseType: "digital", hasFile: false, overview: nil),
            UpcomingItem(id: "placeholder-episode", source: .sonarr, title: "Pioneer One", subtitle: "S01E02",
                         airDate: Date().addingTimeInterval(86400), releaseType: nil, hasFile: false, overview: nil),
        ], anyConfigured: true)
    }

    func snapshot(for configuration: UpcomingConfigIntent, in context: Context) async -> UpcomingEntry {
        await entry(for: configuration)
    }

    func timeline(for configuration: UpcomingConfigIntent, in context: Context) async -> Timeline<UpcomingEntry> {
        let e = await entry(for: configuration)
        return Timeline(entries: [e], policy: .after(e.date.addingTimeInterval(3 * 3600)))
    }

    private func entry(for c: UpcomingConfigIntent) async -> UpcomingEntry {
        var enabled: Set<UpcomingItem.Source> = []
        if c.showRadarr { enabled.insert(.radarr) }
        if c.showSonarr { enabled.insert(.sonarr) }
        if c.showLidarr { enabled.insert(.lidarr) }
        if c.showWhisparr { enabled.insert(.whisparr) }

        if WidgetDataStore.isDemoActive {
            let items = await UpcomingService.demo(sources: enabled, limit: 8)
            return UpcomingEntry(date: Date(), items: items, anyConfigured: true)
        }

        func cfg(_ s: UpcomingItem.Source) -> ServiceConfig {
            enabled.contains(s) ? WidgetDataStore.serviceConfig(s.serviceKind) : .empty
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

    private func message(_ text: LocalizedStringKey, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            Text(text, bundle: .arrCore).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
            Text("Up Next", bundle: .arrCore).font(.caption.weight(.semibold))
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
        .configurationDisplayName(Text("Up Next", bundle: .arrCore))
        .description(Text("Your next releases and episodes.", bundle: .arrCore))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
