// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "MediaKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "MediaKit", targets: ["MediaKit"]),
        .library(name: "MediaKitRecording", targets: ["MediaKitRecording"]),
        .executable(name: "mediakit-record", targets: ["mediakit-record"]),
    ],
    targets: [
        .target(
            name: "MediaKit",
            path: "Sources/MediaKit",
            resources: [.copy("Fixtures")],
            swiftSettings: strict
        ),
        .target(
            name: "MediaKitRecording",
            dependencies: ["MediaKit"],
            path: "Sources/MediaKitRecording",
            swiftSettings: strict
        ),
        .executableTarget(
            name: "mediakit-record",
            dependencies: ["MediaKit", "MediaKitRecording"],
            path: "Sources/mediakit-record",
            swiftSettings: strict
        ),
        .testTarget(
            name: "MediaKitTests",
            dependencies: ["MediaKit", "MediaKitRecording"],
            path: "Tests/MediaKitTests",
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(nil)]
        ),
    ]
)
