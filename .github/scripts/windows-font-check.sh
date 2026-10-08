#!/usr/bin/env bash
# TASK-49 AC2: configured families installed for the system and for one user
# on Windows are discovered and loaded.
#
# Usage: windows-font-check.sh <conduit.exe> <artifact-dir> [<per-user-font-file>]
#
#   system    Consolas (and Cascadia Mono when the image has it) ship in
#             %WINDIR%\Fonts.
#   per-user  When a font file is given, it is installed the way Settings >
#             Fonts installs one for a single user: copied into
#             %LOCALAPPDATA%\Microsoft\Windows\Fonts and registered under
#             HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts with its
#             absolute path. Its family must then load too.
#
# Each family is run with `--font=<family>` against the real environment, so
# discovery is the app's own, and the log line the app writes once the face is
# the one drawing ("drawing with <family>,") is required. The discovery line
# (which source listed the fonts) is printed. A family installed nowhere is run
# last as a negative control and must fall back to the bundled face.
set -euo pipefail
export MSYS_NO_PATHCONV=1

conduit="${1:?usage: windows-font-check.sh <conduit.exe> <artifact-dir> [<font-file>]}"
out="${2:?usage}"
user_font="${3:-}"
mkdir -p "$out"

run_family() {
  local family="$1" tag="$2"
  local log="$out/$tag.log"
  rm -f "$log"
  timeout -k 5 120 "$conduit" --hidden --run-ms=3000 --command="printf 'family: $family  0O 1lI {}[] => != \\n'; sleep 5" --width=640 --height=200 --scale=1.5 \
    --font="$family" --screenshot="$(cygpath -w "$out/$tag.png")" --log-file="$(cygpath -w "$log")" \
    > /dev/null 2>&1 || true
}

check_family() {
  local family="$1"
  local tag
  tag="$(printf '%s' "$family" | tr -c 'A-Za-z0-9' '-')"
  run_family "$family" "$tag"
  grep -hE "font discovery|font files" "$out/$tag.log" | head -n 3 | sed 's/^/INFO /' || true
  local line
  line="$(grep -E "drawing with $family," "$out/$tag.log" | tail -n 1 || true)"
  if [ -n "$line" ]; then
    echo "PASS $family: ${line#*: }"
  else
    echo "FAIL $family was not loaded; the log says:" >&2
    grep -E "font|drawing with" "$out/$tag.log" | tail -n 20 >&2 || true
    exit 1
  fi
}

windir="$(cygpath -u "${WINDIR:-C:\\Windows}")"
ls "$windir/Fonts" | grep -iE "^(consola|cascadia)" | sed 's/^/INFO system font file: /' || true
check_family "Consolas"
if ls "$windir/Fonts" | grep -qi "^CascadiaMono"; then
  check_family "Cascadia Mono"
else
  echo "INFO Cascadia Mono is not installed on this image"
fi

if [ -n "$user_font" ]; then
  user_dir="$(cygpath -u "$LOCALAPPDATA")/Microsoft/Windows/Fonts"
  mkdir -p "$user_dir"
  base="$(basename "$user_font")"
  cp "$user_font" "$user_dir/$base"
  user_path="$(cygpath -w "$user_dir/$base")"
  family="$(python -c '
import struct, sys
data = open(sys.argv[1], "rb").read()
count = struct.unpack(">H", data[4:6])[0]
for i in range(count):
    tag, _, off, _ = struct.unpack(">4sIII", data[12 + 16 * i: 28 + 16 * i])
    if tag == b"name":
        _, n, strings = struct.unpack(">HHH", data[off:off + 6])
        for j in range(n):
            pid, eid, lid, nid, length, o = struct.unpack(">HHHHHH", data[off + 6 + 12 * j: off + 18 + 12 * j])
            if nid == 1 and pid == 3:
                print(data[off + strings + o: off + strings + o + length].decode("utf-16-be"))
                sys.exit(0)
' "$user_font")"
  powershell.exe -NoProfile -Command "New-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts' -Name '$family (TrueType)' -Value '$user_path' -PropertyType String -Force | Out-Null"
  echo "INFO per-user font: '$family' at $user_path, registered under HKCU"
  if ls "$windir/Fonts" | grep -qi "^$(printf '%s' "$base" | cut -c1-6)"; then
    echo "FAIL the per-user fixture $base is also a system font, so it proves nothing" >&2
    exit 1
  fi
  check_family "$family"
fi

control="Conduit Missing Family"
run_family "$control" control
if grep -qE "drawing with $control," "$out/control.log"; then
  echo "FAIL the negative control claims to draw with '$control'" >&2
  exit 1
fi
echo "PASS negative control: '$control' fell back ($(grep -E 'drawing with' "$out/control.log" | tail -n 1 | sed 's/.*drawing with/drawing with/'))"
