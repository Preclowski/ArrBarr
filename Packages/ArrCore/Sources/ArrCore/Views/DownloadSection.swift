import SwiftUI

/// Detail-view download section: one progress card for a single item, or a summary
/// header over compact rows for several episodes of one series.
struct DownloadSection: View {
    let items: [QueueItem]
    let focused: QueueItem
    var showCustomFormats: Bool = false
    var showListingBadges: Bool = false
    var listCollapsible: Bool = false
    var onTapItem: ((QueueItem) -> Void)? = nil
    var onPauseItem: ((QueueItem) -> Void)? = nil
    var onResumeItem: ((QueueItem) -> Void)? = nil
    var onDeleteItem: ((QueueItem) -> Void)? = nil
    /// Resolves the arr web URL per row, for the warning banner's "Open in browser" action.
    var arrWebURLForItem: ((QueueItem) -> URL?)? = nil

    @State private var listExpanded: Bool

    init(
        items: [QueueItem],
        focused: QueueItem,
        showCustomFormats: Bool = false,
        showListingBadges: Bool = false,
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
        self.showCustomFormats = showCustomFormats
        self.showListingBadges = showListingBadges
        self.listCollapsible = listCollapsible
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

    var body: some View {
        if items.count <= 1 {
            VStack(alignment: .leading, spacing: 6) {
                DownloadingSectionHeader(item: focused)
                singleItemBlock(focused)
            }
        } else {
            multiItemBlock
        }
    }

    // MARK: Single item

    @ViewBuilder
    private func singleItemBlock(_ item: QueueItem) -> some View {
        singleItemContent(item)
    }

    @ViewBuilder
    private func singleItemContent(_ item: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showListingBadges {
                listingBadges(item)
            }
            DownloadProgressCard(item: item, showUpgradeDiff: true, showHeader: true, showStatusRow: false)
            // No meta line under the card: it already carries quality, size, score and client.
            if !item.statusMessages.isEmpty {
                QueueStatusMessagesBanner(
                    messages: item.statusMessages,
                    tint: item.status.tint,
                    actionURL: arrWebURLForItem?(item)
                )
            }

            // Upgrades show formats and filenames inside the card's diff; don't render them twice.
            if !item.isUpgrade {
                if showCustomFormats, !item.customFormats.isEmpty {
                    CustomFormatChips(
                        formats: item.customFormats,
                        score: 0
                    )
                }
                ReleaseNameBlock(release: item.releaseName)
            }
        }
    }

    @ViewBuilder
    private func listingBadges(_ item: QueueItem) -> some View {
        ListingBadgesView(item: item)
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
                    Text("queue.inQueue.button", bundle: .module)
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                    SeparatorDot()
                    Text(String.localizedStringWithFormat(NSLocalizedString("unit.downloads", bundle: .module, comment: ""), items.count))
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                    // No aggregate size: each row carries its own spec, like the queue list.
                    Spacer()
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

}
