// swift-tools-version: 6.0
import PackageDescription

// TonightBarr's core, moved into the ArrBarr repo so that it consumes the REAL
// ArrCore instead of a vendored copy. The copy had already drifted 21 files
// behind in two days — which is the cost this move removes.
//
// Its platform floor is stricter than ArrCore's (macOS 15 vs 14); that is
// TonightBarr's own choice and must never leak downward into ArrCore or
// MediaKit, which stay on ArrBarr's floor.
let package = Package(
    name: "TonightCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "TonightCore", targets: ["TonightCore"]),
    ],
    dependencies: [
        .package(path: "../ArrCore"),
        .package(path: "../MediaKit"),
    ],
    targets: [
        .target(
            name: "TonightCore",
            dependencies: [
                .product(name: "ArrCore", package: "ArrCore"),
                .product(name: "MediaKit", package: "MediaKit"),
            ],
            path: "Sources/TonightCore",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TonightCoreTests",
            dependencies: ["TonightCore"],
            path: "Tests/TonightCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
