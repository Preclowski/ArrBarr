import SwiftUI

// MARK: - Shared entry presentation

extension LibraryEntry {
    /// Lidarr artist images are square; forcing 2:3 letterboxes them.
    var posterAspect: CGFloat {
        source == .lidarr ? 1 : 2.0 / 3.0
    }

    var isMonitored: Bool { state != .unmonitored }


    func releaseStatusText(locale: Locale) -> String? {
        ArrReleaseStatusLabel.text(releaseStatus, locale: locale)
    }

    /// `includeYear: false` for the list row, whose title line already carries the year.
    func metaText(locale: Locale, includeYear: Bool = true) -> String {
        switch state {
        case .unmonitored:
            return AppLocalized.string("Unmonitored", locale: locale)
        case .notAvailable:
            return AppLocalized.string("library.status.notAvailable", locale: locale)
        case .missing:
            if let total = totalCount, total > 0 {
                return "\(fileCount ?? 0)/\(total)"
            }
            return AppLocalized.string("search.missing.button", locale: locale)
        case .partial:
            return "\(fileCount ?? 0)/\(totalCount ?? 0)"
        case .complete:
            var parts: [String] = []
            if includeYear, let year { parts.append(String(year)) }
            if sizeOnDisk > 0 {
                parts.append(ByteCountFormatter.string(fromByteCount: sizeOnDisk, countStyle: .file))
            }
            return parts.joined(separator: " · ")
        }
    }

    var sizeText: String? {
        sizeOnDisk > 0 ? ByteCountFormatter.string(fromByteCount: sizeOnDisk, countStyle: .file) : nil
    }

    /// A Lidarr entry is the artist, so it opens the artist surface.
    var detailTarget: QueueItem {
        DetailRequest.item(source: source, arrId: arrId, title: title,
                           posterURL: posterURL, posterRequiresAuth: posterRequiresAuth)
    }

    func openDetail() {
        DetailRequest.post(detailTarget)
    }

    func webURL(in configStore: ConfigStore) -> URL? {
        source == .lidarr
            ? lidarrArtistWebURL(foreignArtistId: slug, in: configStore)
            : arrWebURL(source: source, slug: slug, in: configStore)
    }
}

extension View {
    /// The entry's detail "…", minus delete.
    func libraryEntryMenu(_ entry: LibraryEntry, configStore: ConfigStore) -> some View {
        contextMenu {
            DetailEntryMenuItems(target: entry.detailTarget, webURL: entry.webURL(in: configStore))
        }
    }
}

// MARK: - Tile

struct LibraryTile: View {
    let entry: LibraryEntry
    let apiKey: String?
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        Button {
            entry.openDetail()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                PosterBlurContainer(
                    blurred: configStore.shouldBlurPoster(for: entry.source),
                    cornerRadius: Tokens.Radius.card
                ) {
                    // The tile owns the shape; artwork of any other ratio fills it instead of resizing it.
                    Color.clear
                        .aspectRatio(entry.posterAspect, contentMode: .fit)
                        .overlay {
                            RemotePoster(
                                url: entry.posterURL,
                                apiKey: apiKey,
                                // `.icon`, not `.card`: 288 px covers a ≤160 pt tile at @2x and is already on disk;
                                // `.card` costs ~180 kB per tile (~400 MB for a 3000-title library).
                                tier: .icon,
                                cornerRadius: Tokens.Radius.card,
                                fallbackSymbol: entry.source.symbol,
                                fill: true
                            )
                        }
                }
                .posterMarks(watched: entry.watched, monitored: entry.isMonitored,
                             cornerRadius: Tokens.Radius.card, ribbonWidth: 10)
                Text(verbatim: entry.title)
                    .scaledFont(size: 11, weight: .semibold)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if entry.state == .complete {
                    Text(verbatim: entry.metaText(locale: configStore.currentLocale))
                        .scaledFont(size: 10)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                } else {
                    LibraryStatusChip(entry: entry)
                }
            }
            .opacity(entry.state == .unmonitored ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .libraryEntryMenu(entry, configStore: configStore)
        .libraryTooltip(entry: entry, apiKey: apiKey)
        .accessibilityLabel(Text(verbatim: entry.title))
    }
}

// MARK: - List row

struct LibraryListRow: View {
    let entry: LibraryEntry
    let apiKey: String?
    @EnvironmentObject var configStore: ConfigStore

    private var rowTitle: String {
        if let year = entry.year {
            return "\(entry.title) (\(year))"
        }
        return entry.title
    }

    private var metadataSegments: [String] {
        var segments: [String] = []
        if let size = entry.sizeText { segments.append(size) }
        // Skipped for partial, where the status chip already shows the count.
        if entry.state != .partial, let total = entry.totalCount, total > 0 {
            segments.append("\(entry.fileCount ?? 0)/\(total)")
        }
        if let quality = entry.fileQuality { segments.append(quality) }
        return segments
    }

    /// A chip, not a bare segment, so it reads as the target rather than another on-disk quality.
    @ViewBuilder
    private var profileBadge: some View {
        if let name = entry.profileName { ProfileChip(name: name) }
    }

    var body: some View {
        PosterMetadataRow(
            posterURL: entry.posterURL,
            posterAPIKey: apiKey,
            posterSize: CGSize(width: 38 * entry.posterAspect, height: 38),
            posterBlurred: configStore.shouldBlurPoster(for: entry.source),
            posterFallbackSymbol: entry.source.symbol,
            // Watched only: the row already dims unmonitored entries, and two marks crowd a 25pt thumbnail.
            posterWatched: entry.watched,
            title: rowTitle,
            metadataSegments: metadataSegments,
            onTap: { entry.openDetail() },
            metadataBadge: { profileBadge }
        ) {
            // Trailing, so the chips line up in a column down the list.
            LibraryStatusChip(entry: entry)
        }
        .opacity(entry.state == .unmonitored ? 0.55 : 1)
        .libraryEntryMenu(entry, configStore: configStore)
        .libraryTooltip(entry: entry, apiKey: apiKey)
    }
}

// MARK: - Status chip

struct LibraryStatusChip: View {
    let entry: LibraryEntry
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        MediaStateChip(
            state: entry.state,
            have: entry.fileCount,
            total: entry.totalCount,
            locale: configStore.currentLocale
        )
    }
}
