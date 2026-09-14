import SwiftUI
import SwiftData
import TonightCore

@main
struct TonightBarrApp: App {
    private let container: ModelContainer

    init() {
        // TMDB images are immutable — lean on plain HTTP caching, generously.
        URLCache.shared = URLCache(memoryCapacity: 128 << 20, diskCapacity: 512 << 20)
        do {
            container = try Library.makeContainer()
        } catch {
            // A corrupt store should not brick the app: fall back to memory
            // so the browse experience still works this session.
            container = (try? Library.makeContainer(inMemory: true))!
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(ExternalLibraryStore.shared)
        }
        .modelContainer(container)
        // A hard `minWidth` on the content used to live here. Widening the
        // sidebar until the detail column could no longer honour it made the
        // layout unsatisfiable and AppKit killed the app mid-drag. The
        // window gets a sensible size instead, and no impossible floor.
        .defaultSize(width: 1280, height: 820)
        // The window's minimum comes from the columns' own minimums, so the
        // two can never disagree.
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)

        Settings {
            TonightSettingsView()
        }
    }
}
