import SwiftUI

extension PopoverContentView {
    // MARK: - Tab bar

    /// Same Control gate and spring as the tab pill, so ⌘1/2/3 and a click are the same action.
    func selectTab(_ tab: Tab) {
        if tab == .chat && !storeManager.isPro {
            storeManager.gate(.chat)
            return
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selectedTab = tab }
    }

    var visibleTabs: [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .chat: return configStore.aiConfigured
            default:    return true
            }
        }
    }

    /// "More picks" can only come from the agent: this prompt makes it call `discover_in_quiz`
    /// with `append: true`; mood and shown picks are already in the chat history.
    func requestMoreQuizPicks() {
        // No LLM, or a turn already running: the message would never resolve.
        guard configStore.aiConfigured, !chatHolder.vm.isThinking else { return }
        // In-app language, not the process one (see AppLocalized), or the prompt lags a live switch.
        let prompt = AppLocalized.string("discover.moreLikeThese.chatPrompt", locale: configStore.currentLocale)
        Task { await chatHolder.vm.send(prompt) }
    }

    var tabBar: some View {
        // One container so the islands morph together. `spacing: 0` because the container fuses
        // glass within its spacing — at 8 the two islands became one blob.
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 8) {
                tabPills
                    .frame(maxWidth: .infinity)
                    .glassyFloatingBar()
                    .glassEffectID("tabs", in: barGlass)
                accessoryIsland
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// Sized from the tab cluster's measured height so the two capsules cannot drift apart.
    private var accessoryIsland: some View {
        #if os(macOS)
        let hasClose = isDetachedWindow && onCloseWindow != nil
        #else
        let hasClose = false
        #endif
        let side = barHeight
        return HStack(spacing: 0) {
            moreMenu
            #if os(macOS)
            // The traffic lights are hidden; the menu-bar panel dismisses itself on focus loss.
            if isDetachedWindow, let onCloseWindow {
                windowCloseButton(action: onCloseWindow)
            }
            #endif
        }
        .frame(width: hasClose ? side * 2 : side, height: side)
        // Explicit circle: the glass pads its bounds and a capsule re-derives its radius from that.
        .glassyFloatingBar(circular: !hasClose)
        .glassEffectID("accessory", in: barGlass)
    }

    private var barHeight: CGFloat {
        tabFrames.values.map(\.height).max() ?? 32
    }

    #if os(macOS)
    private func windowCloseButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: Self.glyphButton, height: Self.glyphButton)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(Text("Close window", bundle: .module))
        .accessibilityLabel(Text("Close window", bundle: .module))
    }
    #endif

    /// Measured frames, because localized labels range from "Chat" (~25 pt) to "Nadchodzące"
    /// (~80 pt) and equal-width segments truncated.
    private struct TabFrames: PreferenceKey {
        static var defaultValue: [Tab: CGRect] = [:]
        static func reduce(value: inout [Tab: CGRect], nextValue: () -> [Tab: CGRect]) {
            value.merge(nextValue()) { _, new in new }
        }
    }

    private var commandHeld: Bool {
        #if os(macOS)
        commandKey.isHeld
        #else
        false
        #endif
    }

    private func commandHint(for tab: Tab) -> String? {
        #if os(macOS)
        guard commandKey.isHeld, let index = visibleTabs.firstIndex(of: tab), index < 9 else { return nil }
        return "⌘\(index + 1)"
        #else
        return nil
        #endif
    }

    private var tabPills: some View {
        HStack(spacing: 0) {
            // Edge spacers split the extra width into uniform gutters instead of clumping tabs left.
            Spacer(minLength: 0)
            ForEach(Array(visibleTabs.enumerated()), id: \.element) { _, tab in
                Button {
                    if tab == .chat && !storeManager.isPro {
                        storeManager.gate(.chat)
                        return
                    }
                    // Re-tapping the active tab clears the query. Not from Chat: it doesn't show the field.
                    if tab == selectedTab, tab.hostsSearch, searchViewModel.isActive {
                        withAnimation(.easeOut(duration: 0.18)) {
                            searchViewModel.query = ""
                        }
                    }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selectedTab = tab }
                } label: {
                    // Invisible semibold copy fixes the width, or the regular→semibold switch resizes the tab
                    // out of band from the selection spring and the indicator's width snaps.
                    HStack(spacing: 3) {
                        // Explicit `.transition(.opacity)`: otherwise the inserted Text slides in from the left
                        // inside the animated relayout instead of crossfading.
                        if selectedTab == tab && !commandHeld {
                            // No `fixedSize`: an incompressible "Nadchodzące" pill pushed the detached bar past the
                            // 400 pt panel and the content bled past the window edges.
                            Text(LocalizedStringKey(tab.rawValue), bundle: .module)
                                .scaledFont(size: 12, weight: .semibold)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                // 0.75: the squeeze needs ~20 pt back; a higher floor makes SwiftUI truncate instead of scale.
                                .minimumScaleFactor(0.75)
                                .transition(.opacity)
                        } else {
                            Image(systemName: tab.symbol)
                                .scaledFont(size: 13, weight: .medium)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text(LocalizedStringKey(tab.rawValue), bundle: .module))
                                .help(Text(LocalizedStringKey(tab.rawValue), bundle: .module))
                                .transition(.opacity)
                        }
                        if tab == .chat && !storeManager.isPro {
                            Image(systemName: "lock.fill")
                                .scaledFont(size: 9, weight: .semibold)
                                .foregroundStyle(.secondary)
                        }
                        // In the layout rather than an overlay: every pill reshapes while ⌘ is held anyway, and
                        // the animated `tabFrames` glide absorbs it.
                        if let hint = commandHint(for: tab) {
                            Text(hint)
                                .scaledFont(size: 9, weight: .semibold)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                                .transition(.opacity)
                                .accessibilityHidden(true)
                        }
                    }
                    // No `fixedSize` either — same overflow as the label above.
                    .padding(.horizontal, 18)
                    // Padding, not a fixed height, so the bar grows with the user's text size.
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: TabFrames.self,
                                value: [tab: proxy.frame(in: .named("tabPills"))]
                            )
                        }
                    )
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
        .coordinateSpace(name: "tabPills")
        #if os(macOS)
        .animation(.easeOut(duration: 0.12), value: commandKey.isHeld)
        #endif
        .onPreferenceChange(TabFrames.self) { newFrames in
            // This preference fires out of band from the selection spring; animating with the same
            // spring stops the indicator snapping mid-flight. First layout has nothing to glide from.
            if tabFrames.isEmpty {
                tabFrames = newFrames
            } else {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    tabFrames = newFrames
                }
            }
        }
        .background(
            // `.position()` in an explicit GeometryReader: a `.background(ZStack).offset` mis-aligned by
            // one tab on macOS when the implicit ZStack's bounds didn't match the HStack's.
            GeometryReader { geo in
                if let rect = selectionPillRect(in: geo.size) {
                    TabPillBackground()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        )
    }

    /// Fills the tab's slot (label plus half of each gutter) measured from `tabFrames`, so it
    /// neither under-fills the popover nor spills when the detached × squeezes the tabs.
    private func selectionPillRect(in container: CGSize) -> CGRect? {
        guard let frame = tabFrames[selectedTab] else { return nil }
        let ordered = visibleTabs
            .compactMap { tab in tabFrames[tab].map { (tab, $0) } }
            .sorted { $0.1.minX < $1.1.minX }
        guard let idx = ordered.firstIndex(where: { $0.0 == selectedTab }) else { return nil }

        let gap: CGFloat = 3
        // Outer edges reach halfway to the bar's inner edge, so every pill is symmetric.
        let leftEdge = idx > 0
            ? (ordered[idx - 1].1.maxX + frame.minX) / 2 + gap
            : frame.minX / 2
        let rightEdge = idx < ordered.count - 1
            ? (ordered[idx + 1].1.minX + frame.maxX) / 2 - gap
            : (frame.maxX + container.width) / 2

        let height = max(0, frame.height - 6)
        return CGRect(x: leftEdge, y: frame.midY - height / 2,
                      width: max(0, rightEdge - leftEdge), height: height)
    }

    /// Shorter than the tab labels, so a glyph can never stretch the bar.
    private static let glyphButton: CGFloat = 28

    /// The frame must sit outside the Menu: `.fixedSize()` collapses a Menu to its bare glyph
    /// (~12×4 pt) and the glass capsule hugs that instead of a circle.
    var moreMenu: some View {
        Menu {
            if selectedTab == .queue, viewModel.activeCount > 0 {
                Button { queueSelecting = true } label: {
                    Label { Text("queue.selectMultiple.button", bundle: .module) } icon: { Image(systemName: "checkmark.circle") }
                }
            }
            if selectedTab == .queue, !QueueUIState.shared.hiddenQueueItems.isEmpty {
                Toggle(isOn: Bindable(QueueUIState.shared).showHiddenQueueItems) {
                    Label { Text("queue.showHidden.button", bundle: .module) } icon: { Image(systemName: "eye") }
                }
            }
            if selectedTab == .queue, viewModel.activeCount > 0 || !QueueUIState.shared.hiddenQueueItems.isEmpty {
                Divider()
            }
            // No "Refresh" item: the queue refreshes itself and ⌘R stays.
            Button { onOpenSettings() } label: { Text("common.settings2.button", bundle: .module) }
                .keyboardShortcut(",", modifiers: .command)
            #if os(macOS)
            Button { onShowAbout() } label: { Text("settings.aboutArrbarr.button", bundle: .module) }
            // In the menu, not its own glyph: the detached bar has no width to spare. AppDelegate
            // observes `$detachedWindow` and opens/closes the window.
            Button {
                let wasInPopover = !isDetachedWindow
                configStore.detachedWindow.toggle()
                // Re-attaching is handled by AppDelegate closing the NSWindow.
                if wasInPopover { dismiss() }
            } label: {
                Text(isDetachedWindow ? "common.reattachToMenuBar.button" : "common.detachIntoAWindow.button", bundle: .module)
            }
            #endif
            Divider()
            Button { onQuit() } label: { Text("common.quitArrbarr.button", bundle: .module) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: Self.glyphButton, height: Self.glyphButton)
        .contentShape(Capsule())
        .help(Text("common.moreOptions.button", bundle: .module))
    }
}
