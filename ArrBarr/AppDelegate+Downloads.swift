import AppKit
import SwiftUI
import ArrCore

extension AppDelegate {
    // MARK: - Dropped / opened downloads

    /// Dock drop, Finder "Open With" and `magnet:` links all land here. Undownloadable items are ignored,
    /// not refused: a drag may carry a stray file alongside the torrents.
    func application(_ application: NSApplication, open urls: [URL]) {
        enqueueDrops(urls.compactMap(DownloadDrop.init(url:)))
    }

    /// Torrent and usenet go in separate batches: a `.nzb` and a `.torrent` reach different clients even within one arr,
    /// so one "which arr?" answer can't cover both. The second batch opens when the first window closes.
    func enqueueDrops(_ drops: [DownloadDrop]) {
        guard !drops.isEmpty else { return }
        for kind in DownloadKind.allCases {
            let batch = drops.filter { $0.kind == kind }
            if !batch.isEmpty { pendingDropBatches.append(batch) }
        }
        showNextDropBatch()
    }

    private func showNextDropBatch() {
        guard !pendingDropBatches.isEmpty else { return }
        // One window at a time. Surface the open one, or a second drop looks lost.
        if let existing = addDownloadWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let batch = pendingDropBatches.removeFirst()

        let view = AddDownloadView(drops: batch) { [weak self] in
            self?.addDownloadWindow?.close()
        }
        .environmentObject(configStore)
        // Standalone scene: without the injected font-scale preset every scaledFont renders at 1.0.
        .appFontScale(configStore)

        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = String(localized: "Add download", bundle: .arrCore)
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        // Size before centring: `NSHostingController` reports zero size until layout, and centring a zero frame
        // can park the window off-screen, where it looks like a hang.
        win.setContentSize(hosting.view.fittingSize == .zero ? NSSize(width: 420, height: 260) : hosting.view.fittingSize)
        win.center()
        if let screen = NSScreen.main, !screen.visibleFrame.intersects(win.frame) {
            win.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - win.frame.width / 2,
                y: screen.visibleFrame.midY - win.frame.height / 2
            ))
        }
        // An accessory app doesn't activate on Dock drop, so the window would open behind the user's app.
        win.level = .floating
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.addDownloadWindow = nil
                self?.showNextDropBatch()
            }
        }
        addDownloadWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Status-item right-click menu

    /// `MenuBarExtra(.window)` has no right-click affordance, so a local monitor sniffs the status item's window class;
    /// failure degrades to right-click opening the panel.
    func installStatusItemRightClickMenu() {
        statusItemRightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self,
                  let window = event.window,
                  String(describing: type(of: window)).contains("StatusBar"),
                  let contentView = window.contentView
            else { return event }
            NSMenu.popUpContextMenu(self.statusItemContextMenu(), with: event, for: contentView)
            return nil
        }
    }

    private func statusItemContextMenu() -> NSMenu {
        let bundle = Bundle.arrCore
        let menu = NSMenu()
        let settings = NSMenuItem(
            title: String(localized: "common.settings2.button", bundle: bundle),
            action: #selector(statusMenuOpenSettings), keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(
            title: String(localized: "settings.aboutArrbarr.button", bundle: bundle),
            action: #selector(statusMenuShowAbout), keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: String(localized: "common.quitArrbarr.button", bundle: bundle),
            action: #selector(statusMenuQuit), keyEquivalent: ""
        )
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func statusMenuOpenSettings() { openSettings() }
    @objc private func statusMenuShowAbout() { showAbout() }
    @objc private func statusMenuQuit() { NSApp.terminate(nil) }
}
