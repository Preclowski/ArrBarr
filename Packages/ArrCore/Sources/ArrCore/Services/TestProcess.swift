import Foundation

nonisolated enum TestProcess {
    /// No single marker covers both runners: SwiftPM's `swiftpm-testing-helper` can load no XCTest, set no env var
    /// and not list the `.xctest` bundle — then only argv names it.
    static let isActive: Bool = {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil { return true }
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) { return true }
        return ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest") }
    }()
}
