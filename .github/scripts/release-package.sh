#!/usr/bin/env bash
# Package a staged Conduit install prefix into the Linux release artifacts.
#
# Usage: release-package.sh <version> <stage-dir> <dist-dir> [tools-dir]
#
#   version    the SemVer version the binary was built with (`-Dversion=`),
#              without a leading `v`
#   stage-dir  the `--prefix` that `zig build` installed into
#   dist-dir   where the artifacts are written; created if missing
#   tools-dir  directory holding the pinned `appimagetool-x86_64.AppImage` and
#              `runtime-x86_64` (see release-fetch-appimagetool.sh). Without
#              it the AppImage leg is skipped, which is only acceptable when
#              RELEASE_ALLOW_MISSING_APPIMAGE=1 is set for a local dry run.
#
# Produces, under dist-dir:
#   conduit-<version>-x86_64-linux.tar.gz
#   conduit_<version>_amd64.deb   (the control file carries the Debian form, e.g. 0.1.0~rc.1)
#   Conduit-<version>-x86_64.AppImage
#   SHA256SUMS
#
# Only stage-dir is read and only dist-dir is written. The script never
# consults the user's configuration or state and installs nothing on the host.
set -euo pipefail

version="${1:?usage: release-package.sh <version> <stage-dir> <dist-dir> [tools-dir]}"
stage="${2:?usage: release-package.sh <version> <stage-dir> <dist-dir> [tools-dir]}"
dist="${3:?usage: release-package.sh <version> <stage-dir> <dist-dir> [tools-dir]}"
tools="${4:-}"
glibc_baseline="${GLIBC_BASELINE:-2.35}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
app_id="io.github.thowd22.Conduit"

# Payload every package must carry, relative to the prefix.
required_payload=(
  bin/conduit
  "share/applications/$app_id.desktop"
  share/conduit/fonts/JetBrainsMono-Regular.ttf
  share/conduit/shell-integration/bash/conduit.bash
  share/conduit/shell-integration/zsh/.zshenv
  share/conduit/shell-integration/zsh/conduit.zsh
  share/conduit/shell-integration/fish/vendor_conf.d/conduit.fish
  share/licenses/conduit/LICENSE
  share/licenses/conduit/Ghostty-LICENSE
  share/licenses/conduit/SDL-LICENSE.txt
  share/licenses/conduit/zopengl-LICENSE
  share/licenses/conduit/FreeType-FTL.txt
  share/licenses/conduit/FreeType-LICENSE.TXT
  share/licenses/conduit/HarfBuzz-COPYING.txt
  share/licenses/conduit/Oniguruma-COPYING.txt
  share/licenses/conduit/JetBrainsMono-OFL-1.1.txt
)
# The application icon at every freedesktop hicolor size build.zig installs.
icon_sizes=(16 22 24 32 48 64 128 256 512)
for size in "${icon_sizes[@]}"; do
  required_payload+=("share/icons/hicolor/${size}x${size}/apps/$app_id.png")
done

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
[[ "$version" =~ $semver ]] || fail "version '$version' is not SemVer without a leading 'v'"

# Debian orders `1.0.0-rc.1` above `1.0.0` because `-` introduces a package
# revision; `~` sorts below the release, which is what a prerelease means.
deb_version="${version/-/\~}"

for rel in "${required_payload[@]}"; do
  [ -f "$stage/$rel" ] || fail "staged prefix is missing $rel"
done
pass "staged prefix has every required payload file"

# Runtime shared libraries the binary links, mapped to the Debian packages
# that provide them. An unmapped soname fails the packaging on purpose: the
# dependency list must come from the binary, not from memory.
declare -A soname_to_package=(
  ["libc.so.6"]="libc6 (>= $glibc_baseline)"
  ["libm.so.6"]="libc6 (>= $glibc_baseline)"
  ["libdl.so.2"]="libc6 (>= $glibc_baseline)"
  ["libpthread.so.0"]="libc6 (>= $glibc_baseline)"
  ["librt.so.1"]="libc6 (>= $glibc_baseline)"
  ["ld-linux-x86-64.so.2"]="libc6 (>= $glibc_baseline)"
  ["libgcc_s.so.1"]="libgcc-s1"
  ["libstdc++.so.6"]="libstdc++6"
)
mapfile -t needed < <(readelf -d "$stage/bin/conduit" | sed -nE 's/.*\(NEEDED\).*\[([^]]+)\].*/\1/p')
[ "${#needed[@]}" -gt 0 ] || fail "readelf reports no NEEDED entries for bin/conduit"
declare -A depends_set=()
for soname in "${needed[@]}"; do
  pkg="${soname_to_package[$soname]:-}"
  [ -n "$pkg" ] || fail "bin/conduit links $soname, which has no Debian package mapping in $(basename "$0")"
  depends_set["$pkg"]=1
done
linked_depends="$(printf '%s\n' "${!depends_set[@]}" | sort | paste -sd, - | sed 's/,/, /g')"
echo "INFO: bin/conduit NEEDED: ${needed[*]}"
echo "INFO: linked Depends: $linked_depends"

# SDL3 is linked statically and dlopens the display and GL stacks at runtime,
# so they never appear in NEEDED. Conduit cannot start without OpenGL and one
# windowing system, which makes those hard dependencies; the rest of the
# dlopened set is Recommends so a minimal X11-only or Wayland-only host still
# installs cleanly.
runtime_depends="libgl1, libx11-6 | libwayland-client0"
recommends="libx11-6, libxext6, libxcursor1, libxi6, libxrandr2, libxfixes3, libxkbcommon0, libwayland-client0, libwayland-cursor0, libwayland-egl1, libegl1, libdecor-0-0, libdbus-1-3"
depends="$linked_depends, $runtime_depends"

mkdir -p "$dist"
work="$(mktemp -d "$dist/.package-work.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

# One payload tree for every package: the staged prefix minus the test-driver
# CLI, which is development tooling rather than part of the product.
payload="$work/payload"
mkdir -p "$payload"
cp -a -- "$stage/." "$payload/"
rm -f -- "$payload/bin/conduit-test"
find "$payload" -type d -empty -delete

# Deterministic archive metadata: fixed owner, sorted entries, and the commit
# timestamp when the workflow supplies one.
epoch="${SOURCE_DATE_EPOCH:-$(date +%s)}"
tar_name="conduit-$version-x86_64-linux"
tar_path="$dist/$tar_name.tar.gz"
rm -f -- "$tar_path"
ln -s -- "$payload" "$work/$tar_name"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$epoch" \
  --dereference -C "$work" -cf - "$tar_name" | gzip -n -9 > "$tar_path"
pass "wrote $(basename "$tar_path")"

# Debian package.
deb_root="$work/deb"
mkdir -p "$deb_root/DEBIAN" "$deb_root/usr" "$deb_root/usr/share/doc/conduit"
cp -a -- "$payload/." "$deb_root/usr/"
cp -- "$repo_root/packaging/debian/copyright.in" "$deb_root/usr/share/doc/conduit/copyright"
installed_size="$(du -sk --apparent-size "$deb_root/usr" | cut -f1)"
# Bash substitution rather than sed: Depends legitimately contains `|`, `(`
# and `>=`, none of which may be special in the template expansion.
control="$(cat -- "$repo_root/packaging/debian/control.in")"
control="${control//@VERSION@/$deb_version}"
control="${control//@INSTALLED_SIZE@/$installed_size}"
control="${control//@DEPENDS@/$depends}"
control="${control//@RECOMMENDS@/$recommends}"
printf '%s\n' "$control" > "$deb_root/DEBIAN/control"
if grep -q '@[A-Z_]*@' "$deb_root/DEBIAN/control"; then
  fail "unexpanded placeholder in DEBIAN/control"
fi
(cd "$deb_root" && find usr -type f -print0 | sort -z | xargs -0 md5sum > DEBIAN/md5sums)
chmod 0755 "$deb_root/DEBIAN" && chmod 0644 "$deb_root/DEBIAN/control" "$deb_root/DEBIAN/md5sums"
find "$deb_root/usr" -type d -exec chmod 0755 {} +
find "$deb_root/usr" -type f -exec chmod 0644 {} +
chmod 0755 "$deb_root/usr/bin/conduit"
# The file name keeps the SemVer spelling: GitHub release assets cannot contain `~` and would be
# renamed on upload, which breaks SHA256SUMS and --clobber matching. Only the control file's
# Version field uses the Debian `~` form.
deb_path="$dist/conduit_${version}_amd64.deb"
rm -f -- "$deb_path"
dpkg-deb --build --root-owner-group "$deb_root" "$deb_path" > /dev/null
pass "wrote $(basename "$deb_path")"

# AppImage: the payload under usr/, AppRun, and the desktop entry and icon at
# the AppDir root where the runtime and desktop integration expect them.
appimage_path="$dist/Conduit-$version-x86_64.AppImage"
rm -f -- "$appimage_path"
if [ -n "$tools" ] && [ -x "$tools/appimagetool-x86_64.AppImage" ] && [ -f "$tools/runtime-x86_64" ]; then
  appdir="$work/Conduit.AppDir"
  mkdir -p "$appdir/usr"
  cp -a -- "$payload/." "$appdir/usr/"
  install -m 0755 -- "$repo_root/packaging/appimage/AppRun" "$appdir/AppRun"
  cp -- "$payload/share/applications/$app_id.desktop" "$appdir/$app_id.desktop"
  # The desktop entry's `Icon=$app_id` resolves to this top-level PNG inside an AppImage.
  cp -- "$payload/share/icons/hicolor/256x256/apps/$app_id.png" "$appdir/$app_id.png"
  ln -sf -- "$app_id.png" "$appdir/.DirIcon"
  # `--appimage-extract-and-run` lets the tool run on hosts without FUSE;
  # `--runtime-file` pins the runtime instead of downloading the latest one.
  ARCH=x86_64 "$tools/appimagetool-x86_64.AppImage" --appimage-extract-and-run \
    --no-appstream --runtime-file "$tools/runtime-x86_64" \
    "$appdir" "$appimage_path" > "$work/appimagetool.log" 2>&1 \
    || { cat "$work/appimagetool.log" >&2; fail "appimagetool failed"; }
  chmod 0755 "$appimage_path"
  pass "wrote $(basename "$appimage_path")"
elif [ "${RELEASE_ALLOW_MISSING_APPIMAGE:-0}" = "1" ]; then
  echo "SKIP: AppImage not built (no pinned appimagetool/runtime in '${tools:-<unset>}'; RELEASE_ALLOW_MISSING_APPIMAGE=1)"
else
  fail "AppImage tooling missing in '${tools:-<unset>}'; run release-fetch-appimagetool.sh first or set RELEASE_ALLOW_MISSING_APPIMAGE=1 for a local dry run"
fi

(
  cd "$dist"
  rm -f SHA256SUMS
  shopt -s nullglob
  files=(*.tar.gz *.deb *.AppImage)
  [ "${#files[@]}" -ge 2 ] || fail "nothing to checksum in $dist"
  sha256sum "${files[@]}" > SHA256SUMS
)
pass "wrote SHA256SUMS"
echo "INFO: artifacts in $dist:"
for artifact in "$dist"/*; do
  [ -f "$artifact" ] && printf 'INFO:   %10d  %s\n' "$(stat -c %s -- "$artifact")" "$(basename -- "$artifact")"
done
