#!/usr/bin/env bash
# Verify the Linux release artifacts: checksums, stamped version, architecture,
# glibc baseline, runtime dependencies and an isolated extract or install of
# each package.
#
# Usage: release-verify.sh <version> <dist-dir> [work-dir]
#
#   version   the SemVer version the tag carries, without a leading `v`
#   dist-dir  directory holding the tar.gz, .deb, .AppImage and SHA256SUMS
#   work-dir  scratch directory (default: <dist-dir>/.verify-work); removed on exit
#
# Environment: GLIBC_BASELINE (default 2.35) is the highest GLIBC_x.y symbol
# version the binary may require. RELEASE_ALLOW_MISSING_APPIMAGE=1 turns a
# missing AppImage into SKIP for local dry runs; CI never sets it.
#
# Every check prints PASS or FAIL and the script keeps going so one run shows
# every problem; it exits non-zero if anything failed. Binaries run with an
# isolated HOME and XDG directories under work-dir, so nothing of the real
# user's configuration or state is read or written.
set -euo pipefail

version="${1:?usage: release-verify.sh <version> <dist-dir> [work-dir]}"
dist="$(cd -- "${2:?usage: release-verify.sh <version> <dist-dir> [work-dir]}" && pwd)"
work="${3:-$dist/.verify-work}"
glibc_baseline="${GLIBC_BASELINE:-2.35}"
app_id="io.github.thowd22.Conduit"
expected_version_line="conduit $version"
deb_version="${version/-/\~}"

tar_path="$dist/conduit-$version-x86_64-linux.tar.gz"
deb_path="$dist/conduit_${version}_amd64.deb"
appimage_path="$dist/Conduit-$version-x86_64.AppImage"

failures=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
skip() { echo "SKIP: $*"; }
# check_that <pass message> <fail message> <command...>: report one check.
check_that() {
  local ok="$1" bad="$2"
  shift 2
  if "$@"; then pass "$ok"; else fail "$bad"; fi
}

rm -rf -- "$work"
mkdir -p "$work"
trap 'rm -rf -- "$work"' EXIT

# Isolation for every binary this script runs.
export HOME="$work/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share"
export TMPDIR="$work/tmp"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$TMPDIR"
unset DISPLAY WAYLAND_DISPLAY

payload_files=(
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
  share/licenses/conduit/zlib-LICENSE.txt
  share/licenses/conduit/libpng-LICENSE.txt
  share/licenses/conduit/NerdFonts-LICENSE.txt
  share/licenses/conduit/NerdFonts-license-audit.md
)
# The application icon at every freedesktop hicolor size build.zig installs.
icon_sizes=(16 22 24 32 48 64 128 256 512)
for size in "${icon_sizes[@]}"; do
  payload_files+=("share/icons/hicolor/${size}x${size}/apps/$app_id.png")
done

# Compare two dotted versions numerically; true when $1 <= $2.
version_le() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# Run `<binary> --version` with a timeout and compare the exact output.
check_version_output() {
  local label="$1" exe="$2" out status
  set +e
  out="$(timeout 20 "$exe" --version 2>&1)"
  status=$?
  set -e
  if [ "$status" -eq 0 ] && [ "$out" = "$expected_version_line" ]; then
    pass "$label: --version printed '$expected_version_line'"
  else
    fail "$label: --version exited $status and printed '$(printf '%s' "$out" | head -c 200 | tr '\n' ' ')', expected exactly '$expected_version_line'"
  fi
}

# Check the payload tree beneath $2 has every file, and the binary inside it.
check_payload_tree() {
  local label="$1" root="$2" rel missing=0
  for rel in "${payload_files[@]}"; do
    [ -f "$root/$rel" ] || { fail "$label: missing $rel"; missing=1; }
  done
  [ "$missing" -eq 0 ] && pass "$label: binary, fallback font, shell integration, desktop entry, icon and all license notices present"
  [ -f "$root/bin/conduit-test" ] && fail "$label: ships the development-only conduit-test binary"
  return 0
}

check_binary() {
  local label="$1" exe="$2" desc machine needed max_glibc soname
  [ -x "$exe" ] || { fail "$label: $exe is not executable"; return 0; }
  desc="$(file -b -- "$exe")"
  case "$desc" in
    *"ELF 64-bit"*"x86-64"*) pass "$label: file reports x86-64 ELF 64-bit" ;;
    *) fail "$label: file reports '$desc', expected an x86-64 ELF 64-bit executable" ;;
  esac
  machine="$(readelf -h -- "$exe" | sed -nE 's/^[[:space:]]*Machine:[[:space:]]+(.*)$/\1/p')"
  if [ "$machine" = "Advanced Micro Devices X86-64" ]; then
    pass "$label: readelf machine is $machine"
  else
    fail "$label: readelf machine is '$machine'"
  fi
  mapfile -t needed < <(readelf -d -- "$exe" | sed -nE 's/.*\(NEEDED\).*\[([^]]+)\].*/\1/p')
  for soname in "${needed[@]}"; do
    case "$soname" in
      libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|librt.so.1|ld-linux-x86-64.so.2) ;;
      *) fail "$label: unexpected linked library $soname (only glibc components are allowed; everything else is vendored or dlopened)" ;;
    esac
  done
  pass "$label: NEEDED = ${needed[*]}"
  max_glibc="$(objdump -T -- "$exe" | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sed 's/GLIBC_//' | sort -V | tail -n1)"
  if [ -z "$max_glibc" ]; then
    fail "$label: no GLIBC_ symbol versions found; is the binary dynamically linked against glibc?"
  elif version_le "$max_glibc" "$glibc_baseline"; then
    pass "$label: highest glibc symbol version GLIBC_$max_glibc <= baseline $glibc_baseline"
  else
    fail "$label: requires GLIBC_$max_glibc, above the $glibc_baseline baseline"
  fi
  if grep -qaF 'libGL.so.1' -- "$exe"; then
    pass "$label: binary references libGL.so.1 for runtime dlopen (OpenGL dependency is real)"
  else
    fail "$label: binary does not reference libGL.so.1; the Debian Depends on libgl1 would be unjustified"
  fi
}

echo "== Conduit $version release verification (glibc baseline $glibc_baseline) =="

# --- checksums ---------------------------------------------------------------
if [ -f "$dist/SHA256SUMS" ]; then
  if (cd "$dist" && sha256sum -c --strict --quiet SHA256SUMS); then
    pass "SHA256SUMS verifies every listed artifact"
  else
    fail "SHA256SUMS does not verify"
  fi
  for artifact in "$tar_path" "$deb_path"; do
    grep -qF -- " $(basename "$artifact")" "$dist/SHA256SUMS" || fail "SHA256SUMS lacks $(basename "$artifact")"
  done
  if [ -f "$appimage_path" ]; then
    grep -qF -- " $(basename "$appimage_path")" "$dist/SHA256SUMS" || fail "SHA256SUMS lacks $(basename "$appimage_path")"
  fi
else
  fail "SHA256SUMS missing from $dist"
fi

# --- tar.gz ------------------------------------------------------------------
if [ -f "$tar_path" ]; then
  tar_work="$work/tar"
  mkdir -p "$tar_work"
  if tar -xzf "$tar_path" -C "$tar_work"; then
    top="$tar_work/conduit-$version-x86_64-linux"
    if [ -d "$top" ] && [ "$(find "$tar_work" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]; then
      pass "tar.gz: single top-level directory conduit-$version-x86_64-linux"
    else
      fail "tar.gz: expected exactly one top-level directory conduit-$version-x86_64-linux"
    fi
    check_payload_tree "tar.gz" "$top"
    check_binary "tar.gz" "$top/bin/conduit"
    check_version_output "tar.gz" "$top/bin/conduit"
  else
    fail "tar.gz: extraction failed"
  fi
else
  fail "tar.gz missing: $tar_path"
fi

# --- Debian package ----------------------------------------------------------
if [ -f "$deb_path" ]; then
  info="$(dpkg-deb --info "$deb_path")"
  field() { printf '%s\n' "$info" | sed -nE "s/^ $1: (.*)$/\1/p"; }
  check_that "deb: Package is conduit" "deb: Package is '$(field Package)'" [ "$(field Package)" = "conduit" ]
  check_that "deb: Architecture is amd64" "deb: Architecture is '$(field Architecture)'" [ "$(field Architecture)" = "amd64" ]
  check_that "deb: Version is $deb_version (Debian form of $version)" "deb: Version is '$(field Version)', expected $deb_version" [ "$(field Version)" = "$deb_version" ]
  depends="$(field Depends)"
  if printf '%s' "$depends" | grep -qF "libc6 (>= $glibc_baseline)"; then
    pass "deb: Depends pins libc6 (>= $glibc_baseline): $depends"
  else
    fail "deb: Depends '$depends' does not pin libc6 (>= $glibc_baseline)"
  fi
  if printf '%s' "$depends" | grep -qF "libgl1"; then
    pass "deb: Depends requires libgl1 for OpenGL"
  else
    fail "deb: Depends lacks libgl1"
  fi
  contents="$(dpkg-deb --contents "$deb_path")"
  missing=0
  for rel in "${payload_files[@]}"; do
    printf '%s\n' "$contents" | grep -qF -- " ./usr/$rel" || { fail "deb: contents lack usr/$rel"; missing=1; }
  done
  printf '%s\n' "$contents" | grep -qF -- " ./usr/share/doc/conduit/copyright" || { fail "deb: contents lack usr/share/doc/conduit/copyright"; missing=1; }
  [ "$missing" -eq 0 ] && pass "deb: contents list the full payload and the Debian copyright file"
  deb_work="$work/deb"
  mkdir -p "$deb_work"
  if dpkg-deb -x "$deb_path" "$deb_work"; then
    pass "deb: dpkg-deb -x extracted the package"
    check_payload_tree "deb" "$deb_work/usr"
    check_binary "deb" "$deb_work/usr/bin/conduit"
    check_version_output "deb (extracted)" "$deb_work/usr/bin/conduit"
  else
    fail "deb: dpkg-deb -x failed"
  fi
  if command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1; then
    # Install into a pristine image of the baseline distribution, read-only
    # mount of the artifact, no network needed beyond apt itself.
    docker_log="$work/docker-install.log"
    set +e
    docker run --rm --pull=missing \
      -v "$deb_path:/pkg/$(basename "$deb_path"):ro" \
      -e DEBIAN_FRONTEND=noninteractive \
      ubuntu:22.04 bash -euo pipefail -c '
        apt-get update -qq > /dev/null
        apt-get install -y -qq --no-install-recommends "/pkg/'"$(basename "$deb_path")"'" > /dev/null
        dpkg-query -W -f="installed \${Package} \${Version} \${Architecture}\n" conduit
        ldd /usr/bin/conduit
        test -f /usr/share/applications/'"$app_id"'.desktop
        test -f /usr/share/licenses/conduit/LICENSE
        printf "version-output:"
        conduit --version
      ' > "$docker_log" 2>&1
    status=$?
    set -e
    if [ "$status" -eq 0 ] && grep -qxF "version-output:$expected_version_line" "$docker_log"; then
      pass "deb: installed with apt in ubuntu:22.04 (glibc $glibc_baseline) and 'conduit --version' printed '$expected_version_line'"
    else
      fail "deb: isolated ubuntu:22.04 install/run failed (exit $status); last lines of the log follow"
      tail -n 12 "$docker_log" | sed 's/^/    | /'
    fi
  else
    skip "deb: docker is unavailable, so the isolated ubuntu:22.04 install was not run (dpkg-deb -x extraction covered above)"
  fi
else
  fail "deb missing: $deb_path"
fi

# --- AppImage ----------------------------------------------------------------
if [ -f "$appimage_path" ]; then
  [ -x "$appimage_path" ] || fail "AppImage: not executable"
  if head -c 4 "$appimage_path" | od -An -c | grep -q 'E   L   F'; then
    pass "AppImage: starts with an ELF runtime"
  else
    fail "AppImage: does not start with an ELF runtime"
  fi
  if [ "$(dd if="$appimage_path" bs=1 skip=8 count=3 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "414902" ]; then
    pass "AppImage: carries the type 2 AppImage magic"
  else
    fail "AppImage: type 2 magic bytes missing at offset 8"
  fi
  ai_work="$work/appimage"
  mkdir -p "$ai_work"
  if (cd "$ai_work" && "$appimage_path" --appimage-extract > /dev/null 2>&1); then
    pass "AppImage: --appimage-extract succeeded without FUSE"
    root="$ai_work/squashfs-root"
    check_that "AppImage: AppRun present" "AppImage: AppRun missing" [ -x "$root/AppRun" ]
    check_that "AppImage: desktop entry at AppDir root" "AppImage: desktop entry missing at AppDir root" [ -f "$root/$app_id.desktop" ]
    if [ -f "$root/$app_id.png" ] && [ -f "$root/.DirIcon" ] \
      && [ "$(head -c 8 "$root/.DirIcon" | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ]; then
      pass "AppImage: PNG icon and .DirIcon present"
    else
      fail "AppImage: PNG icon or .DirIcon missing"
    fi
    check_that "AppImage: desktop entry names the icon" "AppImage: desktop entry Icon= does not name $app_id" \
      grep -qx "Icon=$app_id" "$root/$app_id.desktop"
    check_payload_tree "AppImage" "$root/usr"
    check_binary "AppImage" "$root/usr/bin/conduit"
    check_version_output "AppImage (AppRun)" "$root/AppRun"
  else
    fail "AppImage: --appimage-extract failed"
  fi
  if "$appimage_path" --appimage-version > "$work/appimage-version.txt" 2>&1; then
    echo "INFO: AppImage runtime reports: $(tr '\n' ' ' < "$work/appimage-version.txt")"
  else
    echo "INFO: AppImage runtime does not support --appimage-version; skipped"
  fi
elif [ "${RELEASE_ALLOW_MISSING_APPIMAGE:-0}" = "1" ]; then
  skip "AppImage: $(basename "$appimage_path") not present (RELEASE_ALLOW_MISSING_APPIMAGE=1)"
else
  fail "AppImage missing: $appimage_path"
fi

echo "== summary: $failures failure(s) =="
[ "$failures" -eq 0 ]
