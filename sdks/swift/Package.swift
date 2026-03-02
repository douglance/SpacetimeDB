// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpacetimeDBSwift",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "SpacetimeDBSwift", targets: ["SpacetimeDBSwift"]),
    ],
    targets: [
        .target(name: "SpacetimeDBSwift"),
        .testTarget(name: "SpacetimeDBSwiftTests", dependencies: ["SpacetimeDBSwift"]),
    ]
)
