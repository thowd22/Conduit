#!/usr/bin/env bash
# TASK-15 AC1 on macOS: copy and paste through the *system* clipboard.
#
# Usage: macos-clipboard-check.sh <conduit> <conduit-test> <artifact-dir>
#
# `--clipboard-test` deliberately runs on SDL's process-local offscreen
# clipboard, so it never proves the OS pasteboard. This check drives a real
# Cocoa window through `conduit-test` (the real SDL event queue) instead:
#
#   paste  `pbcopy` puts a fixture on the general pasteboard, Cmd+V
#          (`SUPER+v`, the macOS default `clipboard.paste`) is sent, and the
#          child must read exactly that fixture.
#   copy   a double click on a file reference selects that word in the
#          terminal, Cmd+C (`clipboard.copy`) is sent, and `pbpaste` must
#          return exactly the selected text.
#
# On Linux the same script runs under Xvfb with xclip and the Ctrl+Shift
# chords, which is how it was checked before it reached a Mac.
set -euo pipefail

conduit="${1:?usage: macos-clipboard-check.sh <conduit> <conduit-test> <artifact-dir>}"
driver="${2:?usage: macos-clipboard-check.sh <conduit> <conduit-test> <artifact-dir>}"
out="${3:?usage: macos-clipboard-check.sh <conduit> <conduit-test> <artifact-dir>}"
mkdir -p "$out"
root="$(mktemp -d "${TMPDIR:-/tmp}/cclip.XXXXXX")"

case "$(uname -s)" in
  Darwin)
    put() { printf '%s' "$1" | pbcopy; }
    get() { pbpaste; }
    mod=SUPER
    ;;
  *)
    put() { printf '%s' "$1" | xclip -selection clipboard -in; }
    get() { xclip -selection clipboard -out; }
    mod=CTRL+SHIFT
    ;;
esac

fixture="conduit-paste-$(date +%s)-$$"
selection="kestrel/lantern.txt"
put "$fixture"
[ "$(get)" = "$fixture" ] || { echo "FAIL: the system clipboard did not take the fixture" >&2; exit 1; }

ct() { "$driver" --root="$root" --run="$run" "$@"; }
run="$("$driver" --root="$root" launch --conduit="$conduit" --visible \
  --width=640 --height=360 --scale=1 \
  --command="printf 'pick: $selection\\n'; stty -echo; while IFS= read -r line; do printf 'GOT[%s]\\n' \"\$line\"; done")"
cleanup() {
  ct logs 1048576 > "$out/app.log" 2>&1 || true
  ct screenshot > "$out/screenshot-path.txt" 2>&1 && cp "$(cat "$out/screenshot-path.txt")" "$out/final.png" 2>/dev/null || true
  ct quit > /dev/null 2>&1 || true
}
trap cleanup EXIT

ct wait-for terminal-text "pick: $selection" 10000 > /dev/null

# Paste: the system clipboard into the child.
ct key "$mod+v" > /dev/null
ct key ENTER > /dev/null
if ct wait-for terminal-text "GOT[$fixture]" 10000 > /dev/null; then
  echo "PASS paste: the child read the system clipboard fixture after $mod+v"
else
  echo "FAIL paste: the child never read GOT[$fixture]" >&2
  ct terminal-text >&2 || true
  exit 1
fi

# Copy: a terminal selection onto the system clipboard.
link="$(ct inspect | python3 -c '
import json, sys
tree = json.load(sys.stdin)
for e in tree["elements"]:
    if e["role"] == "terminal_link" and e["label"] == sys.argv[1]:
        print(e["id"])
        break
' "$selection")"
[ -n "$link" ] || { echo "FAIL copy: no terminal_link element for $selection" >&2; exit 1; }
ct double-click "$link" > /dev/null
ct key "$mod+c" > /dev/null
copied=""
for _ in $(seq 1 50); do
  copied="$(get)"
  [ "$copied" = "$selection" ] && break
  # The copy crosses the app's event loop; poll the pasteboard rather than sleep once.
  perl -e 'select(undef, undef, undef, 0.1)'
done
if [ "$copied" = "$selection" ]; then
  echo "PASS copy: $mod+c put the double-clicked selection '$selection' on the system clipboard"
else
  echo "FAIL copy: the system clipboard holds '$copied', expected '$selection'" >&2
  exit 1
fi
