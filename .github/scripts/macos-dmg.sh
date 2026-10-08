#!/usr/bin/env bash
# TASK-69 (macOS): package Conduit.app as a disk image and verify it.
#
# Usage: macos-dmg.sh <Conduit.app> <version> <dist-dir>
#
# Writes <dist-dir>/conduit-<version>-macos-<arch>.dmg and its .sha256. The
# image holds the app and an /Applications link, the usual drag-to-install
# layout. Signing:
#
#   - When MACOS_SIGNING_IDENTITY is set (a "Developer ID Application: ..."
#     identity already imported into the keychain by the caller), the app is
#     signed with the hardened runtime before packaging and the image after.
#     Notarization (`xcrun notarytool submit --wait` and `xcrun stapler staple`)
#     additionally needs MACOS_NOTARY_* credentials; see docs/release.md.
#   - Otherwise the app is signed ad hoc. An ad hoc signature binds the bundle
#     together but is not trusted by Gatekeeper: the downloaded app is
#     unsigned as far as users are concerned (docs/release.md says how to open
#     it).
#
# Verification mounts the finished image read-only and checks the payload: the
# app, the /Applications link, Info.plist's version, `codesign --verify`, and
# that the mounted executable prints `conduit <version>`.
set -euo pipefail

app="${1:?usage: macos-dmg.sh <Conduit.app> <version> <dist-dir>}"
version="${2:?usage: macos-dmg.sh <Conduit.app> <version> <dist-dir>}"
dist="${3:?usage: macos-dmg.sh <Conduit.app> <version> <dist-dir>}"
mkdir -p "$dist"
arch="$(uname -m)"
name="conduit-$version-macos-$arch.dmg"
dmg="$dist/$name"
work="$(mktemp -d "${TMPDIR:-/tmp}/cdmg.XXXXXX")"
trap 'hdiutil detach "$work/mnt" -quiet > /dev/null 2>&1 || true; rm -rf "$work"' EXIT

stage="$work/stage"
mkdir -p "$stage"
ditto "$app" "$stage/Conduit.app"
ln -s /Applications "$stage/Applications"

if [ -n "${MACOS_SIGNING_IDENTITY:-}" ]; then
  codesign --force --deep --options runtime --timestamp --sign "$MACOS_SIGNING_IDENTITY" "$stage/Conduit.app"
  signing="Developer ID ($MACOS_SIGNING_IDENTITY)"
else
  codesign --force --deep --sign - "$stage/Conduit.app"
  signing="ad hoc (unsigned for Gatekeeper)"
fi
codesign --verify --strict --verbose=2 "$stage/Conduit.app"

rm -f "$dmg"
hdiutil create -volname "Conduit $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" > /dev/null
if [ -n "${MACOS_SIGNING_IDENTITY:-}" ]; then
  codesign --force --sign "$MACOS_SIGNING_IDENTITY" --timestamp "$dmg"
fi
hdiutil verify "$dmg" > /dev/null
echo "PASS created $name, app signed $signing"

# Verify the image as a user would receive it.
mkdir -p "$work/mnt"
hdiutil attach "$dmg" -readonly -nobrowse -noautoopen -mountpoint "$work/mnt" > /dev/null
mounted="$work/mnt/Conduit.app"
[ -d "$mounted" ] || { echo "FAIL $name has no Conduit.app" >&2; exit 1; }
[ "$(readlink "$work/mnt/Applications")" = /Applications ] || { echo "FAIL $name has no /Applications link" >&2; exit 1; }
info="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleGetInfoString' "$mounted/Contents/Info.plist")"
[ "$info" = "Conduit $version" ] || { echo "FAIL Info.plist says '$info'" >&2; exit 1; }
codesign --verify --strict "$mounted"
reported="$("$mounted/Contents/MacOS/conduit" --version)"
[ "$reported" = "conduit $version" ] || { echo "FAIL the mounted app printed '$reported'" >&2; exit 1; }
[ -s "$mounted/Contents/Resources/AppIcon.icns" ] || { echo "FAIL no icon in the mounted app" >&2; exit 1; }
ls "$mounted/Contents/Resources/licenses" > /dev/null
hdiutil detach "$work/mnt" -quiet
echo "PASS mounted $name: Conduit.app, /Applications link, '$info', codesign verifies, prints '$reported'"

(cd "$dist" && shasum -a 256 "$name" > "$name.sha256")
cat "$dist/$name.sha256"
du -h "$dmg"
