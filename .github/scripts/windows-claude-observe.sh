#!/usr/bin/env bash
# TASK-81 AC2: a Claude Code started by hand in a PowerShell tab is observed.
#
# Usage: windows-claude-observe.sh <conduit.exe> <conduit-test.exe> <artifact-dir>
#
# `claude` must already be on PATH (the workflow installs it with
# `npm i -g @anthropic-ai/claude-code`). It is never authenticated: started in
# an isolated run it stops at its first-run onboarding, which is enough for
# Conduit to see it as the PowerShell tab's foreground job. Through
# conduit-test, exactly as a person would:
#
#   1. launch a run whose first tab is the default shell (PowerShell);
#   2. type `claude` and Enter;
#   3. wait for the tab's observed-agent glyph and check the agent's own row,
#      `workspace.1.tab.1.agent-row.<id>`, reads `· claude idle`;
#   4. Ctrl+C until Claude Code exits (or, reported with a warning when Ctrl+C
#      does not reach it, end it with taskkill), then wait for `done` and
#      check the row reads `✓ claude done`.
#
# Screenshots of both states, the semantic tree, the terminal text and the
# app log are kept in <artifact-dir>.
set -uo pipefail

conduit="${1:?usage: windows-claude-observe.sh <conduit.exe> <conduit-test.exe> <artifact-dir>}"
driver="${2:?usage}"
out="${3:?usage}"
mkdir -p "$out"
root="$(cygpath -w "$(mktemp -d "${RUNNER_TEMP:-/tmp}/cco.XXXXXX")")"
# shellcheck source=windows-common.sh
. "$(dirname "$0")/windows-common.sh"
failed=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*" >&2; failed=$((failed + 1)); }

py="$(command -v python || command -v python3)"

# agent_row: the label of the first tab-1 agent row, or nothing; its id goes
# to stderr.
agent_row() {
  local tree
  tree="$(mktemp "${RUNNER_TEMP:-/tmp}/ctree.XXXXXX")"
  ct --json inspect > "$tree" || return 0
  "$py" -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as tree:
    reply = json.load(tree)
for element in reply.get("result", reply).get("elements", []):
    ident = element.get("id", "")
    if ident.startswith("workspace.1.tab.1.agent-row."):
        sys.stderr.write("INFO agent row id " + ident + "\n")
        sys.stdout.buffer.write(element.get("label", "").encode("utf-8"))
        break
' "$tree"
}

keep_screenshot() {
  local shot
  shot="$(ct screenshot)" || shot=""
  if [ -n "$shot" ] && [ -f "$(cygpath -u "$shot")" ]; then
    cp "$(cygpath -u "$shot")" "$out/$1.png"
    echo "INFO screenshot $out/$1.png"
  else
    fail "$1: no screenshot"
  fi
}

claude_path="$(command -v claude || command -v claude.cmd || true)"
[ -n "$claude_path" ] || { echo "FAIL: claude is not on PATH" >&2; exit 1; }
echo "INFO claude at $claude_path"

pwsh_path="$(command -v pwsh.exe || command -v powershell.exe)"
# Claude Code on Windows runs its tools through Git for Windows' bash.
export CLAUDE_CODE_GIT_BASH_PATH='C:\Program Files\Git\bin\bash.exe'
run="$(launch "$(cygpath -w "$pwsh_path")" --conduit="$(cygpath -w "$conduit")" \
  --visible --width=800 --height=450 --scale=1)" || { echo "FAIL: launch failed" >&2; exit 1; }
echo "INFO run $run"

if ct wait-for terminal-text "PS " 60000 > /dev/null; then
  pass "PowerShell drew its prompt"
else
  fail "no PowerShell prompt"
fi
ct type "claude" > /dev/null
ct key ENTER > /dev/null

# The observed agent's glyph is a semantic element of the tab row; the check
# runs at most every two seconds once the terminal is active.
if ct wait-for element workspace.1.tab.1.agent.idle exists true 90000 > /dev/null; then
  pass "the hand-started claude was observed on the PowerShell tab (idle glyph)"
else
  fail "no idle agent glyph on the PowerShell tab"
fi
# The process tree as Windows reports it, for the evidence.
powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,CreationDate,Name,CommandLine | Format-List" \
  > "$out/processes.txt" 2>&1 || true
grep -B2 -A3 -iE "claude|pwsh" "$out/processes.txt" | sed 's/^/INFO /' | head -n 60
row="$(agent_row)"
echo "INFO agent row: ${row:-<none>}"
case "$row" in
  "· claude idle") pass "the agent row reads '· claude idle'" ;;
  *) fail "the agent row is '${row:-<none>}', expected '· claude idle'" ;;
esac
keep_screenshot claude-idle
ct terminal-text > "$out/claude-terminal.txt" 2>&1 || true

# Ctrl+C until Claude Code has left: the first asks "Press Ctrl-C again to
# exit", and a second within a moment of that ends it.
left=""
for attempt in 1 2 3; do
  ct key CTRL+c > /dev/null
  ct wait-for terminal-text "Press Ctrl-C again" 3000 > /dev/null || true
  ct key CTRL+c > /dev/null
  if ct wait-for element workspace.1.tab.1.agent.done exists true 5000 > /dev/null; then
    left=ctrl-c
    break
  fi
  echo "INFO Ctrl+C $attempt: claude is still in front"
done
ct terminal-text > "$out/claude-after-ctrl-c.txt" 2>&1 || true
if [ -z "$left" ]; then
  # Reported, not gating: Ctrl+C through the pseudoconsole has not reached
  # this Claude Code on the runner. What is gated is that its leaving the
  # foreground ends the observed agent, so it is ended from outside.
  echo "::warning::Ctrl+C did not end claude under ConPTY; ending it with taskkill"
  taskkill /F /IM claude.exe || true
  left=taskkill
fi
echo "INFO claude left by $left"
if ct wait-for element workspace.1.tab.1.agent.done exists true 10000 > /dev/null; then
  pass "leaving claude marked the observed agent done"
else
  fail "the observed agent never showed done"
fi
row="$(agent_row)"
echo "INFO agent row: ${row:-<none>}"
case "$row" in
  "✓ claude done") pass "the agent row reads '✓ claude done'" ;;
  *) fail "the agent row is '${row:-<none>}', expected '✓ claude done'" ;;
esac
keep_screenshot claude-done

ct logs 1048576 > "$out/app.log" 2>&1 || true
ct inspect > "$out/tree.txt" 2>&1 || true
ct terminal-text >> "$out/claude-terminal.txt" 2>&1 || true
ct quit > /dev/null 2>&1 || true
grep -E "agents|foreground|observ" "$out/app.log" | tail -n 20 | sed 's/^/INFO /'

echo "$failed claude observation step(s) failed"
[ "$failed" -eq 0 ]
