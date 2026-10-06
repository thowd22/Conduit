#!/usr/bin/env bash
set -euo pipefail

artifact_root="${1:?usage: check-x11-primary.sh ARTIFACT_ROOT}"
mkdir -p "$artifact_root"

driver_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/conduit-primary.XXXXXX")"
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
  --command='printf "PRIMARY_READY\n"; IFS= read -r line; printf "PRIMARY_ASSERT:%s\n" "$line"; while IFS= read -r line; do :; done')"

driver wait-for terminal-text PRIMARY_READY 10000
window_id="$(timeout 15 xdotool search --sync --onlyvisible --limit 1 --name '^conduit$')"
timeout 10 xdotool windowfocus --sync "$window_id"

# xclip is a separate X11 client, so this proves interoperability with the
# server's PRIMARY selection rather than SDL reading back its own write.
printf '%s' 'conduit-primary-external' | xclip -selection primary -in
xdotool mousemove --window "$window_id" 320 180 click 2
driver wait-for terminal-text conduit-primary-external 5000
driver key ENTER
driver wait-for terminal-text PRIMARY_ASSERT:conduit-primary-external 5000

driver terminal-text >"$artifact_root/terminal.txt"
driver inspect >"$artifact_root/semantic-tree.json"
driver logs 1048576 >"$artifact_root/application.log"
screenshot_path="$(driver screenshot)"
cp -- "$screenshot_path" "$artifact_root/final.png"
grep -Fq "window backend x11, high-pixel-density enabled" "$artifact_root/application.log"
grep -Fq "PRIMARY_ASSERT:conduit-primary-external" "$artifact_root/terminal.txt"

driver quit
run_id=""
