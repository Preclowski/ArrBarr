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
        // 1. Status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        updateStatusBarTitle(active: queueVM.activeCount)

        // 2. Popover z SwiftUI
        popover = NSPopover()
        popover.behavior = .transient        // zamknij gdy klik poza
        popover.contentSize = NSSize(width: 400, height: 480)
        popover.delegate = self

        let root = PopoverContentView(
            viewModel: queueVM,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        .environmentObject(configStore)

        popover.contentViewController = NSHostingController(rootView: root)

        // 3. Reaktywny update badge'a
        badgeObserver = Publishers.CombineLatest(queueVM.$radarr, queueVM.$sonarr)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] radarr, sonarr in
                let active = (radarr + sonarr).filter { $0.status != .completed }.count
                self?.updateStatusBarTitle(active: active)
            }
    }

    // MARK: - Status item rendering

    private func updateStatusBarTitle(active: Int) {
        guard let button = statusItem.button else { return }

        let symbolName = active > 0 ? "arrow.down.circle.fill" : "arrow.down.circle"
        let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ArrBarr")
        icon?.isTemplate = true

        if active > 0 {
            // Ikona + liczba
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = CGRect(x: 0, y: -3, width: 16, height: 16)
            let imageString = NSAttributedString(attachment: attachment)

            let mutable = NSMutableAttributedString()
            mutable.append(imageString)
            mutable.append(NSAttributedString(
                string: " \(active)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
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

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            queueVM.startForegroundPolling()
        }
    }

    // MARK: - Settings window

    private func openSettings() {
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
        win.setContentSize(NSSize(width: 480, height: 540))
        win.isReleasedWhenClosed = false
        win.center()

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
