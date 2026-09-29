import os
import Foundation
import MediaKit

extension LocalToolBackend {
    // MARK: - Health, calendar and download queue


    /// Messages are inlined only when there is something to report, to keep a green result compact.
    func healthCheck() async throws -> ToolCallOutput {
        let configured: [(QueueItem.Source, ServiceConfig)] = [
            (.sonarr, sonarr), (.radarr, radarr),
            (.lidarr, lidarr), (.whisparr, whisparr),
        ].filter { $0.1.isConfigured }

        let clientLines = await downloadClientHealthLines()

        guard !configured.isEmpty else {
            if clientLines.isEmpty {
                return ToolCallOutput(text: "No services are configured.")
            }
            return ToolCallOutput(text: (["Download clients:"] + clientLines).joined(separator: "\n"))
        }

        var report: [(source: QueueItem.Source, records: [ArrHealth], error: String?)] = []
        await withTaskGroup(of: (QueueItem.Source, Result<[ArrHealth], Error>).self) { group in
            for (source, cfg) in configured {
                group.addTask { [cfg] in
                    do {
                        let records: [ArrHealth]
                        records = try await ServiceHandles.arr(source, config: cfg).fetchHealth()
                        return (source, .success(records))
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }
            for await (source, outcome) in group {
                switch outcome {
                case .success(let records):
                    report.append((source, records, nil))
                case .failure(let err):
                    report.append((source, [], err.localizedDescription))
                }
            }
        }
        report.sort { $0.source.displayName < $1.source.displayName }

        var lines: [String] = []
        for entry in report {
            if let err = entry.error {
                lines.append("\(entry.source.displayName): unreachable — \(err)")
                continue
            }
            if entry.records.isEmpty {
                lines.append("\(entry.source.displayName): healthy")
                continue
            }
            let errorCount = entry.records.filter { ($0.type ?? "").lowercased() == "error" }.count
            let warningCount = entry.records.count - errorCount
            var summary = "\(entry.source.displayName): "
            if errorCount > 0 { summary += "\(errorCount) error\(errorCount == 1 ? "" : "s")" }
            if warningCount > 0 {
                if errorCount > 0 { summary += ", " }
                summary += "\(warningCount) warning\(warningCount == 1 ? "" : "s")"
            }
            lines.append(summary)
            for rec in entry.records {
                let kind = (rec.type ?? "info").lowercased()
                let msg = rec.message ?? "(no message)"
                lines.append("  • [\(kind)] \(msg)")
            }
        }
        if !clientLines.isEmpty {
            lines.append("Download clients:")
            lines.append(contentsOf: clientLines)
        }
        return ToolCallOutput(text: lines.joined(separator: "\n"))
    }

    private func downloadClientHealthLines() async -> [String] {
        let dc = downloadClients
        let probes: [(String, ServiceKind, ServiceConfig)] = [
            ("qBittorrent", .qbittorrent, dc.qbittorrent),
            ("Transmission", .transmission, dc.transmission),
            ("NZBGet", .nzbget, dc.nzbget),
            ("SABnzbd", .sabnzbd, dc.sabnzbd),
            ("rTorrent", .rtorrent, dc.rtorrent),
            ("Deluge", .deluge, dc.deluge),
        ].filter { $0.2.isConfigured }

        guard !probes.isEmpty else { return [] }

        var results: [(String, String)] = []
        await withTaskGroup(of: (String, String).self) { group in
            for (label, kind, cfg) in probes {
                group.addTask { [cfg] in
                    do {
                        let status = try await ServiceHandles.testConnection(kind, config: cfg)
                        let detail = status.isEmpty ? "" : " (\(status))"
                        return (label, "reachable\(detail)")
                    } catch {
                        return (label, "unreachable — \(error.localizedDescription)")
                    }
                }
            }
            for await r in group { results.append(r) }
        }
        results.sort { $0.0 < $1.0 }
        return results.map { "  • \($0.0): \($0.1)" }
    }

    func getCalendar(_ args: JSONValue) async throws -> ToolCallOutput {
        let requested = Self.stringArg(args, key: "service").lowercased()

        // Whisparr only when the AI-access toggle is on, like every other whisparr tool.
        let all: [(QueueItem.Source, ServiceConfig)] = [
            (.sonarr, sonarr), (.radarr, radarr),
            (.lidarr, lidarr), (.whisparr, whisparr),
        ]
        let targets: [(QueueItem.Source, ServiceConfig)]
        if !requested.isEmpty {
            guard let src = QueueItem.Source(rawValue: requested) else {
                return ToolCallOutput(text: "Unknown service '\(requested)'. Use sonarr, radarr, lidarr or whisparr.")
            }
            if src == .whisparr && !aiKnowsAboutWhisparr {
                return ToolCallOutput(text: "Whisparr AI access is disabled in Settings.")
            }
            guard let cfg = all.first(where: { $0.0 == src })?.1 else {
                return ToolCallOutput(text: "Unknown service '\(requested)'. Use sonarr, radarr, lidarr or whisparr.")
            }
            guard cfg.isConfigured else {
                return ToolCallOutput(text: "\(src.displayName) is not configured.")
            }
            targets = [(src, cfg)]
        } else {
            targets = all.filter { src, cfg in
                cfg.isConfigured && (src != .whisparr || aiKnowsAboutWhisparr)
            }
        }
        guard !targets.isEmpty else {
            return ToolCallOutput(text: "No services are configured.")
        }

        let (items, failed) = await UpcomingService.calendars(targets)
        let merged = items.sorted { $0.airDate < $1.airDate }
        let failures = failed.map { "\($0.0.displayName) calendar unreachable — \($0.1.localizedDescription)" }

        var text = Self.formatCalendarCondensed(merged)
        if !failures.isEmpty {
            text += "\n" + failures.map { "⚠️ \($0)" }.joined(separator: "\n")
        }
        return ToolCallOutput(text: text, rich: .calendar(merged))
    }

    nonisolated static func formatCalendarCondensed(_ items: [UpcomingItem]) -> String {
        guard !items.isEmpty else { return "Nothing upcoming." }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let top = items.prefix(15)
        let lines = top.map { it -> String in
            let dateStr = fmt.string(from: it.airDate)
            if let subtitle = it.subtitle, !subtitle.isEmpty {
                return "• \(dateStr) — \(it.title) · \(subtitle)"
            }
            return "• \(dateStr) — \(it.title)"
        }
        var out = "Upcoming releases:"
        out += "\n" + lines.joined(separator: "\n")
        if items.count > top.count {
            out += "\n(\(items.count - top.count) more not shown)"
        }
        return out
    }

    // MARK: - Download queue

    /// Queue items carry both incoming and existing-file metadata, so upgrades are explained in one call.
    /// Whisparr rides the `aiKnowsAboutWhisparr` gate: an arr hidden from the model must not leak in here.
    func listDownloadQueue(_ args: JSONValue) async throws -> ToolCallOutput {
        let configured: [(QueueItem.Source, ServiceConfig)] = [
            (.sonarr, sonarr), (.radarr, radarr), (.lidarr, lidarr),
            (.whisparr, aiKnowsAboutWhisparr ? whisparr : .empty),
        ].filter { $0.1.isConfigured }

        guard !configured.isEmpty else {
            return ToolCallOutput(text: "No arr is configured.")
        }

        var items: [QueueItem] = []
        var failures: [String] = []
        await withTaskGroup(of: (QueueItem.Source, Result<[QueueItem], Error>).self) { group in
            for (source, cfg) in configured {
                group.addTask { [cfg] in
                    do {
                        let queue: [QueueItem]
                        queue = try await ServiceHandles.arr(source, config: cfg).fetchQueue()
                        return (source, .success(queue))
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }
            for await (source, outcome) in group {
                switch outcome {
                case .success(let queue): items.append(contentsOf: queue)
                case .failure(let err):
                    failures.append("\(source.displayName) queue unreachable — \(err.localizedDescription)")
                }
            }
        }

        let filter = Self.stringArg(args, key: "query").lowercased()
        if !filter.isEmpty {
            items = items.filter { $0.title.lowercased().contains(filter) }
        }
        items.sort { lhs, rhs in
            if lhs.isUpgrade != rhs.isUpgrade { return lhs.isUpgrade }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        let text = Self.formatQueueCondensed(items, failures: failures)
        return ToolCallOutput(text: text, rich: .downloadQueue(items))
    }

    nonisolated static func formatQueueCondensed(_ items: [QueueItem], failures: [String] = []) -> String {
        var sections: [String] = []

        if items.isEmpty {
            sections.append(failures.isEmpty
                ? "Nothing is downloading right now."
                : "Nothing is downloading right now (some services were unreachable).")
        } else {
            let top = items.prefix(25)
            var lines: [String] = []
            for item in top {
                let pct = Int((item.progress * 100).rounded())
                let tag = "[\(item.source.displayName)]"
                var line = "• \(tag) \(item.title) — \(item.status.displayName) \(pct)%"
                if item.isUpgrade, let diff = upgradeDiffFragment(item) {
                    line += "\n    \(diff)"
                }
                lines.append(line)
            }
            var out = "Download queue — \(items.count) item\(items.count == 1 ? "" : "s"):"
            out += "\n" + lines.joined(separator: "\n")
            if items.count > top.count {
                out += "\n(\(items.count - top.count) more not shown)"
            }
            sections.append(out)
        }

        if !failures.isEmpty {
            sections.append(failures.map { "⚠️ \($0)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// `UPGRADE: 1080p → 2160p · score 50→120 · +DV -X · 8.1GB→24.3GB`; nil when nothing differs.
    nonisolated static func upgradeDiffFragment(_ item: QueueItem) -> String? {
        var parts: [String] = []

        let oldQ = item.existingQuality ?? "?"
        let newQ = item.quality ?? "?"
        if oldQ != newQ {
            parts.append("\(oldQ) → \(newQ)")
        }

        if let oldScore = item.existingCustomFormatScore, oldScore != item.customFormatScore {
            parts.append("score \(oldScore)→\(item.customFormatScore)")
        }

        let oldFormats = Set(item.existingCustomFormats)
        let newFormats = Set(item.customFormats)
        let gained = newFormats.subtracting(oldFormats).sorted()
        let lost = oldFormats.subtracting(newFormats).sorted()
        var formatBits = gained.map { "+\($0)" }
        formatBits += lost.map { "-\($0)" }
        if !formatBits.isEmpty {
            parts.append(formatBits.joined(separator: " "))
        }

        if let oldSize = item.existingSize, oldSize > 0 {
            let oldStr = ByteCountFormatter.string(fromByteCount: oldSize, countStyle: .file)
            let newStr = ByteCountFormatter.string(fromByteCount: item.sizeTotal, countStyle: .file)
            parts.append("\(oldStr)→\(newStr)")
        }

        guard !parts.isEmpty else { return nil }
        return "UPGRADE: " + parts.joined(separator: " · ")
    }

}
