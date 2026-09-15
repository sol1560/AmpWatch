// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AmpKit",
    defaultLocalization: "en",
    platforms: [
        .watchOS(.v11),
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AmpKit", targets: ["AmpKit"]),
    ],
    targets: [
        .target(name: "AmpKit", resources: [.process("Resources")]),
        .testTarget(name: "AmpKitTests", dependencies: ["AmpKit"]),
    ]
)
