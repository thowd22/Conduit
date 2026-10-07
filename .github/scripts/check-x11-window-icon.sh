#!/usr/bin/env bash
set -euo pipefail

# Proves the window carries Conduit's icon where X11 task switchers read it: SDL publishes the
# icon given to SDL_SetWindowIcon as the window's _NET_WM_ICON property (width, height, then
# ARGB pixels), which xprop reads back as an external X11 client.

artifact_root="${1:?usage: check-x11-window-icon.sh ARTIFACT_ROOT}"
mkdir -p "$artifact_root"

driver_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/conduit-window-icon.XXXXXX")"
chmod 700 "$driver_root"
run_id=""

driver() {
  ./zig-out/bin/conduit-test --root="$driver_root" --run="$run_id" "$@"
}

cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$run_id" ]]; then
    if (( status != 0 )); then
      driver inspect >"$artifact_root/failure-semantic-tree.json" 2>/dev/null || true
      driver logs 1048576 >"$artifact_root/failure-application.log" 2>/dev/null || true
      failure_screenshot="$(driver screenshot 2>/dev/null)" || failure_screenshot=""
      if [[ -n "$failure_screenshot" && -f "$failure_screenshot" ]]; then
        cp -- "$failure_screenshot" "$artifact_root/failure.png" || true
      fi
    fi
    driver quit >/dev/null 2>&1 || true
  fi
  if (( status != 0 )); then
    mkdir -p "$artifact_root/failure-driver-root"
    cp -a -- "$driver_root/." "$artifact_root/failure-driver-root/" 2>/dev/null || true
    # actions/upload-artifact rejects Unix sockets ("entry not supported"); the driver socket
    # carries no evidence.
    find "$artifact_root/failure-driver-root" -type s -delete 2>/dev/null || true
  fi
  rm -rf -- "$driver_root"
  exit "$status"
}
trap cleanup EXIT

export SDL_VIDEODRIVER=x11
run_id="$(./zig-out/bin/conduit-test --root="$driver_root" launch \
  --visible \
  --width=640 \
  --height=360 \
  --command='printf "ICON_READY\n"; while IFS= read -r line; do :; done')"

driver wait-for terminal-text ICON_READY 10000
window_id="$(timeout 15 xdotool search --sync --onlyvisible --limit 1 --name '^conduit$')"

# xprop draws _NET_WM_ICON as ASCII art by default; the explicit format prints the raw cardinals:
# width, height, then one non-premultiplied ARGB value per pixel. `$0+` is xprop's own syntax.
# shellcheck disable=SC2016
timeout 10 xprop -id "$window_id" -f _NET_WM_ICON 32c ' = $0+\n' _NET_WM_ICON \
  >"$artifact_root/net-wm-icon.txt"
if ! grep -Eq '^_NET_WM_ICON\(CARDINAL\) = 64, 64, ' "$artifact_root/net-wm-icon.txt"; then
  echo "window $window_id has no 64x64 _NET_WM_ICON:" >&2
  head -c 200 "$artifact_root/net-wm-icon.txt" >&2
  exit 1
fi
# The published pixels must be exactly the embedded fixture's, so the window shows Conduit's icon
# rather than merely some 64x64 image.
python3 - "$artifact_root/net-wm-icon.txt" assets/linux/io.github.thowd22.Conduit-64.rgba <<'PY'
import sys

text, fixture = sys.argv[1], sys.argv[2]
with open(text, encoding="ascii") as handle:
    values = [int(value) for value in handle.read().split("=", 1)[1].replace(",", " ").split()]
with open(fixture, "rb") as handle:
    rgba = handle.read()
expected = [64, 64] + [
    (rgba[i + 3] << 24) | (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2]
    for i in range(0, len(rgba), 4)
]
if values != expected:
    sys.exit(f"_NET_WM_ICON has {len(values)} cardinals that do not match the 64x64 fixture")
print("_NET_WM_ICON matches the embedded 64x64 fixture")
PY

driver inspect >"$artifact_root/semantic-tree.json"
driver logs 1048576 >"$artifact_root/application.log"
screenshot_path="$(driver screenshot)"
cp -- "$screenshot_path" "$artifact_root/final.png"
grep -Fq "window backend x11, high-pixel-density enabled" "$artifact_root/application.log"
if grep -Fq "window icon surface could not be created" "$artifact_root/application.log" \
  || grep -Fq "SDL_SetWindowIcon failed" "$artifact_root/application.log"; then
  echo "the application log reports a window icon failure" >&2
  exit 1
fi

driver quit
run_id=""
