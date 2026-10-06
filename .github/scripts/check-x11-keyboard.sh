#!/usr/bin/env bash
set -euo pipefail

# Real X11 keystrokes: one physical printable key produces both an SDL key
# event and an SDL text-input echo. Every built-in check posts only one of the
# two, so this is the check that proves each keystroke reaches the child once.

artifact_root="${1:?usage: check-x11-keyboard.sh ARTIFACT_ROOT}"
mkdir -p "$artifact_root"

driver_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/conduit-keyboard.XXXXXX")"
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
      driver terminal-text >"$artifact_root/failure-terminal.txt" 2>/dev/null || true
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

# Each line the child reads is reported twice, numbered so every wait has its
# own marker: as text, and as hex so an escape prefix is visible exactly.
export SDL_VIDEODRIVER=x11
run_id="$(./zig-out/bin/conduit-test --root="$driver_root" launch \
  --visible \
  --width=640 \
  --height=360 \
  --command='printf "KEYS_READY\n"; n=0; while IFS= read -r line; do n=$((n+1)); printf "KEYS_GOT%d:%s\n" "$n" "$line"; printf "KEYS_HEX%d:%s\n" "$n" "$(printf %s "$line" | od -An -tx1 | tr -d " \n")"; done')"

driver wait-for terminal-text KEYS_READY 10000
window_id="$(timeout 15 xdotool search --sync --onlyvisible --limit 1 --name '^conduit$')"
timeout 10 xdotool windowfocus --sync "$window_id"
xdotool mousemove --window "$window_id" 320 180 click 1

# Lower and upper case (shift) letters plus a space, typed as real key events
# by a separate X11 client.
xdotool type --clearmodifiers --delay 20 'Hello World'
xdotool key --clearmodifiers Return
driver wait-for terminal-text KEYS_HEX1: 5000

# Alt+x is encoded by the key path as ESC x; SDL may also echo plain "x".
xdotool key --clearmodifiers alt+x
xdotool key --clearmodifiers Return
driver wait-for terminal-text KEYS_HEX2: 5000

# A focused UI Input receives the same key and text-echo pair. Type a needle
# that appears exactly once in the terminal, with Shift-produced capitals and
# punctuation, into the search Input: a doubled character can never match, so
# the status settles on 1/1 only when every key was inserted once.
xdotool key --clearmodifiers ctrl+shift+f
driver wait-for element search.query focused true 5000
xdotool type --clearmodifiers --delay 20 'KEYS_GOT1:Hello'
search_status=""
for _ in $(seq 1 200); do
  search_status="$(driver --json inspect | jq -r '[.. | objects | select(.id? == "search.status") | .label][0] // ""')"
  [[ "$search_status" == "1/1" ]] && break
done
printf '%s\n' "$search_status" >"$artifact_root/search-status.txt"
if [[ "$search_status" != "1/1" ]]; then
  printf 'keyboard: search Input status is %s, not 1/1\n' "$search_status" >&2
  exit 1
fi

driver terminal-text >"$artifact_root/terminal.txt"
driver inspect >"$artifact_root/semantic-tree.json"
driver logs 1048576 >"$artifact_root/application.log"
screenshot_path="$(driver screenshot)"
cp -- "$screenshot_path" "$artifact_root/final.png"
grep -Fq "window backend x11, high-pixel-density enabled" "$artifact_root/application.log"

terminal="$artifact_root/terminal.txt"
if grep -Fq "HHeelllloo" "$terminal"; then
  printf 'keyboard: printable keys reached the child twice\n' >&2
  exit 1
fi
[[ "$(grep -Ec '^KEYS_GOT1:Hello World *$' "$terminal")" == 1 ]]
grep -Eq '^KEYS_HEX1:48656c6c6f20576f726c64 *$' "$terminal"
grep -Eq '^KEYS_HEX2:1b78 *$' "$terminal"

driver quit
run_id=""
