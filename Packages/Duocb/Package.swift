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
    url: "https://github.com/andrewtheguy/duocb/releases/download/v0.0.23/libduocb-ios.xcframework.zip",
    checksum: "06baf1f7b7172e14ac00721e3a2b1f94e151d7f62e4f9fe2dd3ef691fb00ef17"
)

let package = Package(
    name: "Duocb",
    products: [.library(name: "libduocb", targets: ["libduocb"])],
    targets: [binaryTarget]
)
