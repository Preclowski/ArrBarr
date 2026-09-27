import AppIntents
import Foundation

// MARK: - App Intents (Siri / Shortcuts / Spotlight)
//
// Spoken summaries over LocalToolBackend: the raw tool text is dense LLM output
// that reads as a wall of characters in Siri.

@available(macOS 13.0, iOS 16.0, *)
enum ArrIntentSupport {
    @MainActor
    static func makeBackend() -> LocalToolBackend {
        let cs = ConfigStore.shared
        return LocalToolBackend(
            sonarr: cs.sonarr, radarr: cs.radarr, lidarr: cs.lidarr, whisparr: cs.whisparr,
            aiKnowsAboutWhisparr: cs.aiKnowsAboutWhisparr,
            tmdbApiKey: cs.tmdbApiKey,
            downloadClients: DownloadClientConfigs(
                qbittorrent: cs.qbittorrent, transmission: cs.transmission,
                nzbget: cs.nzbget, sabnzbd: cs.sabnzbd,
                rtorrent: cs.rtorrent, deluge: cs.deluge
            ),
            mediaServer: cs.mediaServer
        )
    }

    /// nil when the servers didn't answer: Siri must not turn an outage into "nothing is downloading".
    private static func call(_ name: String) async -> ToolCallOutput? {
        let backend = await MainActor.run { makeBackend() }
        return try? await backend.callTool(name: name, arguments: .object([:]))
    }

    private static var unreachable: String { String(localized: "intents.unreachable", bundle: .module) }

    /// e.g. "3 downloads. Ran at 100%, The Next Karate Kid at 80%, and 1 more."
    static func queueSummary() async -> String {
        guard let output = await call("list_download_queue") else { return unreachable }
        guard case .downloadQueue(let items)? = output.rich, !items.isEmpty else {
            return String(localized: "Nothing is downloading right now.", bundle: .module)
        }
        let top = items.prefix(3).map {
            String.localizedStringWithFormat(
                NSLocalizedString("intents.itemAtPercent", bundle: .module, comment: ""),
                $0.title, Int(($0.progress * 100).rounded()))
        }
        var s = String.localizedStringWithFormat(
            NSLocalizedString("unit.downloads", bundle: .module, comment: ""), items.count) + ". "
        s += top.joined(separator: ", ")
        let extra = items.count - min(items.count, 3)
        if extra > 0 {
            s += ", " + String.localizedStringWithFormat(
                NSLocalizedString("intents.andMore", bundle: .module, comment: ""), extra)
        }
        return s + "."
    }

    /// e.g. "Coming up: Severance S2E3 tomorrow, Dune in 3 days."
    static func upcomingSummary() async -> String {
        guard let output = await call("get_calendar") else { return unreachable }
        guard case .calendar(let items)? = output.rich else {
            return String(localized: "Nothing is coming up soon.", bundle: .module)
        }
        // The feed can include past-dated entries (an old cinema date).
        let now = Date()
        let startOfToday = Calendar.current.startOfDay(for: now)
        let future = items
            .filter { $0.airDate >= startOfToday }
            .sorted { $0.airDate < $1.airDate }
        guard !future.isEmpty else {
            return String(localized: "Nothing is coming up soon.", bundle: .module)
        }

        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        let top = future.prefix(3).map { it -> String in
            let when = fmt.localizedString(for: it.airDate, relativeTo: now)
            let sub = it.subtitle.map { " \($0)" } ?? ""
            return "\(it.title)\(sub) \(when)"
        }
        var s = String.localizedStringWithFormat(
            NSLocalizedString("intents.comingUp", bundle: .module, comment: ""),
            top.joined(separator: ", "))
        let extra = future.count - min(future.count, 3)
        if extra > 0 {
            s += ", " + String.localizedStringWithFormat(
                NSLocalizedString("intents.andMore", bundle: .module, comment: ""), extra)
        }
        return s + "."
    }

    static func queueItems() async -> [QueueItem] {
        guard case .downloadQueue(let items)? = await call("list_download_queue")?.rich else { return [] }
        return items
    }

    static func healthSummary() async -> String {
        guard let text = await call("health")?.text else { return unreachable }
        guard !text.isEmpty else { return String(localized: "No services are configured.", bundle: .module) }
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("•") && !$0.hasSuffix(":") && !$0.isEmpty }
        return lines.isEmpty
            ? String(localized: "Everything looks healthy.", bundle: .module)
            : lines.joined(separator: ". ")
    }
}

@available(macOS 13.0, iOS 16.0, *)
public struct ShowDownloadQueueIntent: AppIntent {
    public static var title: LocalizedStringResource = "Show download queue"
    public static var description = IntentDescription(
        "Says what Sonarr and Radarr are currently downloading."
    )
    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let text = await ArrIntentSupport.queueSummary()
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

@available(macOS 13.0, iOS 16.0, *)
public struct ShowUpcomingIntent: AppIntent {
    public static var title: LocalizedStringResource = "Show upcoming releases"
    public static var description = IntentDescription(
        "Says the next upcoming episodes, movies and albums."
    )
    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let text = await ArrIntentSupport.upcomingSummary()
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - Action intents
//
// Not in AppShortcutsProvider, so state-changing actions stay off "Hey Siri".

@available(macOS 13.0, iOS 16.0, *)
public struct PauseAllDownloadsIntent: AppIntent {
    public static var title: LocalizedStringResource = "Pause all downloads"
    public static var description = IntentDescription("Pauses every active download (where a download client is configured).")
    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let items = await ArrIntentSupport.queueItems()
        let targets = await MainActor.run {
            items.filter { $0.status == .downloading && ConfigStore.shared.canControlDownload($0.downloadProtocol) }
        }
        for item in targets { await QueueViewModel.shared.pause(item) }
        let msg = targets.isEmpty
            ? String(localized: "Nothing to pause.", bundle: .module)
            : String.localizedStringWithFormat(
                NSLocalizedString("intents.pausedCount", bundle: .module, comment: ""), targets.count)
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}

@available(macOS 13.0, iOS 16.0, *)
public struct ResumeAllDownloadsIntent: AppIntent {
    public static var title: LocalizedStringResource = "Resume all downloads"
    public static var description = IntentDescription("Resumes every paused download (where a download client is configured).")
    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let items = await ArrIntentSupport.queueItems()
        let targets = await MainActor.run {
            items.filter { $0.status == .paused && ConfigStore.shared.canControlDownload($0.downloadProtocol) }
        }
        for item in targets { await QueueViewModel.shared.resume(item) }
        let msg = targets.isEmpty
            ? String(localized: "Nothing to resume.", bundle: .module)
            : String.localizedStringWithFormat(
                NSLocalizedString("intents.resumedCount", bundle: .module, comment: ""), targets.count)
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}

@available(macOS 13.0, iOS 16.0, *)
public struct SearchToAddIntent: AppIntent {
    public static var title: LocalizedStringResource = "Search to add"
    public static var description = IntentDescription("Search Sonarr/Radarr and open ArrBarr at the results to add something.")
    // The macOS popover can't be opened programmatically; the query waits for its next open.
    public static var openAppWhenRun: Bool = true

    @Parameter(title: "Search")
    public var query: String

    public init() {}
    public init(query: String) { self.query = query }

    public func perform() async throws -> some IntentResult {
        let q = query
        // Lets a cold-launched search surface mount and listen before the post.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            AppMessages.post(AppMessages.SearchQuery(query: q))
        }
        return .result()
    }
}

@available(macOS 13.0, iOS 16.0, *)
public struct CheckArrHealthIntent: AppIntent {
    public static var title: LocalizedStringResource = "Check service health"
    public static var description = IntentDescription(
        "Reports warnings/errors across your arrs and whether download clients are reachable."
    )
    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let text = await ArrIntentSupport.healthSummary()
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}
