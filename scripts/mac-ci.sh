#!/usr/bin/env bash
#
# Run this repo's CI checks on the macOS build host, from a Linux checkout.
#
#   scripts/mac-ci.sh                 # the default jobs
#   scripts/mac-ci.sh simulator smoke # only these
#   scripts/mac-ci.sh ffi             # rebuild the Rust core and link against it
#   scripts/mac-ci.sh --sync-only     # push the trees, run nothing
#   scripts/mac-ci.sh --shell         # push, then drop into a shell there
#   scripts/mac-ci.sh --list          # what jobs exist
#
# Everything in ci/ci.sh runs natively on a Mac and needs Xcode, which this
# checkout's machine does not have — it is Linux. So this script is the bridge:
# it rsyncs *this working tree* plus the sibling ../duocb Rust core to the Mac,
# then runs ci/ci.sh over ssh and streams the output back. The working tree,
# not a commit: the point is to test what you are editing right now.
#
# The sibling repo comes along because the `ffi` job builds it. Both land as
# siblings under one staging directory, which is what keeps this repo's
# committed relative symlink
#   Packages/Duocb/local/libduocb.xcframework -> ../../../../duocb/dist/ios/…
# pointing at the right place on the far side.
#
# One job does not work over ssh: `device`, which signs. codesign has to read a
# private key out of the login keychain, and ssh sessions get it locked — the
# identity still lists, so the failure is a bare `errSecInternalComponent` deep
# in the build. ci/ci.sh checks for it up front and says what to do; unlocking
# needs the account password, so it is not something this script can do for you.
# Every other job (simulator, smoke, unsigned, ffi) is signing-free and runs
# here fine.
#
# Build outputs stay on the Mac and are never synced back or deleted: cargo's
# target/, duocb's dist/, and this repo's build/ are excluded, so an
# incremental Rust build there survives from run to run. That exclusion is
# load-bearing — without it --delete would wipe the Mac's target/ on every
# push and every `ffi` job would be a cold multi-minute build.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_DIR=$PWD
CORE_DIR=$REPO_DIR/../duocb

# An ssh alias, not a hostname: the connection details (user, address, key)
# belong in ~/.ssh/config, not here.
HOST=${DUOCB_MAC_HOST:-macvm}
# Both repos land here as siblings. staging-area is scratch space on the Mac —
# nothing in it is authoritative, and a full re-push always reconstructs it.
REMOTE_ROOT=${DUOCB_MAC_ROOT:-codes/staging-area}
REMOTE_REPO="$REMOTE_ROOT/duocb-ios"
REMOTE_CORE="$REMOTE_ROOT/duocb"

info() { echo "[mac-ci] $*"; }
die() { echo "[mac-ci] error: $*" >&2; exit 1; }

sync_only=false
shell=false
args=()
while [ $# -gt 0 ]; do
    case $1 in
        --sync-only) sync_only=true; shift ;;
        --shell) shell=true; shift ;;
        --host) HOST=${2:?--host needs a value}; shift 2 ;;
        -h|--help)
            sed -n '3,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) args+=("$1"); shift ;;
    esac
done

[ -d "$CORE_DIR" ] || die "no sibling Rust checkout at $CORE_DIR"
command -v rsync >/dev/null || die 'rsync not found'
ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true \
    || die "cannot reach '$HOST' over ssh — check ~/.ssh/config and that the VM is up"

# The Mac runs openrsync, which speaks protocol 29; GNU rsync negotiates down
# to it, so only widely-supported options are used here (no --info=progress2).
push() {
    local src=$1 dest=$2; shift 2
    info "sync $src -> $HOST:$dest"
    ssh "$HOST" "mkdir -p '$dest'"
    rsync -az --delete "$@" "$src/" "$HOST:$dest/"
}

push "$CORE_DIR" "$REMOTE_CORE" \
    --exclude=/.git \
    --exclude=/target \
    --exclude=/dist \
    --exclude=/tmp \
    --exclude=.DS_Store

push "$REPO_DIR" "$REMOTE_REPO" \
    --exclude=/.git \
    --exclude=/build \
    --exclude=/tmp \
    --exclude='*.xcodeproj' \
    --exclude=.build \
    --exclude=.swiftpm \
    --exclude=DerivedData \
    --exclude=xcuserdata \
    --exclude=.DS_Store

if $shell; then
    info "opening a shell in $HOST:$REMOTE_REPO"
    exec ssh -t "$HOST" "cd '$REMOTE_REPO' && exec \$SHELL -l"
fi
if $sync_only; then
    info 'sync only — nothing run'
    exit 0
fi

# -t so the remote job dies with this terminal instead of orphaning an
# xcodebuild on the Mac when you Ctrl-C. Login shell for Homebrew's PATH
# (xcodegen) and ~/.cargo/bin.
info "running ci/ci.sh ${args[*]:-(default jobs)} on $HOST"
exec ssh -t "$HOST" \
    "bash -lc 'cd \"$REMOTE_REPO\" && ci/ci.sh ${args[*]}'"
