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
                        // Not through `Router.detail`, whose handler drops the history surface — Back must land here.
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
                        } else if selectedTab == .shelf {
                            ShelfView(isObscured: tabContentParked)
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
                                case .upcoming, .chat, .shelf:
                                    UpcomingTabContent(viewModel: viewModel)
                                }
                            }
                        }
                    }
                    // In the safe area, not a VStack row: the list scrolls under the glass and the system draws
                    // its soft scroll-edge blur (with `.scrollEdgeEffectStyle(.soft)` on each tab).
                    .safeAreaBar(edge: .top, spacing: 0) {
                        if !(searchViewModel.isActive && selectedTab.hostsSearch) {
                            // Shelf's stage runs under the bar and is always dark.
                            tabBar
                                .environment(\.colorScheme, selectedTab == .shelf ? .dark : colorScheme)
                        }
                    }
                } else {
                    PopoverEmptyState(onOpenSettings: onOpenSettings) { moreMenu }
                }
            }
            .parked(tabContentParked, opacity: Self.parkedOpacity)

            if discoverViewModel.isPresented {
                DiscoverTabView(
                    viewModel: discoverViewModel,
                    llmAvailable: configStore.aiConfigured,
                    radarrAvailable: radarrConfigured,
                    // The top-up round is a chat turn, so the deck waits on the agent's thinking flag.
                    moreInFlight: chatHolder.vm.isThinking,
                    isObscured: discoverParked,
                    onClose: {
                        withAnimation(.smooth(duration: 0.22)) { discoverViewModel.close() }
                    },
                    onCancelLoading: {
                        chatHolder.vm.cancelTurn()
                        discoverViewModel.endLoading()
                    },
                    onRequestMore: requestMoreQuizPicks
                )
                // The detail surface has no opaque background.
                .parked(discoverParked, opacity: Self.parkedOpacity)
                .transition(.opacity)
            }

            if searchResult != nil {
                searchAddOverlay
                    // Only a quiz open animates: the card has just flown off, and the panel settles in its place.
                    .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity),
                                            removal: .scale(scale: 0.96).combined(with: .opacity)))
            }

        }
        // The view model opens the deck (possibly mid-rebuild), so the fade lives here rather
        // than in a `withAnimation` around the flag.
        .animation(.smooth(duration: 0.22), value: discoverViewModel.isPresented)
        .personDestination($personRef)
        .navigationDestination(item: $detailItem) { item in
            Group {
                // Episode rows open the episode; the series is reachable via its "series name >" tap.
                if item.opensEpisodeDetail {
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
            .settleEntrance()
        }
        }
        // A push animates its own entrance; the stack's side slide would fight it. Back keeps the slide.
        .transaction(value: detailItem?.id) { if detailItem != nil { $0.disablesAnimations = true } }
        .frame(width: 400, height: 600)
        // Transparent so NSPopover's native chrome shows through, one step darker than the backdrop.
        // A rim-light overlay cut through where the popover's arrow attaches.
        .background(Color.black.opacity(0.10))
    }

    /// Back branches on `searchAddOrigin`: chat origins return to chat.
    @ViewBuilder
    private var searchAddOverlay: some View {
        if let result = searchResult {
            SearchAddPanel(result: result, viewModel: searchViewModel) {
                switch searchAddOrigin {
                case .chat:
                    searchResult = nil
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        selectedTab = .chat
                    }
                case .quiz:
                    withAnimation(QuizMotion.panelOut) { searchResult = nil }
                default:
                    searchResult = nil
                }
                searchAddOrigin = nil
            }
        }
    }
}
