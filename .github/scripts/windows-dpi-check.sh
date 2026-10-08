#!/usr/bin/env bash
# TASK-49 AC3: a per-monitor DPI change reaches a running Conduit window.
#
# Usage: windows-dpi-check.sh <conduit.exe> <artifact-dir>
#
#   1. The process is per-monitor DPI aware: the app logs the awareness the
#      embedded manifest and SDL left it with, and the window's own DPI.
#   2. A visible 640x360 window is started directly (not through conduit-test,
#      which always fixes the scale) while the display is at 100%, so its scale
#      follows the display.
#   3. The display's scaling is changed the way Settings does
#      (windows-set-dpi.ps1), which sends the window a real WM_DPICHANGED.
#   4. Conduit must log the scale change ("event display scale changed: 1.00
#      -> <new>"), and the frame it writes on exit must have the new density
#      (800x450 at 125%). The display is put back afterwards.
set -uo pipefail
export MSYS_NO_PATHCONV=1

conduit="${1:?usage: windows-dpi-check.sh <conduit.exe> <artifact-dir>}"
out="${2:?usage}"
mkdir -p "$out"
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=windows-common.sh
. "$here/windows-common.sh"
setdpi() { powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$here/windows-set-dpi.ps1")" "$@" | tr -d '\r'; }
log="$out/app.log"

before="$(setdpi -Query)" || { echo "FAIL the display's DPI could not be queried" >&2; exit 1; }
echo "INFO display: $before"
case "$before" in
  "dpi 100%"*) ;;
  *) setdpi -Percent 100 > /dev/null || true ;;
esac
# The largest step this display allows, up to 150%.
target=""
for step in 150 125; do
  if [[ "$before" =~ range\ ([0-9]+)%\.\.([0-9]+)% ]] && [ "${BASH_REMATCH[2]}" -ge "$step" ]; then
    target="$step"
    break
  fi
done
[ -n "$target" ] || { echo "FAIL this display allows no scale above 100% ($before)" >&2; exit 1; }
factor="$(python -c "print('%.2f' % ($target / 100))")"

# 20 s of life is ample: the change is made as soon as the window exists.
"$conduit" --no-child --width=640 --height=360 --run-ms=20000 \
  --log-file="$(cygpath -w "$log")" --screenshot="$(cygpath -w "$out/after.png")" > "$out/stdout.txt" 2>&1 &
app=$!
trap 'setdpi -Percent 100 > /dev/null 2>&1 || true' EXIT
for _ in $(seq 1 100); do
  grep -q "window conduit:" "$log" 2>/dev/null && break
  python -c 'import time; time.sleep(0.1)'
done
grep -E "windows dpi awareness|window conduit" "$log" | sed 's/^/INFO /'
if grep -q "windows dpi awareness per-monitor" "$log"; then
  echo "PASS the process is per-monitor DPI aware"
else
  echo "FAIL the process is not per-monitor DPI aware" >&2
  exit 1
fi
grep -q "scale 1.00" "$log" || { echo "FAIL the window did not start at scale 1.00" >&2; exit 1; }

after="$(setdpi -Percent "$target")" || { echo "FAIL the display could not be set to $target%" >&2; exit 1; }
echo "INFO display: $after"
changed=""
for _ in $(seq 1 50); do
  changed="$(grep -E "event display scale changed: [0-9.]+ -> $factor" "$log" | tail -n 1 || true)"
  [ -n "$changed" ] && break
  python -c 'import time; time.sleep(0.2)'
done
wait "$app"
status=$?
if [ -z "$changed" ]; then
  echo "FAIL Conduit never logged a scale change to $factor" >&2
  grep -E "scale|dpi|resized|geometry" "$log" | tail -n 20 >&2
  exit 1
fi
echo "PASS ${changed#*: }"
[ "$status" -eq 0 ] || { echo "FAIL conduit exited $status" >&2; tail -n 20 "$log" >&2; exit 1; }
size="$(png_size "$out/after.png")"
expected="$(python -c "print('%dx%d' % (round(640 * $target / 100), round(360 * $target / 100)))")"
if [ "$size" = "$expected" ]; then
  echo "PASS the frame drawn after the change is $size at $target% ($out/after.png)"
else
  echo "FAIL the frame after the change is $size, expected $expected" >&2
  exit 1
fi
