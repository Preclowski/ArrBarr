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
    dependencies: [
        // Official Swift Markdown parser (swiftlang), built on cmark-gfm — used
        // to render assistant chat messages (incl. GFM tables) properly.
        //
        // Pinned to an exact release tag, never a branch: a signed DMG must be
        // reproducible from the tag that produced it, and a branch pin means the
        // release build compiles whatever landed upstream that morning. As a
        // bonus, 0.8.0 depends on swift-cmark by *version* (main tracks its `gfm`
        // branch), so this pin removes the last floating ref from the graph.
        // Bumping is a deliberate one-line change — same posture as the MCP SDK
        // pin in ArrMCPServer.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
    ],
    targets: [
        .target(
            name: "ArrCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
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
