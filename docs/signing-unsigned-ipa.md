# Sign the unsigned iOS IPA

The prerelease `duocb-unsigned.ipa` contains a device build with no code
signature or embedded provisioning profile. It cannot be installed until it is
signed for an Apple developer team.

This guide uses Apple's command-line tools on macOS. The commands were verified
with a development certificate and profile, followed by installation on a
registered physical iPhone. They assume the current app layout, which has no
app extensions or embedded dynamic frameworks that require separate signatures.

## Requirements

- macOS with Xcode installed.
- A valid Apple Development certificate and its private key in the login
  Keychain.
- An iOS development provisioning profile for the bundle identifier you will
  use. The profile must include the certificate and destination device.
- Developer Mode enabled on the device if installing with `devicectl`.

The example below uses development signing for a registered device. Ad Hoc
signing follows the same profile/identity matching rule, but uses an Apple
Distribution identity and Ad Hoc profile.

Keep certificates, private keys, Apple credentials, and signing secrets local.
Never add them to this repository or upload them to an untrusted signing
service.

Run the command blocks below in the same Terminal session so the variables
remain available to later steps.

## 1. Download and verify the release

Download these two files from the same GitHub prerelease into one directory:

- `duocb-unsigned.ipa`
- `SHA256SUMS.txt`

Set the download directory to an absolute path, then verify the IPA against the
published checksum:

```bash
DOWNLOAD_DIR="/absolute/path/to/downloads"

(
  cd "$DOWNLOAD_DIR" || exit 1
  awk '$2 == "duocb-unsigned.ipa" { print }' SHA256SUMS.txt \
    | shasum -a 256 -c -
)
```

Continue only if this prints `duocb-unsigned.ipa: OK`.

## 2. Choose the bundle ID, profile, and identity

The released app is compiled with the bundle ID
`com.andrewtheguy.duocb`. Keep that ID only if your developer team owns it and
has a matching profile. Everyone else must choose a unique App ID registered to
their team, such as `com.yourname.duocb`, and create a development provisioning
profile for it.

Xcode-managed iOS profiles are normally stored in:

```text
~/Library/Developer/Xcode/UserData/Provisioning Profiles/
```

List valid identities and copy the 40-character hash for the appropriate Apple
Development identity:

```bash
security find-identity -v -p codesigning
```

Set the three signing inputs. Use absolute paths:

```bash
BUNDLE_ID="com.yourname.duocb"
PROFILE="/absolute/path/to/profile.mobileprovision"
SIGNING_IDENTITY="0123456789ABCDEF0123456789ABCDEF01234567"
```

The identity must be included in the profile. The profile's App ID must equal
its App ID prefix followed by `.$BUNDLE_ID`, and its `ProvisionedDevices` list
must contain the destination device's hardware UDID. The App ID prefix is
usually the Team ID, but older developer accounts can use a different prefix.

## 3. Unpack and validate the inputs

Create an isolated signing directory and unpack the IPA:

```bash
SIGN_ROOT="$(mktemp -d /tmp/duocb-sign.XXXXXX)"
UNSIGNED_IPA="$DOWNLOAD_DIR/duocb-unsigned.ipa"
SIGNED_IPA="$DOWNLOAD_DIR/duocb-signed.ipa"
APP_PATH="$SIGN_ROOT/Payload/duocb.app"
PROFILE_PLIST="$SIGN_ROOT/profile.plist"
ENTITLEMENTS_PLIST="$SIGN_ROOT/entitlements.plist"

unzip -q "$UNSIGNED_IPA" -d "$SIGN_ROOT"
test -d "$APP_PATH"

if codesign --display "$APP_PATH" >/dev/null 2>&1; then
  echo "error: downloaded app is unexpectedly signed" >&2
  exit 1
fi
```

Apply the selected bundle ID, decode the profile, and verify that they match:

```bash
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" \
  "$APP_PATH/Info.plist"

security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
TEAM_ID="$(plutil -extract TeamIdentifier.0 raw -o - "$PROFILE_PLIST")"
APP_ID_PREFIX="$(
  plutil -extract ApplicationIdentifierPrefix.0 raw -o - "$PROFILE_PLIST"
)"
PROFILE_APP_ID="$(
  plutil -extract Entitlements.application-identifier raw -o - \
    "$PROFILE_PLIST"
)"

if [[ "$PROFILE_APP_ID" != "$APP_ID_PREFIX.$BUNDLE_ID" ]]; then
  echo "error: profile App ID does not match $APP_ID_PREFIX.$BUNDLE_ID" >&2
  exit 1
fi

printf 'Profile team: %s\n' "$TEAM_ID"

plutil -extract Entitlements xml1 \
  -o "$ENTITLEMENTS_PLIST" \
  "$PROFILE_PLIST"
```

Before continuing, confirm the profile is unexpired and includes the intended
device:

```bash
plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST"
plutil -extract ProvisionedDevices xml1 -o - "$PROFILE_PLIST"
```

Use `xcrun devicectl device info details --device DEVICE_ID` to find the
device's hardware `udid` when the CoreDevice identifier and hardware UDID are
different.

## 4. Embed the profile and sign

Embed the selected profile, then sign the app with the entitlements authorized
by that profile:

```bash
ditto --norsrc --noextattr --noqtn --noacl \
  "$PROFILE" \
  "$APP_PATH/embedded.mobileprovision"

codesign --force \
  --sign "$SIGNING_IDENTITY" \
  --entitlements "$ENTITLEMENTS_PLIST" \
  --generate-entitlement-der \
  --timestamp=none \
  "$APP_PATH"
```

If a future release contains app extensions, frameworks, or other nested code,
sign each nested component from the inside out before signing `duocb.app`.

## 5. Verify and repackage

Strictly verify the signed bundle and inspect its Team ID and entitlements:

```bash
codesign --verify --deep --strict --verbose=4 "$APP_PATH"
codesign --display --verbose=4 --entitlements :- "$APP_PATH"
```

The displayed `TeamIdentifier`, `application-identifier`, bundle ID, profile,
and certificate must all agree. Repackage the signed app without macOS metadata
files and test the ZIP structure:

```bash
ditto -c -k --keepParent \
  --norsrc --noextattr --noqtn --noacl \
  "$SIGN_ROOT/Payload" \
  "$SIGNED_IPA"

unzip -tq "$SIGNED_IPA"
shasum -a 256 "$SIGNED_IPA"
```

`duocb-signed.ipa` is now the signed artifact. Its signature remains valid only
while its certificate and provisioning profile remain valid.

## 6. Install on a registered device

List paired devices and copy the CoreDevice identifier from the `Identifier`
column:

```bash
xcrun devicectl list devices
```

Install the signed `.app` extracted above:

```bash
DEVICE_ID="00000000-0000-0000-0000-000000000000"

xcrun devicectl device install app \
  --device "$DEVICE_ID" \
  "$APP_PATH"
```

`devicectl` installs the `.app` bundle, not the enclosing IPA. The separately
created `duocb-signed.ipa` can be used with installation software that accepts
IPA files.

If installation reports a signing or verification failure, check these first:

- The profile's App ID exactly matches `APP_ID_PREFIX.BUNDLE_ID`.
- The certificate used by `codesign` is included in the profile.
- The device's hardware UDID is included in `ProvisionedDevices`.
- The profile and certificate have not expired or been revoked.
- The embedded profile and the entitlements used for signing came from the same
  file.

After installation, the temporary signing directory can be removed. Keep the
signed IPA if you need to reinstall it before its profile expires.

## Build from source instead

Building from source is the Apple-supported and less error-prone option. Set
`DEVELOPMENT_TEAM` and `DUOCB_BUNDLE_IDENTIFIER` in
`Developer.local.xcconfig`, then run:

```bash
scripts/create-archive-ios.sh --allow-provisioning-updates
```

Xcode will select or create the signing assets and export the signed IPA.
