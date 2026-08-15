#!/usr/bin/env bash
# Run this repo's CI checks natively on a Mac.
#
#   ci/ci.sh                      # the default jobs (see below)
#   ci/ci.sh simulator            # only these
#   ci/ci.sh --local              # link the sibling's local Rust build, not the
#                                 #   pinned release (see below)
#   ci/ci.sh --list               # what jobs exist
#
# `--local` makes *every* job link ../duocb/dist/ios/libduocb.xcframework
# instead of the release pinned in Packages/Duocb/Package.swift. Use it whenever
# the FFI has changed but no release carrying that change exists yet — otherwise
# the jobs compile this app's Swift against the pinned release's older duocb.h
# and fail on functions that do not exist there. It does not build the Rust
# itself; run the `ffi` job (or ../duocb/build-ios.sh) first.
#
# Everything here runs on the machine you type it on and needs no physical
# device. Unlike the sibling ../duocb, this repo's authoritative checkout lives
# on Linux, so you normally do not run this by hand — scripts/mac-ci.sh rsyncs
# the working tree to the Mac and invokes this over ssh. Running it directly is
# for when you are already sitting on the build host.
#
# Jobs:
#   simulator  build for the Simulator (arm64) — the README's verify command
#   smoke      boot a simulator, install the build, launch it, check it stays up
#   unsigned   Release device archive with signing off, plus the bundle
#              assertions from .github/workflows/unsigned-ios.yml
#   device     signed device-slice .app
#   ffi        rebuild libduocb from the sibling ../duocb working tree and link
#              against it (.github/workflows/verify-duocb-commit.yml)
#
# `ffi` is not in the default set: it compiles the Rust core for two Apple
# targets, which is minutes rather than seconds, and it is only meaningful when
# you are changing ../duocb. Ask for it by name. It is also the only job that
# proves the iOS-only halves of the core compile at all — the dns_sd.h DNS-SD
# backend and the omitted iroh mDNS lookup are `cfg(target_os = "ios")` code
# that no desktop build ever sees.
#
# When a job and the workflow it mirrors disagree, the workflow is right and
# this script is stale. Keep them in step by hand; nothing enforces it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ALL_JOBS=(simulator smoke unsigned device ffi)
DEFAULT_JOBS=(simulator smoke unsigned device)

# A named simulator rather than a UDID: whichever iOS runtime is installed gets
# used, the same way the README's destination leaves OS= off on purpose.
SIM_NAME=${DUOCB_CI_SIM:-iPhone 17}
BUNDLE_ID=${DUOCB_CI_BUNDLE_ID:-com.andrewtheguy.duocb}
# PRODUCT_NAME is `duocb` (lowercase), so that — not the target name — is what
# the .app is called.
APP_NAME=duocb
DERIVED_SIM=build/ci/DerivedData-sim
DERIVED_DEVICE=build/ci/DerivedData-device
DERIVED_FFI=build/ci/DerivedData-ffi
ARCHIVE=build/ci/duocb-ios-unsigned.xcarchive

usage() { echo "usage: $0 [--list] [--local] [${ALL_JOBS[*]}]" >&2; exit 2; }

# Link the sibling's working-tree Rust build everywhere instead of the pinned
# release. See the header.
LOCAL=false

jobs=()
while [ $# -gt 0 ]; do
    case $1 in
        --local) LOCAL=true; shift; continue ;;
        --list)
            printf '%s\n' "available: ${ALL_JOBS[*]}" "default:   ${DEFAULT_JOBS[*]}"
            exit 0 ;;
        -h|--help) usage ;;
        *)
            for known in "${ALL_JOBS[@]}"; do
                [ "$1" = "$known" ] && { jobs+=("$1"); shift; continue 2; }
            done
            echo "unknown job: $1" >&2; usage ;;
    esac
done
if [ ${#jobs[@]} -eq 0 ]; then jobs=("${DEFAULT_JOBS[@]}"); fi

info() { echo "[ci] $*"; }
step() { echo; echo "=== $* ==="; }
die() { echo "[ci] error: $*" >&2; exit 1; }

command -v xcodebuild >/dev/null || die 'xcodebuild not found — install Xcode and run xcode-select'
command -v xcodegen >/dev/null || die 'xcodegen not found (brew install xcodegen)'

# The .xcodeproj is generated and gitignored, so every job below starts from a
# project regenerated out of project.yml. Which xcframework it points at — the
# pinned release or a local Rust build — is baked in here, at generation time,
# not at build time; that is why `ffi` regenerates rather than just rebuilding.
generate() {
    local mode=$1  # pinned | local
    # --local overrides every caller: a job that would use the pinned release
    # still gets the working-tree build.
    if $LOCAL; then mode=local; fi
    if [ "$mode" = local ]; then
        [ -e Packages/Duocb/local/libduocb.xcframework ] \
            || die 'local xcframework not found — run (cd ../duocb && ./build-ios.sh release)'
        DUOCB_LOCAL_XCFRAMEWORK=1 xcodegen generate
    else
        env -u DUOCB_LOCAL_XCFRAMEWORK xcodegen generate
    fi
}

# xcodebuild, with the local-xcframework env var set when --local is in effect.
# The variable has to be present for the *build* as well as for generation:
# SwiftPM re-evaluates Package.swift, and a manifest that resolves to a
# different target than the generated project expects fails to link.
xcb() {
    if $LOCAL; then
        DUOCB_LOCAL_XCFRAMEWORK=1 xcodebuild "$@"
    else
        xcodebuild "$@"
    fi
}

job_simulator() {
    step 'simulator build'
    generate pinned
    # ARCHS=arm64 is not optional: libduocb.xcframework is arm64-only, and a
    # generic Simulator destination without it picks x86_64 and fails to link.
    xcb build \
        -project Duocb.xcodeproj \
        -scheme DuocbApp \
        -configuration Debug \
        -destination "platform=iOS Simulator,name=$SIM_NAME" \
        -derivedDataPath "$DERIVED_SIM" \
        ARCHS=arm64
    # Deliberately NOT CODE_SIGNING_ALLOWED=NO. A Simulator build signs ad-hoc
    # and needs no certificate or team, and that signature is what gives the app
    # an application-identifier — without which every SecItem write fails with
    # errSecMissingEntitlement (-34018). This app puts its private key and its
    # permanent suffix in the keychain, so an unsigned build cannot get past
    # setup: the smoke test would launch a shell that can store nothing.
}

# The only check here that proves the Rust core actually loads and the app gets
# past launch — everything else stops at compile and link.
job_smoke() {
    step "smoke run on the $SIM_NAME simulator"
    local app=$DERIVED_SIM/Build/Products/Debug-iphonesimulator/$APP_NAME.app
    [ -d "$app" ] || die "no simulator build at $app — run the 'simulator' job first"

    # Unlike the rest of this script, this one changes machine state: it leaves a
    # simulator booted with the app installed. Booting an already-booted device
    # is an error, hence the || true, and bootstatus waits out the first boot of
    # a fresh runtime.
    xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
    xcrun simctl bootstatus "$SIM_NAME" -b >/dev/null
    xcrun simctl install "$SIM_NAME" "$app"
    local pid
    pid=$(xcrun simctl launch "$SIM_NAME" "$BUNDLE_ID" | sed 's/.*: //')
    info "launched $BUNDLE_ID as pid $pid"

    # A crash on launch — a missing symbol in the static lib, a failed FFI init —
    # shows up as a process that is gone a moment later, which a bare `launch`
    # exit code will not tell you.
    sleep 5
    # Captured, not piped into grep -q: -q closes the pipe on the first match,
    # simctl dies of SIGPIPE, and under `set -o pipefail` that turns a live app
    # into a reported crash.
    local running
    running=$(xcrun simctl spawn "$SIM_NAME" launchctl list 2>/dev/null || true)
    case $running in
        *"$BUNDLE_ID"*) ;;
        *) die "$BUNDLE_ID did not survive 5s on the simulator — check the device's CrashReporter logs under ~/Library/Developer/CoreSimulator/Devices" ;;
    esac
    info 'still running after 5s'
    xcrun simctl terminate "$SIM_NAME" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

# .github/workflows/unsigned-ios.yml, minus the packaging: the IPA, the archive
# zip, the checksums and the prerelease are release plumbing, and none of them
# can fail in a way the archive and the assertions below do not already catch.
job_unsigned() {
    step 'unsigned release archive'
    generate pinned
    rm -rf "$ARCHIVE"
    xcb archive \
        -project Duocb.xcodeproj \
        -scheme DuocbApp \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -sdk iphoneos \
        -archivePath "$ARCHIVE" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY= \
        DEVELOPMENT_TEAM=

    step 'unsigned archive assertions'
    local app=$ARCHIVE/Products/Applications/$APP_NAME.app
    [ -d "$app" ] || die "archived app not found at $app"

    while IFS= read -r bundle; do
        ! codesign --display "$bundle" >/dev/null 2>&1 \
            || die "$bundle unexpectedly has a code signature"
    done < <(find "$app" -type d \( -name '*.app' -o -name '*.appex' -o -name '*.framework' \) -print)

    ! find "$app" -name embedded.mobileprovision -print -quit | grep -q . \
        || die 'the archived app unexpectedly embeds a profile'

    # The local-network keys are the ones that fail silently. Losing either
    # compiles, links, and launches — and then the LAN rendezvous simply never
    # resolves, which reads like a network problem rather than a missing plist
    # entry. Both service types must be listed: `_duocb-pin._udp` carries card
    # setup and `_duocb-host._udp` carries clipboard sessions, and a device that
    # can trade cards but never find a session is exactly what dropping the
    # second one produces.
    [ -n "$(plutil -extract NSLocalNetworkUsageDescription raw -o - "$app/Info.plist")" ] \
        || die 'the archived app lost its local network usage description'
    local services
    services=$(plutil -extract NSBonjourServices json -o - "$app/Info.plist")
    for service in _duocb-pin._udp _duocb-host._udp; do
        case $services in
            *"$service"*) ;;
            *) die "the archived app does not declare the $service Bonjour service" ;;
        esac
    done
    info 'archive assertions passed'
}

# The signed device slice. `generic/platform=iOS` builds the device arm64 slice
# without the hardware UDID, which is exactly what makes a device-less build
# machine work — the phone's UDID only has to be in the provisioning profile,
# not on this machine's USB bus.
job_device() {
    step 'signed device build'
    local team=${DUOCB_CI_TEAM:-}
    if [ -z "$team" ]; then
        team=$(awk -F= '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/ {
            sub(/\/\/.*$/, "", $2); gsub(/[[:space:]"]/, "", $2); if ($2 != "") { print $2; exit } }' \
            Developer.local.xcconfig 2>/dev/null || true)
    fi
    [ -n "$team" ] || die 'no DEVELOPMENT_TEAM — copy Developer.local.xcconfig.sample to Developer.local.xcconfig and fill it in'
    info "team $team"

    # Signing is the one job that needs more than a toolchain: codesign has to
    # read a private key out of the login keychain, and over ssh that keychain
    # is locked. `find-identity` still lists the identity (that is metadata), so
    # the only symptom without this check is `errSecInternalComponent` from
    # codesign several minutes into the build — an error message that names
    # neither the keychain nor ssh. Fail up front instead.
    if ! security show-keychain-info ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
        die 'the login keychain is locked, so codesign cannot read the signing key.
       Unlock it for this session first:
           security unlock-keychain ~/Library/Keychains/login.keychain-db
       and, if codesign still refuses, authorise it non-interactively once:
           security set-key-partition-list -S apple-tool:,apple:,codesign: \
               -s -k <login-password> ~/Library/Keychains/login.keychain-db
       Both need the account password, so they cannot be scripted from the
       Linux side. Running ci/ci.sh from a GUI session on the Mac avoids it
       entirely — the keychain is already unlocked there.'
    fi

    generate pinned
    xcb build \
        -project Duocb.xcodeproj \
        -scheme DuocbApp \
        -configuration Debug \
        -destination 'generic/platform=iOS' \
        -sdk iphoneos \
        -derivedDataPath "$DERIVED_DEVICE" \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$team"

    local app=$DERIVED_DEVICE/Build/Products/Debug-iphoneos/$APP_NAME.app
    [ -d "$app" ] || die "build did not produce an app at $app"
    codesign --verify --strict "$app" || die "$app failed signature verification"
    # Captured whole and parsed after, for the same reason as the smoke check:
    # a `| head -1` closes the pipe early and SIGPIPEs codesign under pipefail.
    local details
    # --verbose=2: the default -dv does not print the Authority chain at all.
    details=$(codesign -dv --verbose=2 "$app" 2>&1)
    info "signed: $(awk -F= '/^Authority=/ { print $2; exit }' <<<"$details") (team $(awk -F= '/^TeamIdentifier=/ { print $2; exit }' <<<"$details"))"
    info "$app"
}

# .github/workflows/verify-duocb-commit.yml, against the sibling working tree
# instead of a pinned commit — same reason to exist: prove a not-yet-released
# Rust change still compiles and links into this app before cutting a release.
#
# This is also where the iOS-only core code gets its only compile: the
# dns_sd.h DNS-SD backend and the cfg'd-out iroh mDNS lookup exist solely for
# `target_os = "ios"`, so a green desktop `cargo clippy` says nothing about them.
job_ffi() {
    step 'build libduocb from ../duocb'
    [ -d ../duocb ] || die 'no sibling ../duocb checkout'
    ( cd ../duocb && ./build-ios.sh release )

    step 'build against the local xcframework'
    generate local
    local status=0
    DUOCB_LOCAL_XCFRAMEWORK=1 xcodebuild build \
        -project Duocb.xcodeproj \
        -scheme DuocbApp \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -sdk iphoneos \
        -derivedDataPath "$DERIVED_FFI" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        DEVELOPMENT_TEAM= \
        COMPILER_INDEX_STORE_ENABLE=NO || status=$?

    # Leave the project pointing at the pinned release again — on the failing path
    # especially, since that is the one you go back to Xcode after: a generated
    # project wired to a local build is a trap for the next plain `xcodebuild`
    # here. Under --local that *is* what was asked for, so it stays. The build's
    # status is re-raised after the cleanup, not swallowed.
    generate pinned
    return "$status"
}

info "jobs: ${jobs[*]}"
for job in "${jobs[@]}"; do
    "job_$job"
done

echo
info 'all jobs passed'
