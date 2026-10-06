#!/usr/bin/env bash
set -euo pipefail

artifact_root="${1:?usage: check-ibus-hangul.sh ARTIFACT_ROOT}"
mkdir -p "$artifact_root"

driver_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/conduit-ibus.XXXXXX")"
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
      for name in manifest.json stdout.txt stderr.txt; do
        if [[ -f "$driver_root/$run_id/$name" ]]; then
          cp -- "$driver_root/$run_id/$name" "$artifact_root/failure-$name" || true
        fi
      done
    fi
    driver quit >/dev/null 2>&1 || true
  fi
  ibus exit >/dev/null 2>&1 || true
  if (( status != 0 )); then
    mkdir -p "$artifact_root/failure-driver-root"
    cp -a -- "$driver_root/." "$artifact_root/failure-driver-root/" 2>/dev/null || true
  fi
  rm -rf -- "$driver_root"
  exit "$status"
}
trap cleanup EXIT

export GTK_IM_MODULE=ibus
export QT_IM_MODULE=ibus
export XMODIFIERS=@im=ibus
export SDL_IM_MODULE=ibus
export SDL_VIDEODRIVER=x11
export LANG=C.UTF-8

ibus-daemon --daemonize --replace --xim --panel disable \
  >"$artifact_root/ibus-daemon.stdout" \
  2>"$artifact_root/ibus-daemon.stderr"

# Readiness is a successful D-Bus query that sees the packaged Hangul engine, not a fixed delay.
deadline=$((SECONDS + 20))
until ibus list-engine >"$artifact_root/engines.txt" 2>"$artifact_root/ibus-query.err" && \
    grep -Eq '(^|[^[:alnum:]_-])hangul([^[:alnum:]_-]|$)' "$artifact_root/engines.txt"; do
  if (( SECONDS >= deadline )); then
    echo "IBus did not publish the Hangul engine within 20 seconds" >&2
    exit 1
  fi
  sleep 0.05
done

# Make the selected engine deterministic across contexts before the SDL input context is created.
gsettings set org.freedesktop.ibus.general use-global-engine true
ibus engine hangul

run_id="$(./zig-out/bin/conduit-test --root="$driver_root" launch \
  --visible \
  --width=640 \
  --height=360 \
  --command='printf "IBUS_READY\n"; IFS= read -r line; if [ "$line" = "한글" ]; then printf "IBUS_ASSERT:exact\n"; else printf "IBUS_ASSERT:wrong:%s\n" "$line"; fi; printf "IBUS_SECOND_READY\n"; IFS= read -r line; if [ "$line" = "sentinel" ]; then printf "IBUS_SECOND:exact\n"; else printf "IBUS_SECOND:wrong:%s\n" "$line"; fi; while IFS= read -r line; do :; done')"

driver wait-for terminal-text IBUS_READY 10000

# A bare Xvfb has no window manager, so set X focus directly and click the real SDL client area.
window_id="$(timeout 15 xdotool search --sync --onlyvisible --limit 1 --name '^conduit$')"
timeout 10 xdotool windowfocus --sync "$window_id"
xdotool mousemove --window "$window_id" 320 180 click 1
ibus engine hangul
if [[ "$(ibus engine)" != "hangul" ]]; then
  echo "IBus did not retain the Hangul engine for the focused Conduit context" >&2
  exit 1
fi

# XTest key events enter SDL's X11 event queue. IBus turns the Dubeolsik sequence into one UTF-8
# commit; the PTY fixture rejects raw ASCII, duplicate commits and any other line.
xdotool type --clearmodifiers gksrmf
driver wait-for element ime.preedit exists true 5000
driver inspect >"$artifact_root/preedit-semantic-tree.json"
jq -e '.elements | any(.id == "ime.preedit" and .role == "preedit" and (.label | length > 0))' \
  "$artifact_root/preedit-semantic-tree.json" >/dev/null
preedit_screenshot="$(driver screenshot)"
cp -- "$preedit_screenshot" "$artifact_root/preedit.png"
xdotool key --clearmodifiers Return

# Some IBus versions consume the first Return only to commit the active preedit. If the validated
# child line is not ready yet, wait until that commit is visible, then submit it through Conduit's
# real driver/SDL key path. Both branches are bounded by observable app state.
if ! driver wait-for terminal-text IBUS_ASSERT:exact 1500; then
  driver wait-for terminal-text 한글 5000
  driver key ENTER
fi
driver wait-for terminal-text IBUS_ASSERT:exact 5000

# A second exact line makes delayed or duplicate commits observable: any
# leftover Hangul bytes corrupt this sentinel instead of disappearing into a
# drain loop after the first success marker.
driver wait-for terminal-text IBUS_SECOND_READY 5000
driver type sentinel
driver key ENTER
driver wait-for terminal-text IBUS_SECOND:exact 5000

driver inspect >"$artifact_root/semantic-tree.json"
driver terminal-text >"$artifact_root/terminal.txt"
driver logs 1048576 >"$artifact_root/application.log"
screenshot_path="$(driver screenshot)"
cp -- "$screenshot_path" "$artifact_root/final.png"

manifest="$driver_root/$run_id/manifest.json"
jq -e --arg run "$run_id" '.version == 1 and .run == $run' "$manifest" >/dev/null
cp -- "$manifest" "$artifact_root/manifest.json"
cp -- "$driver_root/$run_id/stdout.txt" "$artifact_root/conduit.stdout"
cp -- "$driver_root/$run_id/stderr.txt" "$artifact_root/conduit.stderr"

grep -Fq "window backend x11, high-pixel-density enabled" "$artifact_root/application.log"
grep -Fq "IBUS_ASSERT:exact" "$artifact_root/terminal.txt"
grep -Fq "IBUS_SECOND:exact" "$artifact_root/terminal.txt"

driver quit
run_id=""
