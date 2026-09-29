import SwiftUI

extension QueueListView {
    /// Header row plus sibling rows so collapse animates as native row
    /// insert/remove instead of one growing cell.
    @ViewBuilder
    func needsYouSection() -> some View {
        let collapsed = queueUI.isCollapsed(ConfigStore.needsYouOrderKey)
        NeedsYouHeader(
            count: viewModel.needsYou.count,
            isCollapsed: collapsed,
            onToggle: {
                withAnimation(.smooth(duration: 0.22)) {
                    queueUI.toggleCollapsed(ConfigStore.needsYouOrderKey)
                }
            }
        )
        .plainQueueRow(insets: Self.headerRowInsets)
        if !collapsed {
            ForEach(viewModel.needsYou) { needs in
                NeedsYouRow(needs: needs, onTap: { needsYouItemTapped(needs) })
                    .plainQueueRow()
            }
        }
    }

    private func needsYouItemTapped(_ needs: NeedsYouItem) {
        if let onNeedsYouTap {
            onNeedsYouTap(needs)
        } else if let itemId = needs.item?.id {
            let match = QueueItem.Source.allCases.lazy
                .compactMap { viewModel.items(for: $0).first(where: { $0.id == itemId }) }
                .first
            if let match { onShowDetail(match) }
        }
    }

    #if os(macOS)
    /// Sibling rows, like `needsYouSection`, so collapse animates as row insert/remove.
    @ViewBuilder
    func tonightSection() -> some View {
        let items = viewModel.tonight
        // 0 = "always show all" (Settings).
        let limit = configStore.tonightVisibleCount
        let visible = (viewModel.tonightExpanded || limit == 0) ? items : Array(items.prefix(limit))
        let overflow = items.count - visible.count
        let collapsed = queueUI.isCollapsed(ConfigStore.tonightOrderKey)
        QueueHeaderRow(
            icon: AnyView(
                Image(systemName: "calendar")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            ),
            title: String(localized: "queue.nextWeek.button", bundle: .module),
            collapsed: collapsed,
            onToggle: {
                withAnimation(.smooth(duration: 0.22)) {
                    queueUI.toggleCollapsed(ConfigStore.tonightOrderKey)
                }
            }
        )
        .plainQueueRow(insets: Self.headerRowInsets)
        if !collapsed {
            ForEach(Array(visible.enumerated()), id: \.element.id) { offset, item in
                TonightBannerRow(
                    item: item,
                    timeString: item.airDateCompact(locale: configStore.currentLocale),
                    onTap: { openUpcomingDetail(item) }
                )
                .padding(.top, offset == 0 ? 4 : 0)
                .padding(.leading, QueueHeaderMetrics.contentIndent)
                .padding(.trailing, Tokens.Spacing.queueRowH)
                .plainQueueRow()
            }
            if overflow > 0 && !viewModel.tonightExpanded {
                tonightShowMoreButton
                    .padding(.leading, QueueHeaderMetrics.contentIndent)
                    .plainQueueRow()
            } else if viewModel.tonightExpanded && limit != 0 && items.count > limit {
                tonightShowLessButton
                    .padding(.leading, QueueHeaderMetrics.contentIndent)
                    .plainQueueRow()
            }
        }
    }

    private var tonightShowMoreButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.22)) {
                viewModel.setTonightExpanded(true)
            }
            scheduleBannerCollapse()
        } label: {
            HStack(spacing: 3) {
                Text("queue.showMore.button", bundle: .module)
                    .scaledFont(size: 10)
                Image(systemName: "chevron.down")
                    .scaledFont(size: 9, weight: .medium)
            }
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private var tonightShowLessButton: some View {
        Button {
            bannerCollapseTask?.cancel()
            withAnimation(.smooth(duration: 0.22)) {
                viewModel.setTonightExpanded(false)
            }
        } label: {
            HStack(spacing: 3) {
                Text("discover.showLess.button", bundle: .module)
                    .scaledFont(size: 10)
                Image(systemName: "chevron.up")
                    .scaledFont(size: 9, weight: .medium)
            }
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    /// Picked up by the popover's `Router.detail` observer.
    private func openUpcomingDetail(_ item: UpcomingItem) {
        guard let entityId = item.entityId else { return }
        DetailRequest.post(
            DetailRequest.syntheticItem(
                source: item.source,
                entityId: entityId,
                title: item.title,
                posterURL: item.posterURL,
                posterRequiresAuth: item.posterRequiresAuth
            )
        )
    }

    private func scheduleBannerCollapse() {
        bannerCollapseTask?.cancel()
        bannerCollapseTask = Task { [viewModel] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { return }
            withAnimation(.smooth(duration: 0.22)) {
                viewModel.setTonightExpanded(false)
            }
        }
    }

    #endif
}
