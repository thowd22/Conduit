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
      driver terminal-text >"$artifact_root/failure-terminal.txt" 2>/dev/null || true
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
  if [[ -n "${xim_bridge_pid:-}" ]]; then
    kill "$xim_bridge_pid" >/dev/null 2>&1 || true
  fi
  ibus exit >/dev/null 2>&1 || true
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
export LANG=C.UTF-8
# SDL 3.4's X11 backend reaches input methods only through XIM (its direct D-Bus IBus client is
# used by the Wayland backend), so the daemon must run its XIM bridge and XMODIFIERS must name it.
# Verified by strace: without XMODIFIERS the app never connects to the IBus socket.
export XMODIFIERS=@im=ibus
export GTK_IM_MODULE=ibus
export QT_IM_MODULE=ibus

# Engine selection must be settled before any context exists. The daemon reads these at startup,
# whereas changing them afterwards relies on a change notification racing the first context:
# one global engine, only Hangul preloaded, and Hangul mode from the first key (the engine's own
# default is Latin, which passes the keys through as ASCII with no preedit).
gsettings set org.freedesktop.ibus.general use-global-engine true
gsettings set org.freedesktop.ibus.general preload-engines "['hangul']"
gsettings set org.freedesktop.ibus.general engines-order "['hangul']"
gsettings set org.freedesktop.ibus.engine.hangul initial-input-mode hangul
{
  echo "use-global-engine $(gsettings get org.freedesktop.ibus.general use-global-engine)"
  echo "preload-engines $(gsettings get org.freedesktop.ibus.general preload-engines)"
  echo "initial-input-mode $(gsettings get org.freedesktop.ibus.engine.hangul initial-input-mode)"
} >"$artifact_root/ibus-settings.txt"

# Without `--xim`: the daemon would spawn its XIM bridge (ibus-x11) at once, and on a hosted
# runner that spawn races the daemon's own bus, so the bridge dies with "Not connected to the
# ibus bus" and XIM_SERVERS never appears (release gate run 37642511355). The bridge is started
# below, only after the daemon has answered a query.
ibus-daemon --daemonize --replace --panel disable \
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

# Select the global engine once the daemon answers; the preload list above makes it the only
# candidate, so a context created at any later moment also starts on Hangul.
ibus engine hangul

# The XIM bridge (ibus-x11) is started here, now that the daemon answers, so it cannot lose the
# race its daemon-spawned form loses. SDL opens its X input method once, when the window is
# created, so if Conduit starts before the bridge has registered itself on the X server every
# key stays plain ASCII for the whole session (seen on a hosted run as a lone probe 'g'). The
# root window's XIM_SERVERS property is the readiness signal.
xim_bridge=""
for candidate in /usr/libexec/ibus-x11 /usr/lib/ibus/ibus-x11 \
    /usr/lib/x86_64-linux-gnu/ibus/ibus-x11 "$(command -v ibus-x11 2>/dev/null || true)"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    xim_bridge="$candidate"
    break
  fi
done
if [[ -z "$xim_bridge" ]]; then
  echo "no ibus-x11 XIM bridge executable found" >&2
  exit 1
fi
echo "$xim_bridge" >"$artifact_root/xim-bridge.txt"
"$xim_bridge" >"$artifact_root/ibus-x11.stdout" 2>"$artifact_root/ibus-x11.stderr" &
xim_bridge_pid=$!
deadline=$((SECONDS + 20))
until xprop -root XIM_SERVERS 2>/dev/null | grep -q '@server=ibus'; do
  if (( SECONDS >= deadline )); then
    echo "the IBus XIM server did not register with the X server within 20 seconds" >&2
    if ! kill -0 "$xim_bridge_pid" 2>/dev/null; then
      echo "the XIM bridge exited early; its stderr follows" >&2
      cat "$artifact_root/ibus-x11.stderr" >&2 || true
    fi
    exit 1
  fi
  sleep 0.05
done
xprop -root XIM_SERVERS >"$artifact_root/xim-servers.txt"

# `conduit-test launch` gives the app a private HOME and XDG_CONFIG_HOME, so a client looking for
# the daemon's socket file under the real $XDG_CONFIG_HOME/ibus/bus would not find it. The XIM
# bridge needs no file, but IBUS_ADDRESS is exported for any D-Bus client (SDL reads it first) and
# recorded as evidence of the bus the run used.
IBUS_ADDRESS="$(ibus address)"
if [[ -z "$IBUS_ADDRESS" ]]; then
  echo "IBus published no bus address" >&2
  exit 1
fi
export IBUS_ADDRESS
printf '%s\n' "$IBUS_ADDRESS" >"$artifact_root/ibus-address.txt"

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
# The click gives Conduit X focus and SDL's IBus context focus-in; wait until the daemon reports
# Hangul for the focused context rather than assuming the focus round trip is instantaneous.
deadline=$((SECONDS + 10))
until [[ "$(ibus engine 2>/dev/null)" == "hangul" ]]; do
  if (( SECONDS >= deadline )); then
    echo "IBus did not report the Hangul engine for the focused Conduit context" >&2
    exit 1
  fi
  sleep 0.05
done

# The daemon spawns ibus-engine-hangul lazily on the first focus-in, and keys that arrive before
# the engine answers pass through as ASCII (seen on a hosted run: the child received 'gksrmf').
# Wait for the engine process, then probe with the first Dubeolsik key until a preedit appears,
# erasing a passed-through probe with Backspace before trying again. Both loops are bounded.
deadline=$((SECONDS + 15))
until pgrep -f ibus-engine-hangul >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo "ibus-engine-hangul did not start within 15 seconds of focusing Conduit" >&2
    exit 1
  fi
  sleep 0.05
done
probe_attempts=0
until driver wait-for element ime.preedit exists true 2000 >/dev/null 2>&1; do
  probe_attempts=$((probe_attempts + 1))
  if (( probe_attempts > 5 )); then
    echo "IBus never composed the probe key after 5 attempts" >&2
    exit 1
  fi
  if (( probe_attempts > 1 )); then
    # The previous probe passed through as ASCII; remove it from the child's line buffer.
    xdotool key --clearmodifiers BackSpace
  fi
  xdotool type --clearmodifiers g
done
echo "probe attempts: $probe_attempts" | tee "$artifact_root/probe-attempts.txt"

# XTest key events enter SDL's X11 event queue. IBus turns the Dubeolsik sequence into one UTF-8
# commit; the PTY fixture rejects raw ASCII, duplicate commits and any other line.
xdotool type --clearmodifiers ksrmf
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
