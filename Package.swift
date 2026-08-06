// swift-tools-version: 6.0
import PackageDescription

// A standalone package for the one piece of logic the whole app depends on.
// Kept separate from the app target so it can be tested with `swift test` from
// the command line, with no Xcode project, simulator, or device involved.
//
// Platform minimums are deliberately loose: this code touches nothing but
// Foundation, so it should build anywhere. The app that consumes it targets
// iOS 26.
let package = Package(
    name: "FaultCodeNormalizer",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "FaultCodeNormalizer", targets: ["FaultCodeNormalizer"]),
    ],
    targets: [
        .target(name: "FaultCodeNormalizer"),
        .testTarget(
            name: "FaultCodeNormalizerTests",
            dependencies: ["FaultCodeNormalizer"]
        ),
    ]
)
