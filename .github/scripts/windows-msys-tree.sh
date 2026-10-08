#!/usr/bin/env bash
# Diagnostic (TASK-81): how a Git for Windows `sh` that runs a script by hand
# appears in the Windows process tree, with and without job control.
set -uo pipefail
dir="$(mktemp -d)"
cat > "$dir/busy-script" <<'EOF'
t=0
while [ "$t" -lt 400000 ]; do t=$((t + 1)); done
EOF
win_script="$(cygpath -w "$dir/busy-script")"
for mode in plain jobs viacmd; do
  case "$mode" in
    jobs) /c/bin/sh -c "set -m; sh $dir/busy-script; set +m; echo back" & ;;
    viacmd) /c/bin/sh -c "cmd.exe //c 'C:\\bin\\sh $win_script'; echo back" & ;;
    *) /c/bin/sh -c "sh $dir/busy-script; echo back" & ;;
  esac
  sleep 3
  echo "== $mode"
  powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { \$_.Name -match '^(sh|bash|cmd)' } | Select-Object ProcessId,ParentProcessId,CreationDate,CommandLine | Format-Table -AutoSize -Wrap | Out-String -Width 400"
  wait
done
