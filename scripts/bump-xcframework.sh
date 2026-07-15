#!/usr/bin/env bash
#
# Point Packages/Duocb/Package.swift's binary target at a duocb release.
# Downloads the release's libduocb-ios.xcframework.zip, computes its SPM
# checksum (the plain sha256 of the zip), and rewrites the url + checksum lines.
# Also syncs project.yml's MARKETING_VERSION to the release version (the tag
# without its leading "v") so the app's displayed version matches the FFI build,
# then regenerates the Xcode project.
#
# Usage:
#   scripts/bump-xcframework.sh v0.0.11
#   scripts/bump-xcframework.sh            # defaults to the latest release tag
set -euo pipefail

REPO="andrewtheguy/duocb"
ASSET="libduocb-ios.xcframework.zip"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/../Packages/Duocb/Package.swift"
PROJECT_YML="$SCRIPT_DIR/../project.yml"

die() { echo "error: $*" >&2; exit 1; }

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
  command -v gh >/dev/null || die "no tag given and gh not installed to resolve the latest"
  TAG="$(gh release view --repo "$REPO" --json tagName --jq .tagName)"
fi

URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "Downloading $URL ..."
curl -fL --retry 3 -o "$TMP/$ASSET" "$URL" || die "download failed: $URL"
CHECKSUM="$(shasum -a 256 "$TMP/$ASSET" | cut -d' ' -f1)"

# BSD sed (macOS) needs the empty -i arg; portable form via a temp file.
sed -E \
  -e "s#releases/download/[^/]+/${ASSET}#releases/download/${TAG}/${ASSET}#" \
  -e "s/checksum: \"[a-f0-9]+\"/checksum: \"${CHECKSUM}\"/" \
  "$MANIFEST" > "$TMP/Package.swift"
mv "$TMP/Package.swift" "$MANIFEST"

# Keep the app's MARKETING_VERSION in step with the release version (tag minus
# its leading "v"), so ConfigureView's "v<version>" matches the FFI build.
VERSION="${TAG#v}"
sed -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*)\"[^\"]*\"/\1\"${VERSION}\"/" \
  "$PROJECT_YML" > "$TMP/project.yml"
mv "$TMP/project.yml" "$PROJECT_YML"

echo "Updated $MANIFEST:"
echo "  tag:      $TAG"
echo "  checksum: $CHECKSUM"
echo "Updated $PROJECT_YML:"
echo "  MARKETING_VERSION: $VERSION"

# Regenerate the Xcode project so the new version lands in the build settings.
if command -v xcodegen >/dev/null; then
  ( cd "$SCRIPT_DIR/.." && xcodegen generate )
  echo "Regenerated Duocb.xcodeproj"
else
  echo "warning: xcodegen not installed — run 'xcodegen generate' to apply" >&2
fi
