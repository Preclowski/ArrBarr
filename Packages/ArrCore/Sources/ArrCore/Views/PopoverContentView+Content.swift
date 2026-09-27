import SwiftUI

extension PopoverContentView {
    var mainContent: some View {
        // Overlays sit in a ZStack so the tab content stays mounted and keeps its scroll
        // positions; History still swaps the surface.
        NavigationStack {
        ZStack {
            VStack(spacing: 0) {
                if let historySource {
                    HistoryView(
                        source: historySource,
                        viewModel: viewModel,
                        // Not through `DetailRouter`, whose handler drops the history surface — Back must land here.
                        onOpenDetail: { item in
                            withAnimation(.smooth(duration: 0.22)) { detailItem = item }
                        },
                        onClose: { self.historySource = nil }
                    )
                } else if anyArrConfigured {
                    // A live query makes search a full-size surface; its back chevron is the nav.
                    Group {
                        if selectedTab == .chat {
                            ChatTabContent(chatHolder: chatHolder)
                        } else {
                            SearchHost(
                                searchVM: searchViewModel,
                                localHits: localHits,
                                searchAvailable: anyArrConfigured,
                                focused: $searchFieldFocused,
                                onSelectQueueItem: { detailItem = $0 },
                                onSelectAddResult: { searchResult = $0 }
                            ) {
                                switch selectedTab {
                                case .queue:
                                    QueueTabContent(
                                        viewModel: viewModel,
                                        detailItem: $detailItem,
                                        historySource: $historySource,
                                        selecting: $queueSelecting
                                    )
                                case .library:
                                    LibraryTabContent(viewModel: libraryViewModel)
                                case .upcoming, .chat:
                                    UpcomingTabContent(viewModel: viewModel)
                                }
                            }
                        }
                    }
                    // In the safe area, not a VStack row: the list scrolls under the glass and the system draws
                    // its soft scroll-edge blur (with `.scrollEdgeEffectStyle(.soft)` on each tab).
                    .safeAreaBar(edge: .top, spacing: 0) {
                        if !(searchViewModel.isActive && selectedTab.hostsSearch) {
                            tabBar
                        }
                    }
                } else {
                    PopoverEmptyState(onOpenSettings: onOpenSettings) { moreMenu }
                }
            }
            // Parking takes all four mechanisms; skipping one leaks. `.disabled` is what stops an
            // invisible TextField handing its I-beam to the overlay drawn over it.
            .opacity(tabContentParked ? Self.parkedOpacity : 1)
            .allowsHitTesting(!tabContentParked)
            .disabled(tabContentParked)
            .accessibilityHidden(tabContentParked)

            if discoverViewModel.isPresented {
                DiscoverTabView(
                    viewModel: discoverViewModel,
                    llmAvailable: configStore.aiConfigured,
                    radarrAvailable: radarrConfigured,
                    // The top-up round is a chat turn, so the deck waits on the agent's thinking flag.
                    moreInFlight: chatHolder.vm.isThinking,
                    isObscured: discoverParked,
                    onClose: {
                        withAnimation(.smooth(duration: 0.22)) { discoverViewModel.isPresented = false }
                    },
                    onCancelLoading: {
                        chatHolder.vm.cancelTurn()
                        discoverViewModel.endLoading()
                    },
                    onRequestMore: requestMoreQuizPicks
                )
                // Parked with all four mechanisms too; the detail surface has no opaque background.
                .opacity(discoverParked ? Self.parkedOpacity : 1)
                .allowsHitTesting(!discoverParked)
                .disabled(discoverParked)
                .accessibilityHidden(discoverParked)
                .transition(.opacity)
            }

            if searchResult != nil {
                searchAddOverlay
                    .transition(.opacity)
            }

        }
        // The view model opens the deck (possibly mid-rebuild), so the fade lives here rather
        // than in a `withAnimation` around the flag.
        .animation(.smooth(duration: 0.22), value: discoverViewModel.isPresented)
        .personDestination($personRef)
        .navigationDestination(item: $detailItem) { item in
            // Episode rows open the episode; the series is reachable via its "series name >" tap.
            if isSonarrEpisodeRow(item) {
                // EpisodeQuickDetail owns the series push, so back returns to the episode.
                EpisodeQuickDetail(
                    item: item,
                    viewModel: viewModel,
                    onBack: { self.detailItem = nil }
                )
            } else {
                DetailView(
                    item: item,
                    onBack: { self.detailItem = nil },
                    viewModel: viewModel
                )
            }
        }
        }
        .frame(width: 400, height: 600)
        // Transparent so NSPopover's native chrome shows through, one step darker than the backdrop.
        // A rim-light overlay cut through where the popover's arrow attaches.
        .background(Color.black.opacity(0.10))
    }

    /// Back branches on `searchAddFromChat`: chat origins return to chat.
    @ViewBuilder
    private var searchAddOverlay: some View {
        if let result = searchResult {
            SearchAddPanel(result: result, viewModel: searchViewModel) {
                if searchAddFromChat {
                    searchAddFromChat = false
                    searchResult = nil
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        selectedTab = .chat
                    }
                } else {
                    searchResult = nil
                }
            }
        }
    }
}
