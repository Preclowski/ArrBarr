import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?

    private let configStore = ConfigStore.shared
    private let queueVM = QueueViewModel()
    private var badgeObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusBarTitle(active: queueVM.activeCount)

        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self

        let root = PopoverContentView(
            viewModel: queueVM,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        .environmentObject(configStore)

        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        badgeObserver = Publishers.CombineLatest(queueVM.$radarr, queueVM.$sonarr)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] radarr, sonarr in
                MainActor.assumeIsolated {
                    let active = (radarr + sonarr).filter { $0.status != .completed }.count
                    self?.updateStatusBarTitle(active: active)
                }
            }
    }

    // MARK: - Status item

    private func updateStatusBarTitle(active: Int) {
        guard let button = statusItem.button else { return }

        let a11yLabel = active > 0
            ? "ArrBarr — \(active) active download\(active == 1 ? "" : "s")"
            : "ArrBarr — no active downloads"
        let symbolName = active > 0 ? "arrow.down.circle.fill" : "arrow.down.circle"
        let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: a11yLabel)
        icon?.isTemplate = true

        if active > 0 {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = CGRect(x: 0, y: -3, width: 16, height: 16)

            let mutable = NSMutableAttributedString()
            mutable.append(NSAttributedString(attachment: attachment))
            mutable.append(NSAttributedString(
                string: " \(active)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
                ]
            ))
            button.attributedTitle = mutable
            button.image = nil
        } else {
            button.image = icon
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    // MARK: - Popover

    @objc private func statusItemClicked(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.option) {
            showStatusMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            queueVM.startForegroundPolling()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh", action: #selector(menuRefresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit ArrBarr", action: #selector(menuQuit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuRefresh() { Task { await queueVM.refresh() } }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: - Settings

    private func openSettings() {
        if popover.isShown { popover.performClose(nil) }

        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView().environmentObject(configStore)
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "ArrBarr Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 500, height: 620))
        win.isReleasedWhenClosed = false
        win.center()

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.settingsWindow = nil }
        }

        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        queueVM.stopForegroundPolling()
    }
}
