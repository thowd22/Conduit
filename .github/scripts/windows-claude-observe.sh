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
# --- TASK-83 diagnostics (temporary) ------------------------------------------
# A raw-mode probe under Node and under Bun (Claude Code's runtime): two Ctrl+C
# presses through the driver; the second opens /dev/tty and reads it once, as
# Claude Code's drainStdin does on exit, then calls process.exit.
probe_js="$(cygpath -u "$root")/ctrl-c-probe.js"
cat > "$probe_js" <<'JS'
const fs = require("fs");
const label = process.argv[2] || "x";
let presses = 0;
process.stdin.setRawMode(true);
process.stdin.resume();
console.log("probe-" + "ready-" + label + " " + (process.versions.bun ? "bun " + process.versions.bun : "node " + process.version));
process.stdin.on("data", (d) => {
  console.log("DATA-" + label + " " + [...d].join(","));
  if (d.includes(3) && ++presses === 2) {
    console.log("EXITING-" + label);
    let fd = -1;
    try {
      fd = fs.openSync("/dev/tty", fs.constants.O_RDONLY | (fs.constants.O_NONBLOCK || 0));
      console.log("TTY-OPEN-" + label + " " + fd);
    } catch (e) {
      console.log("TTY-OPEN-FAILED-" + label + " " + e.code);
    }
    if (fd >= 0) {
      try {
        const n = fs.readSync(fd, Buffer.alloc(64), 0, 64, null);
        console.log("TTY-READ-" + label + " " + n);
      } catch (e) {
        console.log("TTY-READ-FAILED-" + label + " " + e.code);
      }
    }
    process.exit(0);
  }
});
JS
probe_win="$(cygpath -w "$probe_js")"

# claude_state <label>: what Windows says about claude.exe and its children.
claude_state() {
  powershell.exe -NoProfile -Command "\$p = @(Get-Process claude -ErrorAction SilentlyContinue); if (\$p.Count -eq 0) { 'no claude process' } else { foreach (\$q in \$p) { 'pid ' + \$q.Id + ' responding ' + \$q.Responding + ' cpu ' + \$q.CPU + ' threads ' + \$q.Threads.Count + ' handles ' + \$q.HandleCount; \$q.Threads | Group-Object ThreadState,WaitReason | ForEach-Object { '  ' + \$_.Count + ' x ' + \$_.Name } }; Get-CimInstance Win32_Process | Where-Object { \$p.Id -contains \$_.ParentProcessId } | ForEach-Object { '  child ' + \$_.ProcessId + ' ' + \$_.CommandLine } }" \
    2>&1 | tr -d '\r' | sed "s/^/INFO $1: /"
}

# probe_runtime <label>: run the probe under <label> (node or bun), press
# Ctrl+C twice, report.
probe_runtime() {
  local label="$1"
  if ! command -v "$label" > /dev/null; then
    echo "INFO probe $label: not installed"
    return
  fi
  ct type "$label '$probe_win' $label; 'probe' + '-ended-$label'" > /dev/null
  ct key ENTER > /dev/null
  if ! ct wait-for terminal-text "probe-ready-$label" 60000 > /dev/null; then
    echo "INFO probe $label: never ready"
    ct terminal-text > "$out/probe-$label.txt" 2>&1 || true
    return
  fi
  ct key CTRL+c > /dev/null
  ct wait-for terminal-text "DATA-$label 3" 5000 > /dev/null || echo "INFO probe $label: first Ctrl+C did not arrive as byte 3"
  ct key CTRL+c > /dev/null
  ct wait-for terminal-text "EXITING-$label" 5000 > /dev/null || echo "INFO probe $label: second Ctrl+C did not arrive"
  if ct wait-for terminal-text "probe-ended-$label" 10000 > /dev/null; then
    echo "INFO probe $label: the process ended and PowerShell went on"
  else
    echo "INFO probe $label: the process did not end within 10 s; one more key"
    ct key x > /dev/null
    if ct wait-for terminal-text "probe-ended-$label" 10000 > /dev/null; then
      echo "INFO probe $label: one more key ended it"
    else
      echo "INFO probe $label: still running after one more key"
      taskkill /F /IM "$label.exe" > /dev/null 2>&1 || true
      ct wait-for terminal-text "probe-ended-$label" 10000 > /dev/null || true
    fi
  fi
  ct terminal-text > "$out/probe-$label.txt" 2>&1 || true
  grep -E "probe-ready|DATA-|EXITING-|TTY-" "$out/probe-$label.txt" | sed "s/^/INFO probe $label screen: /"
}
probe_runtime node
probe_runtime bun
ct type "Clear-Host" > /dev/null
ct key ENTER > /dev/null

# The same Claude Code in a classic console window (no pseudoconsole), with
# Ctrl+C sent by SendKeys, for comparison.
classic_ps1="$(cygpath -u "$root")/classic.ps1"
cat > "$classic_ps1" <<'PS1'
$exe = (Get-Command claude.exe -ErrorAction SilentlyContinue).Source
if (-not $exe) { $exe = 'C:\npm\prefix\node_modules\@anthropic-ai\claude-code\bin\claude.exe' }
$p = Start-Process -FilePath $exe -PassThru -WorkingDirectory 'D:\a\Conduit\Conduit'
Start-Sleep -Seconds 10
$w = New-Object -ComObject WScript.Shell
'classic: activate ' + $w.AppActivate($p.Id)
Start-Sleep -Seconds 1
$w.SendKeys('^c')
Start-Sleep -Milliseconds 300
$w.SendKeys('^c')
if ($p.WaitForExit(15000)) { 'classic: exited with ' + $p.ExitCode } else { 'classic: still running 15 s after two Ctrl+C'; Stop-Process -Id $p.Id -Force }
PS1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$classic_ps1")" 2>&1 | tr -d '\r' | sed 's/^/INFO /'
# --- end of TASK-83 diagnostics -----------------------------------------------

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

# TASK-83 diagnostics (temporary): one press alone first, to see whether
# Claude Code clears its "Press Ctrl-C again" hint (alive, timers running).
claude_state "idle"
ct key CTRL+c > /dev/null
if ct wait-for terminal-text "Press Ctrl-C again" 5000 > /dev/null; then
  echo "INFO single press: hint shown"
  cleared=no
  for _ in $(seq 1 20); do
    if ! ct terminal-text 2> /dev/null | grep -q "Press Ctrl-C again"; then cleared=yes; break; fi
    sleep 0.5
  done
  echo "INFO single press: hint cleared within 10 s: $cleared"
else
  echo "INFO single press: no hint"
fi

# Ctrl+C until Claude Code has left: the first asks "Press Ctrl-C again to
# exit", and a second within a moment of that ends it.
left=""
ct key CTRL+c > /dev/null
ct wait-for terminal-text "Press Ctrl-C again" 3000 > /dev/null || true
ct key CTRL+c > /dev/null
if ct wait-for element workspace.1.tab.1.agent.done exists true 5000 > /dev/null; then
  left=ctrl-c
else
  echo "INFO Ctrl+C twice: claude is still in front"
  claude_state "after double press"
  ct terminal-text > "$out/claude-after-double.txt" 2>&1 || true
  # Is it waiting for input? One key, then up to seventy more.
  ct key x > /dev/null
  if ct wait-for element workspace.1.tab.1.agent.done exists true 5000 > /dev/null; then
    left=one-more-key
  else
    for n in $(seq 1 70); do
      ct key x > /dev/null
      if ct wait-for element workspace.1.tab.1.agent.done exists true 150 > /dev/null 2>&1; then
        left="$n-more-keys"
        break
      fi
    done
  fi
  echo "INFO extra keys: ${left:-none ended it}"
  [ -n "$left" ] && left="keys:$left"
fi
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
