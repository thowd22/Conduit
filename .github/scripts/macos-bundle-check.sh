#!/usr/bin/env bash
# TASK-48 AC2: Conduit.app is a proper bundle and renders at Retina density.
#
# Usage: macos-bundle-check.sh <Conduit.app> <conduit-test> <expected-version> <artifact-dir>
#
#   1. Bundle structure: Info.plist lints and names the executable, identifier,
#      icon, version and NSHighResolutionCapable; the icon decodes with
#      iconutil; every shipped resource is present; the executable reports the
#      stamped version.
#   2. Signature: the bundle is signed ad hoc (or already signed) and
#      `codesign --verify --strict` accepts it, which binds Info.plist and the
#      resources to the executable.
#   3. Launch Services: `open -W -n` starts the bundle as an app, and its log
#      shows a Cocoa window.
#   4. Display density: the executable run with no fixed scale logs what the
#      runner's display reports (the scale rule, pixel density and geometry).
#   5. Retina frame: the bundle's executable is driven through conduit-test at
#      a fixed scale of 2 in a visible 640x360 window. The screenshot must be
#      exactly 1280x720 physical pixels; it is kept for visual inspection.
set -euo pipefail

app="${1:?usage: macos-bundle-check.sh <Conduit.app> <conduit-test> <version> <artifact-dir>}"
driver="${2:?usage}"
version="${3:?usage}"
out="${4:?usage}"
mkdir -p "$out"
exe="$app/Contents/MacOS/conduit"
plist="$app/Contents/Info.plist"
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }
alarm() { perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$@"; }

# 1. Structure.
plutil -lint "$plist" > /dev/null || fail "Info.plist does not lint"
key() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
[ "$(key CFBundleExecutable)" = conduit ] || fail "CFBundleExecutable is not conduit"
[ "$(key CFBundleIdentifier)" = io.github.thowd22.Conduit ] || fail "CFBundleIdentifier"
[ "$(key CFBundlePackageType)" = APPL ] || fail "CFBundlePackageType"
[ "$(key CFBundleIconFile)" = AppIcon ] || fail "CFBundleIconFile"
[ "$(key NSHighResolutionCapable)" = true ] || fail "NSHighResolutionCapable is not true"
[ "$(key CFBundleGetInfoString)" = "Conduit $version" ] || fail "CFBundleGetInfoString is not 'Conduit $version'"
short="$(key CFBundleShortVersionString)"
[[ "$version" == "$short"* ]] || fail "CFBundleShortVersionString $short is not the core of $version"
minimum="$(key LSMinimumSystemVersion)"
pass "Info.plist: conduit, io.github.thowd22.Conduit, $short, minimum macOS $minimum, high resolution"
built_min="$(vtool -show-build "$exe" 2>/dev/null | awk '/minos/ {print $2; exit}')"
echo "INFO executable LC_BUILD_VERSION minos: ${built_min:-unknown}"
iconutil --convert iconset --output "$out/AppIcon.iconset" "$app/Contents/Resources/AppIcon.icns"
icons="$(ls "$out/AppIcon.iconset" | tr '\n' ' ')"
case "$icons" in
  *icon_512x512@2x.png*) pass "AppIcon.icns decodes: $icons" ;;
  *) fail "AppIcon.icns has no 1024 render: $icons" ;;
esac
for resource in \
  fonts/JetBrainsMono-Regular.ttf fonts/SymbolsNerdFontMono-Regular.ttf \
  shell-integration/bash/conduit.bash shell-integration/zsh/conduit.zsh \
  shell-integration/zsh/.zshenv shell-integration/fish/vendor_conf.d/conduit.fish \
  licenses/LICENSE licenses/Ghostty-LICENSE licenses/SDL-LICENSE.txt \
  licenses/JetBrainsMono-OFL-1.1.txt licenses/NerdFonts-LICENSE.txt licenses/FreeType-LICENSE.TXT \
  licenses/HarfBuzz-COPYING.txt licenses/Oniguruma-COPYING.txt licenses/zlib-LICENSE.txt \
  licenses/libpng-LICENSE.txt licenses/zopengl-LICENSE licenses/themes-README.md; do
  [ -s "$app/Contents/Resources/$resource" ] || fail "missing Resources/$resource"
done
pass "every shipped resource is in Contents/Resources"
reported="$("$exe" --version)"
[ "$reported" = "conduit $version" ] || fail "--version printed '$reported'"
pass "the bundle's executable prints '$reported'"
file "$exe" | grep -q "arm64\|x86_64" || fail "the executable is not a Mach-O binary"
file "$exe"

# 2. Signature.
if ! codesign --verify --strict "$app" 2> /dev/null; then
  codesign --force --deep --sign - "$app"
fi
codesign --verify --strict --verbose=2 "$app"
codesign --display --verbose=2 "$app" 2>&1 | grep -E "Identifier|Format|Signature" || true
pass "codesign verifies the bundle"

# 3. Launch Services.
open_log="$out/open-launch.log"
rm -f "$open_log"
alarm 120 open -W -n "$app" --args --hidden --no-child --run-ms=3000 --log-file="$open_log"
grep -F "window backend cocoa" "$open_log" || fail "open did not start a Cocoa window (see $open_log)"
pass "open -W -n started the bundle as an app"

# 4. What the runner's display reports, with no fixed scale.
native_log="$out/native-scale.log"
alarm 120 "$exe" --no-child --run-ms=2000 --width=640 --height=360 --log-file="$native_log"
grep -E "window conduit|physical pixels per logical|window geometry" "$native_log" | sed 's/^/INFO /'

# 5. A Retina frame from the bundle through the real driver path.
root="$(mktemp -d "${TMPDIR:-/tmp}/cret.XXXXXX")"
run="$("$driver" --root="$root" launch --conduit="$exe" --visible --width=640 --height=360 --scale=2 \
  --command="printf 'Retina 2x kestrel lantern 0123456789 {}[]<>=> ~/src\\n'; exec cat")"
ct() { "$driver" --root="$root" --run="$run" "$@"; }
trap 'ct quit > /dev/null 2>&1 || true' EXIT
ct wait-for terminal-text "kestrel lantern" 10000 > /dev/null
shot="$(ct screenshot)"
cp "$shot" "$out/retina-2x.png"
ct logs 1048576 > "$out/retina-app.log"
ct quit > /dev/null
trap - EXIT
width="$(sips -g pixelWidth "$out/retina-2x.png" | awk '/pixelWidth/ {print $2}')"
height="$(sips -g pixelHeight "$out/retina-2x.png" | awk '/pixelHeight/ {print $2}')"
[ "$width" = 1280 ] && [ "$height" = 720 ] || fail "the 2x frame is ${width}x${height}, expected 1280x720"
grep -E "window conduit|physical pixels per logical|window geometry|now drawing|drawing with" "$out/retina-app.log" | sed 's/^/INFO /' || true
pass "a 640x360 window at scale 2 produced a 1280x720 frame ($out/retina-2x.png)"
