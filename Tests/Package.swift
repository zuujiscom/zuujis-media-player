// swift-tools-version:5.9
import PackageDescription

// Unit tests for the app's pure logic (EQ maths, play queue, output-rate
// choice). The app itself is an Xcode project; these files are symlinked in
// from AudioEqualizer/ so nothing is duplicated and the app target is
// untouched. Run with `swift test` from this folder.
let package = Package(
    name: "AE2Core",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AE2Core", path: "Sources/AE2Core"),
        .testTarget(name: "AE2CoreTests", dependencies: ["AE2Core"], path: "Tests/AE2CoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
