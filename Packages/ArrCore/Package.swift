// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArrCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ArrCore", targets: ["ArrCore"]),
    ],
    targets: [
        .target(
            name: "ArrCore",
            path: "Sources/ArrCore",
            resources: [
                // Localizable.xcstrings ships inside the package so the
                // macOS app, the iOS app, and the test runner all read
                // strings from the same bundle (`Bundle.module`).
                .process("Resources"),
            ],
            swiftSettings: [
                // Match the existing app target's checking level. Tightening
                // to the 6.0 mode is a separate cleanup — Phase 1 keeps
                // semantics identical so the macOS app builds unchanged.
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "ArrCoreTests",
            dependencies: ["ArrCore"],
            path: "Tests/ArrCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
