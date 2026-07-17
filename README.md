# duocb-ios

iOS peer of [duocb](https://github.com/andrewtheguy/duocb) — P2P clipboard-text
sharing between two devices you own, over iroh QUIC with nostr-relay discovery.

This app supports **configure mode**: all of your devices share one
standing 47-char secret, set up once through a wizard (generate it on the
first device, import it on every other; compare the fingerprint to confirm
they match). Each device broadcasts a presence record under a unique identity
`<name>_<suffix>` — a short name you choose plus a permanent 8-character
suffix minted on first launch. To pair, **Start a connection** on one device;
on the other choose **Join another device**, which shows your device list and
when each record was last broadcast — no online/offline or hosting guesswork:
relay freshness is unreliable, so nothing is gated on it and the iroh dial
itself is the liveness check. Tap any listed device to connect. If it is not
hosting yet, the join retries every few seconds for up to 10 attempts; if those
attempts expire, tap Join again after Start is pressed there.

It also supports **quick pair**: ephemeral pairing with any duocb device —
even one that doesn't share your secret — via a short rotating PIN, with no
setup at all (it's offered on the first screen and on the hub). One device
shows the PIN, the other types it; the PIN renews every 60 seconds until a
device pairs. The host accepts only its current PIN and the PIN from the
immediately previous rotation; anything older is rejected. A **channel** menu
picks how the PIN is found, matching the desktop presets — choose the same
channel on both devices:

- **Internet + local network** (default; the desktop **P** preset) — the
  rendezvous rides public nostr relays. Works across networks; the connection
  itself still goes direct when the devices share a network.
- **Local network only** (the desktop **L** preset) — no third-party server
  at all: the PIN is advertised as a Bonjour service through the system's
  mDNSResponder daemon (no multicast entitlement involved) and the joiner
  dials the direct addresses it resolves. Both devices must be on the same
  network. Joining triggers the Local Network permission prompt; hosting
  needs the permission too — if iOS denies the advertisement, the app shows
  an error and nudges the prompt, and the next PIN rotation (≤60 s) recovers
  once you grant access (Settings > Privacy & Security > Local Network).

The desktop's nostr-only PIN preset and the manual pairing code remain
desktop-only.

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

2. Signing (once): copy the sample, set your Team ID, and choose a unique
   reverse-DNS bundle identifier —

   ```sh
   cp Developer.local.xcconfig.sample Developer.local.xcconfig
   # edit DEVELOPMENT_TEAM = YOURTEAMID
   # edit DUOCB_BUNDLE_IDENTIFIER = com.yourname.duocb
   ```

3. Run on a device or Simulator. The setup wizard runs on first launch:
   create the secret (or paste the one from your other device), name this
   device, and the hub appears. Start a connection on one device; on the
   other choose Join and tap it in the device list.

The secret lives in the Keychain and stays until you explicitly **Clear
secret** on the hub. The permanent identity suffix also lives in the Keychain
(device-only, never synced) and survives clearing the secret.

The xcframework is arm64-only, so pin an arm64 Simulator explicitly when
building from the CLI:

```sh
xcodebuild -project Duocb.xcodeproj -scheme DuocbApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## Unsigned release artifacts

Start the [`Build unsigned iOS artifacts`](.github/workflows/unsigned-ios.yml)
GitHub Actions workflow manually from the Actions tab. It builds without an
Apple certificate, Team ID, or provisioning profile. Each run uploads an
Actions artifact retained for 30 days and publishes a GitHub prerelease named
with its UTC build time and short commit hash, for example
`20260717164908-3b6e789`. Both contain:

- `duocb-unsigned.ipa` — an unsigned device build for a trusted local IPA
  signing tool.
- `duocb-ios-unsigned.xcarchive.zip` — the complete unsigned Xcode archive for
  manual signing or inspection on a Mac.
- `SHA256SUMS.txt` — SHA-256 checksums for both files.

Neither the IPA nor the archive is installable as downloaded. Before installing
it, sign the app locally with your own Apple signing certificate and a
provisioning profile that includes the destination device. The signer must also
replace the default `com.andrewtheguy.duocb` bundle identifier with a unique App
ID registered to your developer team. Do not send an Apple password, signing
certificate, or private key to this repository or an untrusted signing service.

Development and release-testing profiles only work on devices included by that
profile. TestFlight and App Store distribution require an app record and signing
assets owned by the submitting developer team. This project currently has no
special signing entitlements or app extensions, which keeps re-signing
straightforward.

For the Apple-supported Xcode signing flow, build from source instead: configure
`Developer.local.xcconfig` as described above, then run
`scripts/create-archive-ios.sh --allow-provisioning-updates`. This produces a
signed archive and IPA using your developer team and bundle identifier.

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
  into `build/`, signed with the team and bundle ID from
  `Developer.local.xcconfig`.
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
app: import the same secret (fingerprints must match), name it `phone`. Press
Start on the desktop, then choose Join in the app and tap the `mac_…` row;
send text both ways and compare the CRC readouts.
