// swift-tools-version:5.9
import PackageDescription

// Standalone eval harness for the Pigeon agent. Deliberately its own
// SwiftPM package (not a target in the app's xcodeproj): it's a CLI that
// talks to the running app over HTTP, and keeping it here means
// `swift run` works without xcodegen or Xcode.
let package = Package(
    name: "pigeon-eval",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "pigeon-eval", path: "Sources/pigeon-eval")
    ]
)
