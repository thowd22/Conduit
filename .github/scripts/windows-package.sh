#!/usr/bin/env bash
# TASK-69: zip the portable Windows folder and verify the zip.
#
# Usage: windows-package.sh <portable-dir> <version> <out-dir>
#
# <portable-dir> is what `zig build portable` staged (zig-out/Conduit). The zip
# holds that folder as `Conduit/`, so unpacking it anywhere gives one
# self-contained directory. Writes conduit-<version>-windows-x86_64.zip and its
# .sha256 (sha256sum format) into <out-dir>, then verifies the zip as a user
# would get it: the checksum, a fresh unpack, the payload, the embedded
# manifest, and `conduit.exe --version` and `conduit-test.exe` from the unpacked
# copy.
set -euo pipefail
export MSYS_NO_PATHCONV=1

portable="${1:?usage: windows-package.sh <portable-dir> <version> <out-dir>}"
version="${2:?usage}"
out="${3:?usage}"
mkdir -p "$out"
name="conduit-$version-windows-x86_64.zip"
zip_path="$out/$name"
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }

[ -f "$portable/conduit.exe" ] || fail "no conduit.exe in $portable"
rm -f "$zip_path"
parent="$(cd "$portable/.." && pwd)"
base="$(basename "$portable")"
[ "$base" = Conduit ] || fail "the portable folder must be named Conduit, not $base"
# 7-Zip rather than Compress-Archive: Windows PowerShell 5.1's writes entry
# names with backslashes, which unzip elsewhere turns into odd file names.
(cd "$parent" && 7z a -tzip -mx=9 "$(cygpath -w "$zip_path")" "$base" > /dev/null)
(cd "$out" && sha256sum "$name" > "$name.sha256")
pass "wrote $name ($(stat -c %s "$zip_path") bytes) and $name.sha256"
if unzip -Z1 "$zip_path" | grep -q '\\'; then fail "the zip has entry names with backslashes"; fi
unzip -Z1 "$zip_path" | grep -qx 'Conduit/conduit.exe' || fail "the zip has no Conduit/conduit.exe entry"
pass "every entry is under Conduit/ with forward slashes"

# Verify.
(cd "$out" && sha256sum -c "$name.sha256") || fail "the checksum does not match"
check="$(mktemp -d "${RUNNER_TEMP:-/tmp}/cverify.XXXXXX")"
powershell.exe -NoProfile -Command "Expand-Archive -Path '$(cygpath -w "$zip_path")' -DestinationPath '$(cygpath -w "$check")'"
unpacked="$check/Conduit"
for file in \
  conduit.exe conduit-test.exe \
  share/conduit/fonts/JetBrainsMono-Regular.ttf share/conduit/fonts/SymbolsNerdFontMono-Regular.ttf \
  share/conduit/shell-integration/bash/conduit.bash share/conduit/shell-integration/zsh/conduit.zsh \
  share/conduit/shell-integration/zsh/.zshenv share/conduit/shell-integration/zsh/.zprofile \
  share/conduit/shell-integration/zsh/.zshrc share/conduit/shell-integration/zsh/.zlogin \
  share/conduit/shell-integration/fish/vendor_conf.d/conduit.fish \
  share/conduit/themes/README.md \
  share/conduit/licenses/LICENSE share/conduit/licenses/Ghostty-LICENSE share/conduit/licenses/SDL-LICENSE.txt \
  share/conduit/licenses/JetBrainsMono-OFL-1.1.txt share/conduit/licenses/NerdFonts-LICENSE.txt \
  share/conduit/licenses/FreeType-LICENSE.TXT share/conduit/licenses/HarfBuzz-COPYING.txt \
  share/conduit/licenses/Oniguruma-COPYING.txt share/conduit/licenses/zlib-LICENSE.txt \
  share/conduit/licenses/libpng-LICENSE.txt share/conduit/licenses/zopengl-LICENSE; do
  [ -s "$unpacked/$file" ] || fail "the zip has no $file"
done
pass "every shipped file is in the zip under Conduit/"
if find "$unpacked" -name '*.pdb' | grep -q .; then fail "the zip ships debug databases"; fi
grep -aq "PerMonitorV2" "$unpacked/conduit.exe" || fail "conduit.exe has no embedded DPI-aware manifest"
pass "conduit.exe embeds its application manifest (per-monitor v2, UTF-8)"
reported="$("$unpacked/conduit.exe" --version | tr -d '\r')"
[ "$reported" = "conduit $version" ] || fail "the unpacked conduit.exe printed '$reported'"
pass "the unpacked conduit.exe prints '$reported'"
usage="$("$unpacked/conduit-test.exe" --help 2>&1 | tr -d '\r' | head -n 1 || true)"
case "$usage" in
  *conduit-test*) pass "the unpacked conduit-test.exe runs ('$usage')" ;;
  *) fail "the unpacked conduit-test.exe printed '$usage'" ;;
esac
file "$unpacked/conduit.exe" | grep -q "PE32+ executable" || fail "conduit.exe is not a 64-bit PE image"
file "$unpacked/conduit.exe"
