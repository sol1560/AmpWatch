// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AmpKit",
    platforms: [
        .watchOS(.v11),
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AmpKit", targets: ["AmpKit"]),
    ],
    targets: [
        .target(name: "AmpKit"),
        .testTarget(name: "AmpKitTests", dependencies: ["AmpKit"]),
    ]
)
