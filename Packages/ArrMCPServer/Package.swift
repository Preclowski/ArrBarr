// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArrMCPServer",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ArrMCPServer", targets: ["ArrMCPServer"])],
    dependencies: [
        .package(path: "../ArrCore"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "ArrMCPServer",
            dependencies: [
                .product(name: "ArrCore", package: "ArrCore"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ArrMCPServerTests",
            dependencies: ["ArrMCPServer"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
