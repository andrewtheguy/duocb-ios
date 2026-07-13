// swift-tools-version:5.9
import Foundation
import PackageDescription

// Delivers libduocb.xcframework (built by ../duocb's build-ios.sh, released as
// libduocb-ios.xcframework.zip) as a binary target. Default: pinned release
// URL + checksum (bump with scripts/bump-xcframework.sh <tag>). Local FFI dev:
// set DUOCB_LOCAL_XCFRAMEWORK=1 (or true) to use the committed symlink
// local/libduocb.xcframework -> ../duocb/dist/ios/libduocb.xcframework
// (SPM forbids binary-target paths outside the package root, hence the
// symlink). The env var must be enabled for BOTH `xcodegen generate` and the
// build itself.

func localBinaryTarget() -> Target? {
    guard let value = ProcessInfo.processInfo.environment["DUOCB_LOCAL_XCFRAMEWORK"],
          value == "1" || value == "true" else { return nil }
    return .binaryTarget(name: "libduocb", path: "local/libduocb.xcframework")
}

let binaryTarget = localBinaryTarget() ?? .binaryTarget(
    name: "libduocb",
    url: "https://github.com/andrewtheguy/duocb/releases/download/v0.0.14/libduocb-ios.xcframework.zip",
    checksum: "b6740a47451f5e222e4ce28306f1361f738dda760183f506e81b8988c48cdfbd"
    // Placeholder until the first release with an iOS asset is published —
    // run scripts/bump-xcframework.sh v0.0.8 to fill in the real checksum.
    // Until then, build with DUOCB_LOCAL_XCFRAMEWORK=1.
)

let package = Package(
    name: "Duocb",
    products: [.library(name: "libduocb", targets: ["libduocb"])],
    targets: [binaryTarget]
)
