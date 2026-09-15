// swift-tools-version: 6.2
import PackageDescription

// The shared media data layer. It lives in the TonightBarr repo while it
// grows, but nothing in it may know about TonightBarr: no SwiftUI, no
// SwiftData, no app config, no UI shapes. When ArrBarr is ready to adopt it,
// this directory moves out to its own repo unchanged — which is only possible
// if the platform floor and the dependency list stay ArrBarr-compatible.
let package = Package(
    name: "MediaKit",
    platforms: [
        // ArrCore's floor, not TonightBarr's stricter macOS 15 — see above.
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "MediaKit", targets: ["MediaKit"]),
    ],
    targets: [
        .target(
            name: "MediaKit",
            path: "Sources/MediaKit",
            // Swift 6 language mode from day one. The apps still compile in
            // v5 mode; a data layer crossing actors is exactly the code that
            // should be checked strictly.
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MediaKitTests",
            dependencies: ["MediaKit"],
            path: "Tests/MediaKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
