#!/usr/bin/env bash
# Build, validate, sign, and package a host-architecture macOS release.
# Optional environment: OHMLAB_CODESIGN_IDENTITY and OHMLAB_NOTARY_PROFILE.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$root/dist}"
cd "$root"

swift build -c release
bin_path="$(swift build -c release --show-bin-path)"
version="$($bin_path/ohm --version)"
version="${version#ohm }"
[[ -n "$version" ]] || { printf 'could not determine release version\n' >&2; exit 1; }

architecture="$(uname -m)"
product="OhmLab-$version-macos-$architecture"
work="$(mktemp -d)"
stage="$work/$product"
app="$stage/OhmLab.app"
archive="$output/$product.zip"
checksum="$archive.sha256"
trap 'rm -rf "$work"' EXIT

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$stage/bin" "$stage/docs/contracts" "$output"
cp "$bin_path/OhmLab" "$app/Contents/MacOS/OhmLab"
cp "$bin_path/ohm" "$stage/bin/ohm"
cp LICENSE README.md "$stage/"
cp docs/contracts/*.md "$stage/docs/contracts/"
sed "s/@VERSION@/$version/g" Packaging/Info.plist.in >"$app/Contents/Info.plist"
printf '{\n  "product": "OhmLab",\n  "version": "%s",\n  "platform": "macOS",\n  "architecture": "%s",\n  "minimumSystemVersion": "14.0"\n}\n' \
    "$version" "$architecture" >"$stage/release.json"

"$stage/bin/ohm" --version | grep -qx "ohm $version"
"$stage/bin/ohm" doctor --json | grep -Eq '"ready"[[:space:]]*:[[:space:]]*true'
"$stage/bin/ohm" qualify-linear --json | grep -Eq '"ready"[[:space:]]*:[[:space:]]*true'
"$stage/bin/ohm" qualify-nonlinear --json | grep -Eq '"ready"[[:space:]]*:[[:space:]]*true'

identity="${OHMLAB_CODESIGN_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then
    timestamp=(--timestamp=none)
else
    timestamp=(--timestamp)
fi
codesign --force "${timestamp[@]}" --options runtime --sign "$identity" "$stage/bin/ohm"
codesign --force "${timestamp[@]}" --options runtime --sign "$identity" "$app/Contents/MacOS/OhmLab"
codesign --force "${timestamp[@]}" --options runtime --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
codesign --verify --strict "$stage/bin/ohm"

rm -f "$archive" "$checksum"
ditto -c -k --sequesterRsrc --keepParent "$stage" "$archive"
if [[ -n "${OHMLAB_NOTARY_PROFILE:-}" ]]; then
    [[ "$identity" != "-" ]] || { printf 'notarization requires a Developer ID identity\n' >&2; exit 1; }
    xcrun notarytool submit "$archive" --keychain-profile "$OHMLAB_NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    rm -f "$archive"
    ditto -c -k --sequesterRsrc --keepParent "$stage" "$archive"
fi

(cd "$output" && shasum -a 256 "$(basename "$archive")" >"$(basename "$checksum")")
(cd "$output" && shasum -a 256 -c "$(basename "$checksum")")
printf 'Packaged %s\nChecksum %s\n' "$archive" "$checksum"
