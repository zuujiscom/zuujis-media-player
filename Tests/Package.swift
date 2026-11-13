// swift-tools-version:5.9
import PackageDescription

// Unit tests for the app's pure logic (EQ maths, play queue, output-rate
// choice). The app itself is an Xcode project; these files are symlinked in
// from ZuujisMediaPlayer/ so nothing is duplicated and the app target is
// untouched. Run with `swift test` from this folder.
let package = Package(
    name: "ZuujisCore",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ZuujisCore", path: "Sources/ZuujisCore"),
        .testTarget(name: "ZuujisCoreTests", dependencies: ["ZuujisCore"], path: "Tests/ZuujisCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
