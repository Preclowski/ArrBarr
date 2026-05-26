import SwiftUI

/// "Option B" download section: minimalist, no card chrome.
///
/// - Single item: one progress line + thin bar; if upgrade, a NEW/OLD
///   two-line diff and a monospaced release-name footer.
/// - Multiple items (ungrouped episodes for the same series): a header line
///   summarising the queue, then a stacked list of compact rows. The
///   originally-clicked row gets an accent left border so the user keeps
///   their bearings.
struct DownloadSection: View {
    let items: [QueueItem]
    let focused: QueueItem
    var showInlineUpgrade: Bool = true
    var showCustomFormats: Bool = false
    var showListingBadges: Bool = false
    var rowHoverDetail: Bool = false
    var listCollapsible: Bool = false
    var listExpandedDefault: Bool = true
    /// Per-item drill-down for the multi-row variant — fires when the
    /// user taps an episode row in a season-pack download list.
    var onTapItem: ((QueueItem) -> Void)? = nil
    /// Per-item queue actions for the multi-row variant. Wired by
    /// DetailView to QueueViewModel.pause/resume/delete.
    var onPauseItem: ((QueueItem) -> Void)? = nil
    var onResumeItem: ((QueueItem) -> Void)? = nil
    var onDeleteItem: ((QueueItem) -> Void)? = nil
    /// Optional URL resolver — when present, the warning banner on
    /// each row turns its messages into an "Open in browser" CTA
    /// pointed at the arr's own UI. Closure form (instead of a
    /// pre-baked URL) so the multi-row variant can compute per-row
    /// URLs without recomputing for the single-item case.
    var arrWebURLForItem: ((QueueItem) -> URL?)? = nil

    @State private var listExpanded: Bool

    init(
        items: [QueueItem],
        focused: QueueItem,
        showInlineUpgrade: Bool = true,
        showCustomFormats: Bool = false,
        showListingBadges: Bool = false,
        rowHoverDetail: Bool = false,
        listCollapsible: Bool = false,
        listExpandedDefault: Bool = true,
        onTapItem: ((QueueItem) -> Void)? = nil,
        onPauseItem: ((QueueItem) -> Void)? = nil,
        onResumeItem: ((QueueItem) -> Void)? = nil,
        onDeleteItem: ((QueueItem) -> Void)? = nil,
        arrWebURLForItem: ((QueueItem) -> URL?)? = nil
    ) {
        self.items = items
        self.focused = focused
        self.showInlineUpgrade = showInlineUpgrade
        self.showCustomFormats = showCustomFormats
        self.showListingBadges = showListingBadges
        self.rowHoverDetail = rowHoverDetail
        self.listCollapsible = listCollapsible
        self.listExpandedDefault = listExpandedDefault
        self.onTapItem = onTapItem
        self.onPauseItem = onPauseItem
        self.onResumeItem = onResumeItem
        self.onDeleteItem = onDeleteItem
        self.arrWebURLForItem = arrWebURLForItem
        self._listExpanded = State(initialValue: listExpandedDefault)
    }

    private var sortedItems: [QueueItem] {
        items.sorted { ($0.subtitle ?? "") < ($1.subtitle ?? "") }
    }

    /// Mirrors QueueRowView.hasExistingFileMetadata — guards the
    /// inline "↳ old metadata" diff row from rendering empty when an
    /// upgrade item has no existing-file fields populated.
    private func hasExistingFileMetadata(_ item: QueueItem) -> Bool {
        (item.existingQuality.map { !$0.isEmpty } ?? false)
            || (item.existingSize ?? 0) > 0
            || (item.existingCustomFormatScore ?? 0) != 0
    }

    public var body: some View {
        if items.count <= 1 {
            singleItemBlock(focused)
        } else {
            multiItemBlock
        }
    }

    // MARK: Single item

    @ViewBuilder
    private func singleItemBlock(_ item: QueueItem) -> some View {
        // Inline action cluster moved out — sticky pause/⋯ now lives
        // in `DetailView`'s header (Apple toolbar idiom, see
        // `headerActions`). Single-item block reverts to plain content.
        singleItemContent(item)
    }

    /// Quality · time-left · size · download-client meta line —
    /// rendered as plain text under the progress card. Same content
    /// as the old `ProgressLine.detailsRow` but extracted so the
    /// card can stay focused on the bar itself.
    @ViewBuilder
    private func detailsLine(item: QueueItem) -> some View {
        let segments: [String] = [
            item.quality.flatMap { $0.isEmpty ? nil : $0 },
            formattedTimeLeft(item),
            item.sizeTotal > 0 ? sizeText(item) : nil,
        ].compactMap { $0 }
        if !segments.isEmpty || (!showListingBadges && item.downloadClient != nil) {
            HStack(spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                    if idx > 0 { SeparatorDot() }
                    Text(verbatim: seg)
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                // Client moved into the card header.
            }
        }
    }

    private func sizeText(_ item: QueueItem) -> String {
        let done = max(0, item.sizeTotal - item.sizeLeft)
        return "\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.sizeTotal, countStyle: .file))"
    }

    private func formattedTimeLeft(_ item: QueueItem) -> String? {
        guard let raw = item.timeLeft, !raw.isEmpty else { return nil }
        let trimmed = String(raw.prefix { $0 != "." })
        return trimmed == "00:00:00" ? nil : trimmed
    }

    @ViewBuilder
    private func singleItemContent(_ item: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showListingBadges {
                listingBadges(item)
            }
            // Status + progress + `└─ OLD` upgrade sub-line all in
            // one card. Replaces the previous NEW/OLD grid render
            // that sat outside the card — the `└─` pattern matches
            // every other surface (queue tooltip, episode tooltip)
            // and the user only needs to read one diff format.
            DownloadProgressCard(item: item, showUpgradeDiff: true, showHeader: true, showProgressFill: false)
            // `detailsLine` (quality · time · size · client) dropped
            // — the card now carries quality / size / score and
            // client in its header. Repeating those tokens below
            // was the duplicate the user spotted.
            if !item.statusMessages.isEmpty {
                QueueStatusMessagesBanner(
                    messages: item.statusMessages,
                    tint: item.status.tint,
                    actionURL: arrWebURLForItem?(item)
                )
            }

            // External NEW/OLD upgradeDiff grid dropped — the `└─ OLD`
            // sub-line rendered inside `DownloadProgressCard` (via
            // `showUpgradeDiff: true`) handles the upgrade context
            // with the same tree-branch pattern every other surface
            // uses. One diff format, one source of truth.
            // File / quality block. Wraps the format chips, the
            // release filename, and the existing-file twin (when
            // upgrading) in a single quiet container so the
            // chrome-less inner content reads as a grouped section
            // without needing a caption header. The container is
            // shown whenever at least one of its children would
            // render — otherwise the wrapper would paint an empty
            // tinted card.
            let hasFormats = showCustomFormats && !item.customFormats.isEmpty
            let hasRelease = !(item.releaseName ?? "").isEmpty
            let hasExisting = item.isUpgrade
                && (item.existingFileName != nil || item.existingQuality != nil
                    || !item.existingCustomFormats.isEmpty)
            if hasFormats || hasRelease || hasExisting {
                VStack(alignment: .leading, spacing: 6) {
                    if hasFormats {
                        // New-spec chip strip — chips not in the
                        // existing file render green (added).
                        CustomFormatChips(
                            formats: item.customFormats,
                            score: 0,
                            existingFormats: item.isUpgrade ? item.existingCustomFormats : nil
                        )
                    }
                    if hasRelease, let release = item.releaseName {
                        // Release filename — just the new file's path.
                        // Sibling to the existing-file block below;
                        // both use monospace, distinguished only by
                        // foregroundStyle (primary vs secondary).
                        Text(release)
                            .scaledFont(size: 11, design: .monospaced)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    if hasExisting {
                        // Existing-file twin. Same component used by
                        // the in-library detail path; passing
                        // `comparingTo:` colour-codes removed chips
                        // red against the new release.
                        ExistingFileBanner(item: item, comparingTo: item.customFormats)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card)
                )
            }
        }
    }

    /// Wrapper that defers to the public `ListingBadgesView`. Kept so the
    /// DownloadSection's existing `if showListingBadges` block doesn't need
    /// to reach into the public namespace.
    @ViewBuilder
    private func listingBadges(_ item: QueueItem) -> some View {
        ListingBadgesView(item: item)
    }

    @ViewBuilder
    private func upgradeDiff(_ item: QueueItem) -> some View {
        // VStack of two HStack rows — earlier `Grid + GridRow`
        // implementation flattened the nested `qualityCells` HStack
        // into per-Text columns, which made every quality / size /
        // score / tag stack vertically across the two rows. VStack
        // keeps each side of the NEW/OLD diff as a single horizontal
        // run.
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DiffTag(text: "NEW", style: .new)
                qualityCells(
                    quality: item.quality,
                    size: item.sizeTotal,
                    score: item.customFormatScore,
                    tags: item.customFormats
                )
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DiffTag(text: "OLD", style: .old)
                qualityCells(
                    quality: item.existingQuality,
                    size: item.existingSize ?? 0,
                    score: item.existingCustomFormatScore ?? 0,
                    tags: item.existingCustomFormats
                )
            }
        }
    }

    @ViewBuilder
    private func qualityCells(quality: String?, size: Int64, score: Int, tags: [String]) -> some View {
        // Tag chips dropped from the per-row inline — they wrap
        // unpredictably and at >4 tags overflow the diff row.
        // CustomFormatChips + CustomFormatDiff strip rendered below
        // the diff already shows the tag delta in a wrapping flow
        // layout. Diff row stays compact: quality · size · score.
        HStack(spacing: 4) {
            if let q = quality, !q.isEmpty {
                Text(q)
            } else {
                Text(verbatim: "—").foregroundStyle(.tertiary)
            }
            if size > 0 {
                SeparatorDot()
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            if score != 0 {
                SeparatorDot()
                let sign = score > 0 ? "+" : ""
                Text(verbatim: "\(sign)\(score)")
                    .foregroundStyle(score > 0 ? Color.green : Color.red)
                    .scaledFont(size: 11, weight: .semibold)
            }
        }
        .scaledFont(size: 11)
        .foregroundStyle(.secondary)
    }

    // MARK: Multi-item

    @ViewBuilder
    private var multiItemBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard listCollapsible else { return }
                withAnimation(.smooth(duration: 0.18)) { listExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if listCollapsible {
                        Image(systemName: "chevron.right")
                            .scaledFont(size: 9, weight: .semibold)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(listExpanded ? 90 : 0))
                    }
                    Text("In queue", bundle: .module)
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                    SeparatorDot()
                    Text(String(format: String(localized: "%lld downloads", bundle: .module), items.count))
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: aggregateSizeText)
                        .scaledFont(size: 11, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!listCollapsible)

            if !listCollapsible || listExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sortedItems) { it in
                        MultiRow(
                            item: it,
                            isFocused: it.id == focused.id,
                            showInlineUpgrade: showInlineUpgrade,
                            showCustomFormats: showCustomFormats,
                            hoverDetail: rowHoverDetail,
                            onTap: onTapItem.map { fn in { fn(it) } },
                            onPause: onPauseItem.map { fn in { fn(it) } },
                            onResume: onResumeItem.map { fn in { fn(it) } },
                            onDelete: onDeleteItem.map { fn in { fn(it) } }
                        )
                    }
                }
            }
        }
    }

    private var aggregateSizeText: String {
        let total = items.reduce(Int64(0)) { $0 + $1.sizeTotal }
        let left = items.reduce(Int64(0)) { $0 + $1.sizeLeft }
        let done = max(0, total - left)
        let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        let doneStr = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
        return "\(doneStr) / \(totalStr)"
    }
}
