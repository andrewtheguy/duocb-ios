#!/usr/bin/env bash
#
# Build, install and launch duocb on a physical iPhone, from this Linux checkout.
#
#   scripts/mac-device.sh                  # sync, build, install, launch
#   scripts/mac-device.sh install          # same, without launching
#   scripts/mac-device.sh status           # is it installed, is it running
#   scripts/mac-device.sh devices          # what the Mac has paired
#   scripts/mac-device.sh doctor           # report on the Mac, change nothing
#
# scripts/mac-ci.sh's twin for real hardware, and it exists for one reason:
# **codesign cannot run over ssh**. Signing needs a private key out of the login
# keychain, and an ssh session leaves that keychain locked — `security
# find-identity` still lists the identity, because that is metadata, so the only
# symptom is `errSecInternalComponent` several minutes into a build. Unlocking
# needs the account password, which cannot be scripted from here.
#
# So the build is not run over ssh. It is typed into a tmux session on the Mac
# that was started from a GUI login, where the keychain is already unlocked;
# this script only sends the command and streams the log back. That is also why
# a device build cannot go through mac-ci.sh: ci/ci.sh's `device` job is a
# compile-and-sign check, and it fails fast on exactly this.
#
# Nothing is built here. The Mac already has the whole toolchain, and the work
# is done by the scripts already in this repo, on the far side of the sync:
# scripts/list-devices-ios.sh resolves the device, scripts/run-device-ios.sh
# builds, installs and launches. This script is the hop, not a second copy of
# either.
#
# Defaults differ from run-device-ios.sh's on purpose: Release rather than
# Debug, and the pinned xcframework rather than a local Rust build. This is the
# script that puts the app on a phone you actually use, so it should install
# what a user would get — Debug's -Onone changes how anything timing-sensitive
# in the transport behaves. Pass --local when you are testing an unreleased FFI.
#
# Overrides:
#   DUOCB_MAC_DEVICE_HOST   ssh alias of the Mac the phone is paired with
#                           (default: macwork — note this is NOT mac-ci.sh's
#                           default host: a VM can build and sign but can never
#                           pair with hardware, so the two are different Macs)
#   DUOCB_MAC_TMUX          tmux session to type into    (default: ios)
#   DUOCB_MAC_DEVICE        device selector              (default: iPhone)
#   DUOCB_MAC_ROOT          staging area on the Mac      (default: codes/staging-area)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_DIR=$PWD

HOST=${DUOCB_MAC_DEVICE_HOST:-macwork}
SESSION=${DUOCB_MAC_TMUX:-ios}
REMOTE_ROOT=${DUOCB_MAC_ROOT:-codes/staging-area}
REMOTE_REPO="$REMOTE_ROOT/duocb-ios"
# Written fresh on every run and left behind afterwards: when something fails
# mid-build, the log is the only copy of the output that outlives the pane's
# scrollback.
RUNNER="$REMOTE_ROOT/duocb-device-run.sh"
LOG="$REMOTE_ROOT/duocb-device-run.log"
BUNDLE_ID=com.andrewtheguy.duocb
APP_NAME=duocb
# The runner's last line. The tail below stops on it and takes the exit status
# from it, because a command sent to a tmux pane has no status to return.
SENTINEL=__DUOCB_DEVICE_DONE

selector=${DUOCB_MAC_DEVICE:-iPhone}
configuration=Release
xcframework=pinned
sync=true
launch=true
command=

info() { echo "[device] $*"; }
die() { echo "[device] error: $*" >&2; exit 1; }

usage() {
    sed -n '3,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    cat >&2 <<'USAGE'

options:
  --device SELECTOR   identifier, UDID or name of the target device
  -c, --configuration NAME
                      build configuration (default: Release)
  --local             link ../duocb's working-tree build instead of the pinned
                      release, building the xcframework on the Mac first
  --no-sync           use the tree already on the Mac, do not rsync
  --no-launch         install without launching
  --host ALIAS        ssh alias of the Mac (default: macwork)
  --session NAME      tmux session to type into (default: ios)
USAGE
    exit 2
}

while [ $# -gt 0 ]; do
    case $1 in
        --device) selector=${2:?--device needs a value}; shift 2 ;;
        -c|--configuration) configuration=${2:?--configuration needs a value}; shift 2 ;;
        --local) xcframework=local; shift ;;
        --no-sync) sync=false; shift ;;
        --no-launch) launch=false; shift ;;
        --host) HOST=${2:?--host needs a value}; shift 2 ;;
        --session) SESSION=${2:?--session needs a value}; shift 2 ;;
        -h|--help) usage ;;
        run|install|status|devices|doctor)
            [ -z "$command" ] || die "one command at a time (already have '$command')"
            command=$1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
command=${command:-run}
# An `[ … ] && x` one-liner would take the whole script down under `set -e` on
# the false branch; these are plain ifs for that reason.
if [ "$command" = install ]; then launch=false; fi

# Every ssh below shares one multiplexed connection. The log is followed by
# polling (see the stream loop), which without this would be a fresh TCP+auth
# handshake every couple of seconds for the length of a build.
CTL=${TMPDIR:-/tmp}/duocb-device-ssh-$$
SSH=(ssh -o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=120)
cleanup() { ssh -O exit -o ControlPath="$CTL" "$HOST" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Commands go in on stdin rather than as arguments: no second round of quoting
# to get wrong. PATH is set here rather than left to the login shell — `bash -l`
# reads bash's profile, and on a Mac whose login shell is zsh that never adds
# Homebrew's bin, so tmux/xcodegen/jq would all read as missing.
remote() {
    {
        echo 'export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"'
        cat
    } | "${SSH[@]}" "$HOST" bash -l -s
}

"${SSH[@]}" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true \
    || die "cannot reach '$HOST' over ssh — check ~/.ssh/config and that the Mac is awake"

# ---------------------------------------------------------------- device list

# One TSV row per paired device, from the copy of list-devices-ios.sh already on
# the Mac — devicectl and jq are over there, and so is the JSON.
device_rows() {
    remote <<REMOTE
cd '$REMOTE_REPO' 2>/dev/null || { echo "NOTREE" >&2; exit 1; }
scripts/list-devices-ios.sh --tsv
REMOTE
}

# Transport is blank when the Mac's copy of list-devices-ios.sh predates that
# column — read-only subcommands deliberately do not sync, so they can be
# reading an older tree. "unknown" says so; it must not read as a device state.
print_devices() {
    awk -F'\t' '
        BEGIN { printf "  %-38s %-26s %-14s %s\n", "IDENTIFIER", "UDID", "TRANSPORT", "NAME" }
        { printf "  %-38s %-26s %-14s %s\n", $1, $2, ($8 == "" ? "unknown" : $8), $7 }'
}

# Exactly one match or nothing. Choosing silently between a phone and a tablet
# is worse than asking: the failure mode of guessing is an app installed on
# someone's iPad.
resolve_device() {
    local rows matches count
    rows=$(device_rows) || die "could not list devices on $HOST (is the tree synced? drop --no-sync)"
    [ -n "$rows" ] || die "$HOST has no paired devices"
    matches=$(printf '%s\n' "$rows" | awk -F'\t' -v sel="$selector" '
        tolower($1) == tolower(sel) || tolower($2) == tolower(sel) || tolower($7) == tolower(sel)')
    count=$(printf '%s' "$matches" | grep -c . || true)
    if [ "$count" -ne 1 ]; then
        {
            if [ "$count" -eq 0 ]; then
                echo "no device on $HOST matches '$selector'. Paired:"
            else
                echo "'$selector' matches $count devices on $HOST. Paired:"
            fi
            printf '%s\n' "$rows" | print_devices
        } >&2
        exit 1
    fi
    printf '%s' "$matches"
}

# ------------------------------------------------------- read-only subcommands

case $command in
    devices)
        info "paired devices on $HOST"
        rows=$(device_rows) || die "could not list devices on $HOST"
        printf '%s\n' "$rows" | print_devices
        exit 0 ;;
    doctor)
        info "checking $HOST"
        remote <<REMOTE
sw_vers -productName; sw_vers -productVersion
xcodebuild -version | head -1
printf 'xcodegen:   '; command -v xcodegen || echo 'MISSING (brew install xcodegen)'
printf 'jq:         '; command -v jq || echo 'MISSING (brew install jq) — device listing will fail'
printf 'identities: '; security find-identity -v -p codesigning | tail -1
printf 'tree:       '; ls -d '$REMOTE_REPO' 2>/dev/null || echo 'not synced yet'
printf 'tmux %-6s ' '$SESSION:'
if ! tmux has-session -t '$SESSION' 2>/dev/null; then
    echo 'MISSING — start it from a GUI Terminal on the Mac: tmux new -s $SESSION'
elif ! pane=\$(tmux display -p -t '$SESSION' '#{pane_current_command}'); then
    echo 'present, but its pane could not be read'
else
    case \$pane in
        bash|zsh|sh|fish|-bash|-zsh)
            echo "present and idle (\$pane)"
            # The check that decides whether a signed build can happen at all,
            # and the only one that has to run *inside* the session: over ssh
            # the keychain always reads as locked, which is the whole reason
            # this script types into tmux rather than running the build here.
            # Only sent to an idle pane — a busy one would swallow it.
            printf 'keychain:   '
            tmux send-keys -t '$SESSION' 'security show-keychain-info ~/Library/Keychains/login.keychain-db 2>&1 | sed "s/^/probe: /"' Enter
            sleep 2
            probe=\$(tmux capture-pane -p -t '$SESSION' -S -6 | grep '^probe: ' | tail -1)
            case \$probe in
                *'interaction is not allowed'*|*locked*)
                    echo "LOCKED — this session is not from a GUI login, so signing will fail" ;;
                '') echo 'no answer from the pane' ;;
                *)  echo "unlocked — signing can run here (\${probe#probe: })" ;;
            esac ;;
        *) echo "present but busy running '\$pane' — a run would be refused" ;;
    esac
fi
REMOTE
        echo
        info 'paired devices'
        device_rows 2>/dev/null | print_devices || info 'none (or the tree is not synced)'
        exit 0 ;;
esac

device_row=$(resolve_device) || exit 1
IFS=$'\t' read -r device_id device_udid _ _ device_os device_model device_name device_transport <<<"$device_row"
device_transport=${device_transport:-unknown}
info "device: $device_name — $device_model, iOS $device_os, over $device_transport"
info "  $device_id"
if [ "$device_transport" = unavailable ]; then
    die "$device_name is paired with $HOST but not reachable from it right now.
       Attach it by USB, or wake and unlock it on the same network with Wi-Fi on,
       then retry. Nothing has been built."
fi

if [ "$command" = status ]; then
    remote <<REMOTE
echo '--- installed ---'
xcrun devicectl device info apps --device '$device_id' --bundle-id '$BUNDLE_ID' 2>/dev/null | tail -n +3
echo '--- running ---'
# Matched on the bundle path, not the id: this listing is pid + executable
# path, and $BUNDLE_ID appears nowhere in
# /private/var/containers/Bundle/Application/<uuid>/$APP_NAME.app/$APP_NAME.
procs=\$(xcrun devicectl device info processes --device '$device_id' 2>/dev/null | grep -F '/$APP_NAME.app/' || true)
if [ -n "\$procs" ]; then printf '%s\n' "\$procs" | awk '{ printf "  pid %-8s %s\n", \$1, \$2 }'
else echo '  not running (installed apps are listed above)'; fi
REMOTE
    exit 0
fi

# --------------------------------------------------------------- build and run

if $sync; then
    # mac-ci.sh owns the rsync — the exclude list is load-bearing (it is what
    # keeps the Mac's incremental Rust build alive) and must not exist twice.
    info "syncing to $HOST"
    DUOCB_MAC_ROOT="$REMOTE_ROOT" "$REPO_DIR/scripts/mac-ci.sh" --host "$HOST" --sync-only
fi

# --local needs the sibling's iOS build to exist *on the Mac*: dist/ is excluded
# from the sync (see mac-ci.sh), so the working-tree xcframework is built there,
# in the same session, right before the app.
build_core=
if [ "$xcframework" = local ]; then
    build_core="(cd ../duocb && ./build-ios.sh release) || status=1"
fi

run_args="--device '$device_id' -c '$configuration'"
if [ "$xcframework" = pinned ]; then run_args="$run_args --pinned"; fi
if ! $launch; then run_args="$run_args --no-launch"; fi

info "writing the runner to $HOST:$RUNNER"
remote <<REMOTE
mkdir -p '$REMOTE_ROOT'
cat > '$RUNNER' <<'RUNNER_EOF'
#!/bin/bash
# Generated by scripts/mac-device.sh — overwritten on every run.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:\$HOME/.cargo/bin:\$PATH"
cd "\$HOME/$REMOTE_REPO" || exit 1
status=0
# The reason this runs in tmux rather than over ssh. Checked before a build so
# the failure names the cause, instead of surfacing as errSecInternalComponent
# several minutes in.
if ! security show-keychain-info ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
    echo "error: the login keychain is locked in this tmux session, so codesign cannot"
    echo "       read the signing key. This session has to belong to a GUI login —"
    echo "       start it from Terminal.app on the Mac:  tmux new -s $SESSION"
    status=1
else
    $build_core
    if [ \$status -eq 0 ]; then
        scripts/run-device-ios.sh $run_args
        status=\$?
    fi
fi
echo "$SENTINEL exit=\$status"
RUNNER_EOF
chmod +x '$RUNNER'
rm -f '$LOG'

tmux has-session -t '$SESSION' 2>/dev/null \
    || { echo "[remote] no tmux session '$SESSION' — start it from a GUI Terminal on the Mac: tmux new -s $SESSION" >&2; exit 1; }
# Refuse to type into a pane that is busy: send-keys would append the command
# to whatever is already running there, which at best loses it and at worst
# answers a prompt nobody meant to answer.
running=\$(tmux display -p -t '$SESSION' '#{pane_current_command}')
case \$running in
    bash|zsh|sh|fish|-bash|-zsh) ;;
    *) echo "[remote] session '$SESSION' is busy running '\$running' — wait for it or use --session" >&2; exit 1 ;;
esac
tmux send-keys -t '$SESSION' "bash '\$HOME/$RUNNER' 2>&1 | tee '\$HOME/$LOG'" Enter
REMOTE

info "running in $HOST:tmux($SESSION) — $configuration, $xcframework xcframework"
echo

# Follow the log by polling for the lines not yet seen, rather than `tail -f`:
# a remote tail only notices its reader is gone the next time it writes, and the
# last thing this log ever gets is the sentinel — so a tail started here would
# outlive the run and hold the connection open forever. Polling has no such
# process to leave behind, and over the shared connection each read is cheap.
#
# The run itself lives in the tmux session, so Ctrl-C here detaches from the
# output; it does not kill the build. Re-attach with: ssh $HOST tail -f $LOG
status=
next=1
stalled=0
while [ -z "$status" ]; do
    chunk=$("${SSH[@]}" "$HOST" "sed -n '$next,\$p' \"\$HOME/$LOG\" 2>/dev/null" || true)
    if [ -n "$chunk" ]; then
        stalled=0
        next=$((next + $(printf '%s\n' "$chunk" | wc -l)))
        while IFS= read -r line; do
            case "$line" in
                "$SENTINEL "*) status=${line#*exit=} ;;
                *) printf '%s\n' "$line" ;;
            esac
        done <<<"$chunk"
    else
        # Nothing new. Xcode goes quiet for a while mid-build, so this is only
        # fatal once the pane is idle again: that means the runner ended
        # without its sentinel — killed, or the pane was interrupted.
        stalled=$((stalled + 1))
        if [ "$stalled" -ge 15 ]; then
            pane=$(remote <<<"tmux display -p -t '$SESSION' '#{pane_current_command}' 2>/dev/null" || true)
            case $pane in
                bash|zsh|sh|fish|-bash|-zsh)
                    die "the run ended without finishing (the pane is idle again). Log: ssh $HOST cat $LOG" ;;
            esac
            stalled=0
        fi
    fi
    if [ -z "$status" ]; then sleep 2; fi
done

echo
if [ "$status" = 0 ]; then
    info "done — $APP_NAME ($configuration) is on $device_name"
    $launch || info 'not launched (--no-launch): open it from the home screen'
else
    info "failed (exit $status). Full log: ssh $HOST cat $LOG"
fi
exit "$status"
