# duocb-ios

iOS peer of [duocb](https://github.com/andrewtheguy/duocb) — P2P clipboard-text
sharing between two devices you own, over iroh QUIC with Bonjour/DNS-SD
discovery and Nostr-relay fallback.

Every device holds **its own application keypair** and a signed identity card
naming `<short-name>_<permanent-suffix>` — there is no shared secret to copy
between devices. Two devices come to trust each other by **trading cards**: one
shows a short rotating PIN, the other types it, and the PIN-authenticated
connection carries the two cards across. Both screens then show one **pairing
code** built from both devices' keys, and neither card is stored until you
confirm the two screens display the identical code. That human check is the
point — a PIN is short, so possession of it alone must never be enough to
become a trusted device. Card setup carries no clipboard content and ends as
soon as the cards have crossed.

Once two devices trust each other, press **Connect to a device** on each and
pick the other from the trusted-device list. Neither side goes first and
neither picks a role: duocb decides which device hosts the link from the two
identity keys, and whichever of you is ready first simply waits for the other.

Cards expire 30 days after they are minted; the private key that signs them
never does. At launch, this device renews its own card with the same key once
less than seven days remain. A peer's card that lapses can no longer pair and
shows in warning colour until that device hands over a fresh one. You can also paste a card
directly, check its previewed fingerprint, and trust it without a network card
setup; the same fingerprint then appears on its trusted-device row.

A **channel** setting picks how the two devices find each other. It governs
card setup and clipboard sessions alike, so **both devices must be set to a
channel they share**:

- **Local network, then internet** (default) — the dialer looks on the local
  network first and falls back to relay servers. The host publishes its
  encrypted rendezvous record on both channels, so use Local network only when
  no relay may be contacted. For clipboard sessions, the encrypted payload
  hides the node id, but the Nostr event still exposes the host and intended
  peer application public keys as metadata.
- **Local network only** — no third-party server and no internet needed, but
  both devices must be on the same network. The rendezvous is a Bonjour
  service registered through the system's mDNSResponder daemon (no multicast
  entitlement involved) and the dial goes straight to the addresses it
  resolves. Triggers the Local Network permission prompt; if iOS denies the
  advertisement, the app says so and the next PIN rotation recovers once you
  grant access (Settings > Privacy & Security > Local Network).
- **Internet only** — relay servers only, with no local-network lookup at all.

Where multicast is blocked, the device showing a PIN also displays its local
IP, and the joining device can type it to pair over a direct side channel.

Received text lands in an in-memory inbox showing only size + CRC + time — it
reaches the clipboard only via an explicit **Copy**, and is revealed only via
an explicit **Peek** (auto-hides after 15 s), matching the desktop app.

The networking core is the Rust `duocb-core` crate, compiled to a static
library (`libduocb.xcframework`) and driven over a small C FFI
(`crates/duocb-ffi` + `ios/duocb.h` in the duocb repo). Everything runs
in-process: no accounts, no Network Extension, no special entitlements — it
also runs in the Simulator.

One piece of the core is compiled out on iOS: iroh's own mDNS address lookup,
which opens multicast sockets in-process and would need Apple's restricted
multicast entitlement. Regular mDNS is unaffected — it goes through the system
mDNSResponder daemon instead, which is why `Info.plist` declares both
`_duocb-pin._udp` (card setup) and `_duocb-host._udp` (clipboard sessions).

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
   create this device's identity, name it, and the hub appears. Choose **Trade
   cards** on both devices to pair them, then press **Connect to a device** on
   each and pick the other.

The application private key, permanent identity suffix, and iroh transport key
live in the Keychain with this-device-only accessibility, so they are neither
synced through iCloud Keychain nor restored automatically onto another device.
The application private key can be copied manually to recover that key on a
replacement phone; the suffix and trusted-device list are not part of that
backup. The device name, this device's signed card, trusted peers' cards, and
channel choice live in a JSON file in Application Support; cards are public by
design, so the Keychain buys them nothing. **Reset identity** in Settings starts
over with a fresh application keypair and an empty trusted list; the permanent
suffix and independently managed iroh transport key survive it.

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
provisioning profile that includes the destination device. Keep the default
`com.andrewtheguy.duocb` bundle identifier only when signing for a team that
owns it; otherwise replace it with a unique App ID registered to your developer
team. Follow the tested [unsigned IPA signing guide](docs/signing-unsigned-ipa.md)
for checksum verification, signing, validation, repackaging, and installation.
Do not send an Apple password, signing certificate, or private key to this
repository or an untrusted signing service.

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
  at a duocb release, update `MARKETING_VERSION`, and regenerate the Xcode
  project when XcodeGen is available (defaults to the latest release).
- `scripts/create-archive-ios.sh` — Release `.xcarchive` + exported `.ipa`
  into `build/`, signed with the team and bundle ID from
  `Developer.local.xcconfig`.
- `scripts/list-devices-ios.sh` / `scripts/run-device-ios.sh` — build, install,
  and launch on a paired physical device. Both run **on the Mac**.
- `scripts/mac-device.sh` — the same thing driven from this Linux checkout; see
  [On a real device, from Linux](#on-a-real-device-from-linux).
- `scripts/render-icons.swift` — regenerate the app icon set + `icon.svg`.

## End-to-end test against the desktop app

The Simulator shares the Mac's network, so you can pair it against a desktop
duocb. Give the desktop its own config path (only one process may hold a
config file):

```sh
cd ../duocb && cargo run -p duocb -- --config /tmp/duocb-desktop.json
```

Set up both sides (desktop: generate an identity, name it `mac`; app: the same,
named `phone`), then choose **Trade cards** on both — show the PIN on one, type
it on the other, and confirm the pairing code reads identically on the two
screens before importing. After that press Connect on both — the `phone_…` row
on the desktop and the `mac_…` row in the app, in either order — and send text
both ways, comparing the CRC readouts.

`--lan-only` and `--nostr-only` pin the desktop to one channel for the life of
the process; set the app's Settings channel to one it shares. To exercise the
default channel's LAN-to-relay fallback, make the default-configured device the
dialer and the other device Nostr-only; if key order assigns the roles the other
way around, swap which device carries the override.

## CI from a Linux checkout

This repository's authoritative checkout lives on Linux, while the build needs
Xcode. `scripts/mac-ci.sh` bridges the two: it rsyncs this working tree and the
sibling `../duocb` to a macOS host over ssh (the `macvm` alias by default;
override with `DUOCB_MAC_HOST`), then runs `ci/ci.sh` there and streams the
output back.

```sh
scripts/mac-ci.sh                        # simulator, smoke, unsigned
scripts/mac-ci.sh ffi                    # rebuild the Rust core for iOS and link it
scripts/mac-ci.sh --local simulator smoke
scripts/mac-ci.sh --sync-only            # push the trees, run nothing
```

`--local` links `../duocb`'s working-tree build instead of the release pinned
in `Packages/Duocb/Package.swift`; it is required whenever the FFI has changed
but no release carries that change yet.

The `device` job is the one that cannot run over ssh: codesign needs a private
key from the login keychain, which an ssh session leaves locked. It is in
`ci/ci.sh`'s default set but not in `scripts/mac-ci.sh`'s, so a bare run over
ssh does not end on a job that was never going to work; ask for it by name and
`ci/ci.sh` prints the unlock commands, which need the account password — or run
it from a GUI session on the Mac instead.

## On a real device, from Linux

`scripts/mac-device.sh` puts the app on a physical iPhone without leaving this
checkout. It syncs (through `mac-ci.sh`), then **types the build into a tmux
session on the Mac** rather than running it over ssh, and streams the log back.

```sh
scripts/mac-device.sh                    # sync, build, install, launch
scripts/mac-device.sh install            # same, without launching
scripts/mac-device.sh status             # installed? running?
scripts/mac-device.sh devices            # what the Mac has paired
scripts/mac-device.sh doctor             # report on the Mac, change nothing
scripts/mac-device.sh --device iPad --local
```

The tmux hop is the whole point: that session belongs to a GUI login, so its
login keychain is unlocked and codesign can read the signing key — the one
thing `mac-ci.sh` can never do. Start it once on the Mac with `tmux new -s macscratch`
(from Terminal.app, not over ssh, or the keychain is locked there too);
`doctor` reports whether it is present, idle, and unlocked. A busy pane is
refused rather than typed into.

Defaults differ from `run-device-ios.sh`'s deliberately: **Release** and the
**pinned** xcframework, because this is what goes on a phone you actually use,
and Debug's `-Onone` changes how anything timing-sensitive behaves. `--local`
switches to `../duocb`'s working tree, building that xcframework on the Mac
first (`dist/` is excluded from the sync).

The Mac here is not `mac-ci.sh`'s: a VM can build and sign but can never pair
with hardware, so the default host is `macwork` rather than `macvm` (override
with `DUOCB_MAC_DEVICE_HOST`). The device defaults to the one named `iPhone`
and is matched against identifier, UDID or name — ambiguity lists the paired
devices and stops, rather than guessing onto someone's iPad.
