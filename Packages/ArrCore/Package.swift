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
            swiftSettings: [
                // Match the existing app target's checking level. Tightening
                // to the 6.0 mode is a separate cleanup — Phase 1 keeps
                // semantics identical so the macOS app builds unchanged.
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
