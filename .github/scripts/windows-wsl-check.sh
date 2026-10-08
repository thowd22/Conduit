#!/usr/bin/env bash
# TASK-47 AC1-AC3: a WSL workspace driven end to end through conduit-test.
#
# Usage: windows-wsl-check.sh <conduit> <conduit-test> <artifact-dir> <distribution> [launcher]
#
#   1. AC1: Remote: connect, opened from the clickable sidebar Palette hint,
#      lists <distribution> as a `wsl:<distribution>` choice; the row is
#      clicked.
#   2. AC2: the new workspace's first tab is a login shell inside the
#      distribution (Linux `uname`, `$WSL_DISTRO_NAME`), a pane split by its
#      keybinding is too, and so is the workspace's scratchpad.
#   3. AC3: a `C:\Windows\win.ini:3` reference printed in that terminal is
#      ctrl-clicked by its semantic link id, and a new tab opens vi on the
#      translated `/mnt/c/Windows/win.ini` inside the distribution.
#
# On the Windows runner <distribution> is the real one `wsl.exe` runs. With a
# [launcher] (Linux, for development), a driven run is given that stand-in
# for `wsl.exe` through CONDUIT_TEST_WSL_LAUNCHER and <distribution> is the
# name the stand-in answers to.
set -uo pipefail

conduit="${1:?usage: windows-wsl-check.sh <conduit> <conduit-test> <artifact-dir> <distribution> [launcher]}"
driver="${2:?usage}"
out="${3:?usage}"
distro="${4:?usage}"
launcher="${5:-}"
mkdir -p "$out"
if command -v cygpath > /dev/null; then
  winpath() { cygpath -w "$1"; }
  unixpath() { cygpath -u "$1"; }
  local_shell='C:\Windows\System32\cmd.exe'
else
  winpath() { printf '%s' "$1"; }
  unixpath() { printf '%s' "$1"; }
  local_shell=/bin/sh
fi
root="$(winpath "$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cwsl.XXXXXX")")"
# shellcheck source=windows-common.sh
. "$(dirname "$0")/windows-common.sh"
failed=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*" >&2; failed=$((failed + 1)); }

# The id of the last element in the semantic tree whose JSON object contains
# every given fragment, or nothing.
py="$(command -v python || command -v python3)"
element_id() {
  ct --json inspect > "$out/tree.json" 2>&1 || return 0
  "$py" - "$out/tree.json" "$@" <<'PY'
import json, sys
def walk(node, found):
    if isinstance(node, dict):
        # A fragment `label=<text>` must be the whole label; any other is a
        # substring of some field.
        def has(f):
            if f.startswith("label="):
                return node.get("label") == f[len("label="):]
            return any(f in str(v) for v in node.values())
        if "id" in node and all(has(f) for f in sys.argv[2:]):
            found.append(node["id"])
        for value in node.values():
            walk(value, found)
    elif isinstance(node, list):
        for value in node:
            walk(value, found)
found = []
try:
    walk(json.load(open(sys.argv[1], encoding="utf-8")), found)
except ValueError:
    pass
print(found[-1] if found else "")
PY
}

shot() {
  local tag="$1" path
  path="$(ct screenshot)" || path=""
  if [ -n "$path" ] && [ -f "$(unixpath "$path")" ]; then
    cp "$(unixpath "$path")" "$out/$tag.png"
    echo "INFO screenshot $out/$tag.png"
  else
    fail "$tag: no screenshot"
  fi
}

finish() {
  ct logs 1048576 > "$out/app.log" 2>&1 || true
  ct inspect > "$out/final-tree.txt" 2>&1 || true
  ct terminal-text > "$out/final-terminal.txt" 2>&1 || true
  ct terminal-text --target scratchpad > "$out/final-scratchpad.txt" 2>&1 || true
  ct quit > /dev/null 2>&1 || true
}

visible=(--visible)
[ -n "$launcher" ] && visible=()
if [ -n "$launcher" ]; then export CONDUIT_TEST_WSL_LAUNCHER="$launcher"; fi
run="$(launch "$local_shell" --conduit="$(winpath "$conduit")" "${visible[@]}" --width=800 --height=450 --scale=1)" || {
  fail "launch failed"
  exit 1
}
unset CONDUIT_TEST_WSL_LAUNCHER
echo "INFO run $run"
trap finish EXIT

# 1. AC1: the distribution is a Remote: connect target.
ct wait-for element sidebar.palette exists true 30000 > /dev/null || fail "no sidebar palette hint"
ct click sidebar.palette > /dev/null
ct wait-for element palette.query focused true 10000 > /dev/null || fail "the palette did not open"
ct type "remote connect" > /dev/null
ct key ENTER > /dev/null
ct wait-for element palette.filter exists true 10000 > /dev/null || fail "Remote: connect asked for no target"
row="$(element_id "palette.choice." "$distro  WSL")"
if [ -n "$row" ]; then
  pass "AC1: Remote: connect lists '$distro  WSL' as $row"
else
  fail "AC1: no '$distro  WSL' row in Remote: connect"
fi
shot ac1-connect-targets
[ -n "$row" ] && ct click "$row" > /dev/null

# 2. AC2: the first tab, a split pane and the scratchpad run in the distribution.
ws="$(element_id "workspace" "label=$distro")"
if [ -n "$ws" ]; then pass "AC1: the workspace row $ws is named $distro"; else fail "AC1: no workspace row named $distro"; fi
ct type 'echo "TAB=$WSL_DISTRO_NAME/$(uname -s)"' > /dev/null
ct key ENTER > /dev/null
if ct wait-for terminal-text "TAB=$distro/Linux" 180000 > /dev/null; then
  pass "AC2: the WSL workspace's first tab runs in $distro (uname Linux)"
else
  fail "AC2: the first tab never printed TAB=$distro/Linux"
fi

ct key CTRL+SHIFT+e > /dev/null
ct type 'echo "PANE=$WSL_DISTRO_NAME/$(uname -s)"' > /dev/null
ct key ENTER > /dev/null
if ct wait-for terminal-text "PANE=$distro/Linux" 120000 > /dev/null; then
  pass "AC2: a split pane runs in $distro"
else
  fail "AC2: the split pane never printed PANE=$distro/Linux"
fi
shot ac2-split

ct key 'CTRL+`' > /dev/null
pad_hide="$ws.scratchpad.hide"
ct wait-for element "$pad_hide" exists true 20000 > /dev/null || fail "the scratchpad did not show"
ct type 'echo "PAD=$WSL_DISTRO_NAME/$(uname -s)"' > /dev/null
ct key ENTER > /dev/null
if ct wait-for terminal-text "PAD=$distro/Linux" 120000 --target scratchpad > /dev/null; then
  pass "AC2: the scratchpad runs in $distro"
else
  fail "AC2: the scratchpad never printed PAD=$distro/Linux"
fi
shot ac2-scratchpad
ct click "$pad_hide" > /dev/null
ct wait-for element "$pad_hide" exists false 10000 > /dev/null || fail "the scratchpad did not hide"

# 3. AC3: a Windows file reference opens vi on the distribution's path.
# The typed line spells the backslashes as octal escapes, so the only
# reference reading exactly C:\Windows\win.ini:3 is printf's output.
ct type "printf 'C:\\134Windows\\134win.ini:3\\n'" > /dev/null
ct key ENTER > /dev/null
ct wait-for terminal-text 'C:\Windows\win.ini:3' 20000 > /dev/null || fail "the reference was not printed"
reference="$(element_id "terminal_link" 'label=C:\Windows\win.ini:3')"
if [ -n "$reference" ]; then
  echo "INFO reference link: $reference"
  ct ctrl-click "$reference" > /dev/null
  if ct wait-for terminal-text "/mnt/c/Windows/win.ini" 60000 > /dev/null; then
    pass "AC3: ctrl-clicking C:\\Windows\\win.ini:3 opened vi on /mnt/c/Windows/win.ini"
  else
    fail "AC3: vi never showed /mnt/c/Windows/win.ini"
  fi
  tab="$(element_id "tab" "win.ini")"
  if [ -n "$tab" ]; then pass "AC3: the editor tab is $tab"; else fail "AC3: no win.ini tab in the sidebar"; fi
else
  fail "AC3: no terminal link registered for the reference"
fi
shot ac3-editor

echo "$failed WSL step(s) failed"
[ "$failed" -eq 0 ]
