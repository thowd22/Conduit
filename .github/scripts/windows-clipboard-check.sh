#!/usr/bin/env bash
# TASK-49 AC1 and TASK-15 on Windows: copy and paste through the Windows
# clipboard.
#
# Usage: windows-clipboard-check.sh <conduit.exe> <conduit-test.exe> <artifact-dir>
#
# `--clipboard-test` runs on SDL's process-local offscreen clipboard, so it
# never proves the OS clipboard. This drives a real Win32 window whose child is
# cmd.exe through `conduit-test` (the real SDL event queue) instead:
#
#   paste  PowerShell's Set-Clipboard puts a fixture on the Windows clipboard,
#          Ctrl+Shift+V (`clipboard.paste` on Linux/Windows) pastes it into an
#          `echo GOT[...]` line, and cmd.exe must print exactly that fixture.
#   copy   a double click on a file reference selects that word in the
#          terminal, Ctrl+Shift+C (`clipboard.copy`) is sent, and PowerShell's
#          Get-Clipboard must return exactly the selected text.
set -euo pipefail
export MSYS_NO_PATHCONV=1

conduit="${1:?usage: windows-clipboard-check.sh <conduit.exe> <conduit-test.exe> <artifact-dir>}"
driver="${2:?usage}"
out="${3:?usage}"
mkdir -p "$out"
root="$(cygpath -w "$(mktemp -d "${RUNNER_TEMP:-/tmp}/ccb.XXXXXX")")"

put() { powershell.exe -NoProfile -Command "Set-Clipboard -Value '$1'"; }
get() { powershell.exe -NoProfile -Command "Get-Clipboard" | tr -d '\r'; }

fixture="conduit-paste-$(date +%s)-$$"
selection="kestrel/lantern.txt"
put "$fixture"
[ "$(get)" = "$fixture" ] || { echo "FAIL: the Windows clipboard did not take the fixture" >&2; exit 1; }

# shellcheck source=windows-common.sh
. "$(dirname "$0")/windows-common.sh"
run="$(launch 'C:\Windows\System32\cmd.exe' --conduit="$(cygpath -w "$conduit")" \
  --visible --width=640 --height=360 --scale=1)"
cleanup() {
  ct logs 1048576 > "$out/app.log" 2>&1 || true
  shot="$(ct screenshot 2>/dev/null)" && cp "$(cygpath -u "$shot")" "$out/final.png" 2>/dev/null || true
  ct quit > /dev/null 2>&1 || true
}
trap cleanup EXIT

ct wait-for terminal-text ">" 20000 > /dev/null
ct type "echo pick: $selection" > /dev/null
ct key ENTER > /dev/null
ct wait-for terminal-text "pick: $selection" 10000 > /dev/null

# Paste: the Windows clipboard into the child.
ct type "echo GOT[" > /dev/null
ct key "CTRL+SHIFT+v" > /dev/null
ct type "]" > /dev/null
ct key ENTER > /dev/null
if ct wait-for terminal-text "GOT[$fixture]" 10000 > /dev/null; then
  echo "PASS paste: cmd.exe echoed the Windows clipboard fixture after Ctrl+Shift+V"
else
  echo "FAIL paste: cmd.exe never printed GOT[$fixture]" >&2
  ct terminal-text >&2 || true
  exit 1
fi

# Copy: a terminal selection onto the Windows clipboard.
link="$(ct inspect | python -c '
import json, sys
tree = json.load(sys.stdin)
for e in tree["elements"]:
    if e["role"] == "terminal_link" and e["label"] == sys.argv[1]:
        print(e["id"])
        break
' "$selection" | tr -d '\r')"
[ -n "$link" ] || { echo "FAIL copy: no terminal_link element for $selection" >&2; exit 1; }
ct double-click "$link" > /dev/null
ct key "CTRL+SHIFT+c" > /dev/null
copied=""
for _ in $(seq 1 50); do
  copied="$(get)"
  [ "$copied" = "$selection" ] && break
  # The copy crosses the app's event loop; poll the clipboard rather than sleep once.
  python -c 'import time; time.sleep(0.1)'
done
if [ "$copied" = "$selection" ]; then
  echo "PASS copy: Ctrl+Shift+C put the double-clicked selection '$selection' on the Windows clipboard"
else
  echo "FAIL copy: the Windows clipboard holds '$copied', expected '$selection'" >&2
  exit 1
fi
