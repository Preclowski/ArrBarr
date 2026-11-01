import SwiftUI
import ArrCore

@main
struct ArrBarrApp: App {
    // Before every other stored property, so the flag is set before `ConfigStore.shared`
    // picks its secret store. `#if APPSTORE` is live here, unlike inside ArrCore.
    #if APPSTORE
    private let _capabilities: Void = { AppCapabilities.configure(isAppStore: true) }()
    #endif

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var queueVM = QueueViewModel.shared
    private var configStore: ConfigStore { .shared }

    init() {
        // Before the first localized lookup, so model-layer strings match the UI language.
        ConfigStore.applyAppLanguageToProcess()
        #if APPSTORE
        StoreManager.shared.use(StoreKitBackend())
        KVSyncCoordinator.startShared()
        #endif
    }

    var body: some Scene {
        // `style: .window` gives SwiftUI a real window context, so NavigationStack renders native chrome.
        // Read-only `isInserted` setter: the Settings toggle owns visibility, not ⌘-drag.
        MenuBarExtra(isInserted: Binding(
            get: { !configStore.detachedWindow },
            set: { _ in }
        )) {
            PopoverContentView(
                viewModel: queueVM,
                onOpenSettings: { appDelegate.openSettings() },
                onShowAbout: { appDelegate.showAbout() },
                onQuit: { NSApp.terminate(nil) }
            )
            .environment(configStore)
            #if !APPSTORE
            .background(PanelBlurBackground().ignoresSafeArea())
            #endif
        } label: {
            // A custom (non-symbol) image inside a `Label` suppresses the title in the status item.
            let active = queueVM.activeCount
            HStack(spacing: 2) {
                Image("MenuBarGlyph").renderingMode(.template)
                if active > 0 {
                    Text("\(active)")
                }
            }
            // The app's only entry point: an asset image would otherwise be announced by its file name.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "ArrBarr"))
            .accessibilityValue(active > 0
                ? String.localizedStringWithFormat(String(localized: "queue.titleGroup.downloadsCount", bundle: .arrCore), active)
                : "")
        }
        .menuBarExtraStyle(.window)

        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) { }
                CommandGroup(replacing: .appInfo) {
                    Button {
                        appDelegate.showAbout()
                    } label: {
                        Text("About ArrBarr", bundle: .arrCore)
                    }
                }
            }
    }
}

#if !APPSTORE
/// A touch more blur behind the panel, whose glass has no setting for it. A stock effect view blurs far too much
/// (radius 30, nothing behind stays readable), so this lowers its private backdrop filter. App Store builds keep the glass.
private struct PanelBlurBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = EffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    private final class EffectView: NSVisualEffectView {
        private static let blurRadius = 6.0

        override func layout() {
            super.layout()
            setBlurRadius()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            setBlurRadius()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            setBlurRadius()
        }

        /// Next tick: the view builds its layers after these callbacks.
        private func setBlurRadius() {
            DispatchQueue.main.async { [weak self] in
                if let layer = self?.layer { Self.setBlurRadius(on: layer) }
            }
        }

        private static func setBlurRadius(on layer: CALayer) {
            if (layer.filters ?? []).contains(where: { String(describing: $0).contains("gaussianBlur") }) {
                layer.setValue(blurRadius, forKeyPath: "filters.gaussianBlur.inputRadius")
            }
            layer.sublayers?.forEach(setBlurRadius)
        }
    }
}
#endif
