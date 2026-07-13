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
    url: "https://github.com/andrewtheguy/duocb/releases/download/v0.0.16/libduocb-ios.xcframework.zip",
    checksum: "fbed0d77c7e8e4b49b3ebddf2780c4ec7de405ffb5c7bd5b4b9797f199239355"
)

let package = Package(
    name: "Duocb",
    products: [.library(name: "libduocb", targets: ["libduocb"])],
    targets: [binaryTarget]
)
