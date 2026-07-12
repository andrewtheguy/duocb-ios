// swift-tools-version:5.9
import Foundation
import PackageDescription

// Delivers libduocb.xcframework (built by ../duocb's build-ios.sh, released as
// libduocb-ios.xcframework.zip) as a binary target. Default: pinned release
// URL + checksum (bump with scripts/bump-xcframework.sh <tag>). Local FFI dev:
// set DUOCB_LOCAL_XCFRAMEWORK to use the committed symlink
// local/libduocb.xcframework -> ../duocb/dist/ios/libduocb.xcframework
// (SPM forbids binary-target paths outside the package root, hence the
// symlink). The env var must be set for BOTH `xcodegen generate` and the
// build itself.

func localBinaryTarget() -> Target? {
    guard let value = ProcessInfo.processInfo.environment["DUOCB_LOCAL_XCFRAMEWORK"],
          !value.isEmpty else { return nil }
    let path = (value == "1" || value == "true") ? "local/libduocb.xcframework" : value
    return .binaryTarget(name: "libduocb", path: path)
}

let binaryTarget = localBinaryTarget() ?? .binaryTarget(
    name: "libduocb",
    url: "https://github.com/andrewtheguy/duocb/releases/download/v0.0.8/libduocb-ios.xcframework.zip",
    checksum: "0000000000000000000000000000000000000000000000000000000000000000"
    // Placeholder until the first release with an iOS asset is published —
    // run scripts/bump-xcframework.sh v0.0.8 to fill in the real checksum.
    // Until then, build with DUOCB_LOCAL_XCFRAMEWORK=1.
)

let package = Package(
    name: "Duocb",
    products: [.library(name: "libduocb", targets: ["libduocb"])],
    targets: [binaryTarget]
)
