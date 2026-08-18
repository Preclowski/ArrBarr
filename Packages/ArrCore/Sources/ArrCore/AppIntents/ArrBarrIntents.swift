import AppIntents
import Foundation

// MARK: - App Intents (Siri / Shortcuts / Spotlight)
//
// Read-only Phase-1 intents. They reuse the chat assistant's LocalToolBackend
// for data, but format CONCISE, spoken-friendly summaries (top few items) —
// the raw tool text is dense LLM output and reads as a wall of characters in
// Siri. Live in ArrCore so both app targets get them.

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

    private static func call(_ name: String) async -> ToolCallOutput? {
        let backend = await MainActor.run { makeBackend() }
        return try? await backend.callTool(name: name, arguments: .object([:]))
    }

    /// e.g. "3 downloads. Ran at 100%, The Next Karate Kid at 80%, and 1 more."
    static func queueSummary() async -> String {
        guard case .downloadQueue(let items)? = await call("list_download_queue")?.rich,
              !items.isEmpty else {
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
        guard case .calendar(let items)? = await call("get_calendar")?.rich else {
            return String(localized: "Nothing is coming up soon.", bundle: .module)
        }
        // Only FUTURE releases — the feed can include past-dated entries
        // (e.g. a monitored movie's old cinema date), which produced the
        // nonsensical "coming up … 5 years ago".
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

    /// Current queue items (real download rows).
    static func queueItems() async -> [QueueItem] {
        guard case .downloadQueue(let items)? = await call("list_download_queue")?.rich else { return [] }
        return items
    }

    /// Mirrors QueueRowView.canControl — pause/resume needs a configured
    /// download client for the item's protocol.
    @MainActor
    static func canControl(_ item: QueueItem, _ cs: ConfigStore) -> Bool {
        switch item.downloadProtocol {
        case .usenet:
            return (cs.sabnzbd.isConfigured && !cs.sabnzbd.apiKey.isEmpty) || cs.nzbget.isConfigured
        case .torrent:
            return cs.qbittorrent.isConfigured || cs.transmission.isConfigured
                || cs.rtorrent.isConfigured || cs.deluge.isConfigured
        case .unknown:
            return false
        }
    }

    /// Per-service one-liners, dropping the LLM detail bullets + section
    /// headers so Siri gets a clean summary.
    static func healthSummary() async -> String {
        let text = await call("health")?.text ?? ""
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
// NOT added to AppShortcutsProvider (no zero-config Siri phrases) — they're
// available as actions in the Shortcuts app for the user to wire up manually.
// Keeps destructive/state-changing actions off "Hey Siri" by default.

@available(macOS 13.0, iOS 16.0, *)
public struct PauseAllDownloadsIntent: AppIntent {
    public static var title: LocalizedStringResource = "Pause all downloads"
    public static var description = IntentDescription("Pauses every active download (where a download client is configured).")
    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let cs = ConfigStore.shared
        let items = await ArrIntentSupport.queueItems()
        let targets = await MainActor.run {
            items.filter { $0.status == .downloading && ArrIntentSupport.canControl($0, cs) }
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
        let cs = ConfigStore.shared
        let items = await ArrIntentSupport.queueItems()
        let targets = await MainActor.run {
            items.filter { $0.status == .paused && ArrIntentSupport.canControl($0, cs) }
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
    // Bring the app forward; iOS shows the search surface. (On the macOS
    // menu-bar app the popover can't be opened programmatically, so the query
    // is staged for the next time the popover opens.)
    public static var openAppWhenRun: Bool = true

    @Parameter(title: "Search")
    public var query: String

    public init() {}
    public init(query: String) { self.query = query }

    public func perform() async throws -> some IntentResult {
        let q = query
        // Small delay so the (possibly cold-launched) search surface is mounted
        // and listening before we post.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            NotificationCenter.default.post(name: .arrBarrSearchQuery, object: nil, userInfo: ["query": q])
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
