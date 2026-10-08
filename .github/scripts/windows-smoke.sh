#!/usr/bin/env bash
# TASK-49 AC1 and AC4: Conduit runs a local Windows shell with correct
# rendering and input, driven end to end through conduit-test.
#
# Usage: windows-smoke.sh <conduit.exe> <conduit-test.exe> <artifact-dir>
#
#   1. cmd.exe under ConPTY: a visible 640x360 window at scale 1 whose child is
#      the real `cmd.exe` (selected through SHELL, the interactive-shell input
#      Conduit reads today). Typed text crosses the real SDL event queue, cmd
#      runs it, and its output is asserted with wait-for.
#   2. Unicode text input: a non-ASCII string typed through the driver (SDL
#      text-input events, the path an IME commit takes) reaches cmd.exe and is
#      echoed back exactly once.
#   3. Frames: a screenshot at scale 1 (640x360) and one at scale 1.5 (960x540)
#      are kept for visual inspection; their pixel sizes are checked here.
#   4. PowerShell: the same round trip with PowerShell as the shell.
set -uo pipefail

conduit="${1:?usage: windows-smoke.sh <conduit.exe> <conduit-test.exe> <artifact-dir>}"
driver="${2:?usage}"
out="${3:?usage}"
mkdir -p "$out"
root="$(cygpath -w "$(mktemp -d "${RUNNER_TEMP:-/tmp}/csm.XXXXXX")")"
# shellcheck source=windows-common.sh
. "$(dirname "$0")/windows-common.sh"
failed=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*" >&2; failed=$((failed + 1)); }

finish_run() {
  local tag="$1"
  ct logs 1048576 > "$out/$tag-app.log" 2>&1 || true
  ct inspect > "$out/$tag-tree.json" 2>&1 || true
  ct terminal-text > "$out/$tag-terminal.txt" 2>&1 || true
  ct quit > /dev/null 2>&1 || true
}

keep_screenshot() {
  local tag="$1" want="$2"
  local shot
  shot="$(ct screenshot)" || shot=""
  if [ -n "$shot" ] && [ -f "$(cygpath -u "$shot")" ]; then
    cp "$(cygpath -u "$shot")" "$out/$tag.png"
    local size
    size="$(png_size "$out/$tag.png")"
    if [ "$size" = "$want" ]; then
      pass "$tag: screenshot is $size ($out/$tag.png)"
    else
      fail "$tag: screenshot is $size, expected $want"
    fi
  else
    fail "$tag: no screenshot"
  fi
}

# 1-3. cmd.exe at scale 1, then at 1.5.
for scale in 1 1.5; do
  tag="cmd-scale-$scale"
  run="$(launch 'C:\Windows\System32\cmd.exe' --conduit="$(cygpath -w "$conduit")" \
    --visible --width=640 --height=360 --scale="$scale")" || {
    fail "$tag: launch failed"
    continue
  }
  echo "INFO $tag run $run"
  if ct wait-for terminal-text ">" 20000 > /dev/null; then
    pass "$tag: cmd.exe drew its prompt"
  else
    fail "$tag: no cmd.exe prompt"
  fi
  ct type "chcp 65001 > nul & echo CONDUIT_%OS%_READY" > /dev/null
  ct key ENTER > /dev/null
  if ct wait-for terminal-text "CONDUIT_Windows_NT_READY" 20000 > /dev/null; then
    pass "$tag: typed command ran in cmd.exe and its output was drawn"
  else
    fail "$tag: cmd.exe never printed CONDUIT_Windows_NT_READY"
  fi
  if [ "$scale" = 1 ]; then
    unicode='héllo wörld ✓ 日本語'
    ct type "echo U[$unicode]" > /dev/null
    ct key ENTER > /dev/null
    if ct wait-for terminal-text "U[$unicode]" 20000 > /dev/null; then
      count="$(ct terminal-text | grep -cF "U[$unicode]" || true)"
      # Once as typed on the command line, once as echo's output.
      if [ "$count" = 2 ]; then
        pass "unicode text input: '$unicode' reached cmd.exe once and was echoed"
      else
        fail "unicode text input: the line appears $count times, expected 2"
      fi
    else
      fail "unicode text input: '$unicode' never came back from cmd.exe"
    fi
    ct type "dir /b C:\\Windows\\System32\\cmd.exe" > /dev/null
    ct key ENTER > /dev/null
    ct wait-for terminal-text "cmd.exe" 10000 > /dev/null || true
    keep_screenshot "$tag" 640x360
  else
    keep_screenshot "$tag" 960x540
  fi
  finish_run "$tag"
  grep -E "window backend|window conduit|physical pixels|drawing with|window geometry|dpi awareness|OpenGL|GL_RENDERER|renderer" "$out/$tag-app.log" | head -n 10 | sed 's/^/INFO /'
done

# 4. PowerShell.
pwsh_path="$(command -v pwsh.exe || command -v powershell.exe || true)"
if [ -n "$pwsh_path" ]; then
  tag="pwsh"
  if run="$(launch "$(cygpath -w "$pwsh_path")" --conduit="$(cygpath -w "$conduit")" \
    --visible --width=640 --height=360 --scale=1)"; then
    ct wait-for terminal-text "PS " 30000 > /dev/null || true
    ct type "Write-Output (\"PWSH_\" + (6*7))" > /dev/null
    ct key ENTER > /dev/null
    if ct wait-for terminal-text "PWSH_42" 30000 > /dev/null; then
      pass "pwsh: typed pipeline ran and printed PWSH_42"
    else
      fail "pwsh: never printed PWSH_42"
    fi
    keep_screenshot "$tag" 640x360
    finish_run "$tag"
  else
    fail "pwsh: launch failed"
  fi
fi

echo "$failed smoke step(s) failed"
[ "$failed" -eq 0 ]
