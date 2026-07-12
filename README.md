# duocb-ios

iOS peer of [duocb](https://github.com/andrewtheguy/duocb) — P2P clipboard-text
sharing between two devices you own, over iroh QUIC with nostr-relay discovery.

This app supports **configure mode only**: all of your devices share one
standing 47-char secret, set up once through a wizard (generate it on the
first device, import it on every other; compare the fingerprint to confirm
they match). Each device broadcasts a presence record under a unique identity
`<name>_<suffix>` — a short name you choose plus a permanent 8-character
suffix minted on first launch — so the home hub shows your device list: who is
online, who is hosting, when each was last seen. To pair, **Start a
connection** on one device and tap it in the list on the other. Quick mode
(rotating PIN / manual node id) is desktop-only.

Received text lands in an in-memory inbox showing only size + CRC + time — it
reaches the clipboard only via an explicit **Copy**, and is revealed only via
an explicit **Peek** (auto-hides after 15 s), matching the desktop app.

The networking core is the Rust `duocb-core` crate, compiled to a static
library (`libduocb.xcframework`) and driven over a small C FFI
(`crates/duocb-ffi` + `ios/duocb.h` in the duocb repo). Everything runs
in-process: no accounts, no Network Extension, no special entitlements — it
also runs in the Simulator.

## Requirements

- Xcode on Apple Silicon
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- For local FFI dev only: a Rust toolchain with the iOS targets
  (`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`)

## Build & run

1. Generate the Xcode project (regenerate after changing `project.yml`):

   ```sh
   xcodegen generate
   open Duocb.xcodeproj
   ```

   On first build, Xcode resolves the local Swift package
   (`Packages/Duocb`), which downloads the pinned `libduocb-ios.xcframework.zip`
   release asset by URL + checksum.

2. Signing (once): copy the sample and set your Team ID —

   ```sh
   cp Developer.local.xcconfig.sample Developer.local.xcconfig
   # edit DEVELOPMENT_TEAM = YOURTEAMID
   ```

3. Run on a device or Simulator. The setup wizard runs on first launch:
   create the secret (or paste the one from your other device), name this
   device, and the hub appears with your device list. Start a connection on
   one device and tap it in the list on the other to join.

The secret lives in the Keychain and stays until you explicitly **Clear
secret** on the hub. The permanent identity suffix also lives in the Keychain
(device-only, never synced) and survives clearing the secret.

The xcframework is arm64-only, so pin an arm64 Simulator explicitly when
building from the CLI:

```sh
xcodebuild -project Duocb.xcodeproj -scheme DuocbApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## Local FFI development

To build against the sibling repo's working tree instead of the pinned
release: build the xcframework there, then set `DUOCB_LOCAL_XCFRAMEWORK=1` for
**both** project generation and the build (the choice is baked in at
`xcodegen generate` time):

```sh
(cd ../duocb && ./build-ios.sh release)
DUOCB_LOCAL_XCFRAMEWORK=1 xcodegen generate
DUOCB_LOCAL_XCFRAMEWORK=1 xcodebuild -project Duocb.xcodeproj -scheme DuocbApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

SPM forbids binary-target paths outside the package root, so the sibling's
`dist/ios` build is reached via the committed symlink
`Packages/Duocb/local/libduocb.xcframework`.

## Scripts

- `scripts/bump-xcframework.sh [tag]` — repoint `Packages/Duocb/Package.swift`
  at a duocb release (downloads the zip, computes the SPM checksum, rewrites
  url + checksum; defaults to the latest release).
- `scripts/create-archive-ios.sh` — Release `.xcarchive` + exported `.ipa`
  into `build/`.
- `scripts/list-devices-ios.sh` / `scripts/run-device-ios.sh` — build, install,
  and launch on a paired physical device.
- `scripts/render-icons.swift` — regenerate the app icon set + `icon.svg`.

## Same-machine end-to-end test

The Simulator shares the Mac's network, so you can pair it against a desktop
duocb on the same machine. Give the desktop its own config path (only one
process may hold a config file):

```sh
cd ../duocb && cargo run -p duocb -- --config /tmp/duocb-desktop.json
```

Desktop: run the setup wizard (generate the secret, name it `mac`). Simulator
app: import the same secret (fingerprints must match), name it `phone`. Each
now shows the other in its device list. Press Start on the desktop, then tap
the `mac_…` row in the app to join; send text both ways and compare the CRC
readouts.
