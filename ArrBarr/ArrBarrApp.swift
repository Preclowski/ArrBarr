import SwiftUI

@main
struct ArrBarrApp: App {
    // Cała robota dzieje się w AppDelegate (NSStatusItem, popover).
    // Podstawowa scena nie pokazuje żadnego okna — LSUIElement w Info.plist sprawia,
    // że nie ma ikony w Docku, a to Settings rejestrujemy w AppDelegate ręcznie.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Settings scene jest pusta tylko po to, żeby SwiftUI nie wymagał WindowGroup.
        // Faktyczne ustawienia otwieramy własnym oknem z AppDelegate.
        Settings {
            EmptyView()
        }
    }
}
