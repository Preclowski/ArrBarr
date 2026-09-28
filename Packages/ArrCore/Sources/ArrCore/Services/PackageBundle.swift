import Foundation

/// `Bundle.module` is synthesized `internal`, so app targets reach ArrCore's
/// string catalog through this.
public extension Bundle {
    nonisolated static let arrCore: Bundle = .module
}
