import Foundation

/// Public handle for the ArrCore Swift package's resource bundle.
///
/// `Bundle.module` is synthesized as `internal` so the app target (which
/// imports ArrCore) can't reach it. App-target code that needs to look
/// up a string from ArrCore's `Localizable.xcstrings` — menu titles,
/// alert text, window titles — uses this accessor instead.
public extension Bundle {
    static let arrCore: Bundle = .module
}
