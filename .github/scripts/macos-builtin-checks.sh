#!/usr/bin/env bash
# Run Conduit's built-in checks on a macOS runner and report each one.
#
# Usage: macos-builtin-checks.sh <conduit> <artifact-dir> <check>...
#
# GitHub's macOS runners have a logged-in window server, so every check opens a
# real Cocoa window (hidden, as on Linux) with a real OpenGL context; nothing is
# wrapped in Xvfb. `--clipboard-test` pins SDL's offscreen driver itself. Each
# check gets its own log directory and screenshot, a 300 s alarm so a hang names
# the check, and its backend line is required to be `cocoa` (or `offscreen` for
# the clipboard check). Every check runs even after one fails; the exit status
# is non-zero when any failed.
set -uo pipefail

conduit="${1:?usage: macos-builtin-checks.sh <conduit> <artifact-dir> <check>...}"
root="${2:?usage: macos-builtin-checks.sh <conduit> <artifact-dir> <check>...}"
shift 2
[ "$#" -gt 0 ] || { echo "FAIL: no checks named" >&2; exit 2; }

mkdir -p "$root"
summary="$root/summary.txt"
: > "$summary"
failed=0
for check in "$@"; do
  name="${check#--}"
  dir="$root/$name"
  mkdir -p "$dir/logs" "$dir/driver"
  started=$(date +%s)
  perl -e 'alarm shift; exec @ARGV or die "exec: $!"' 300 \
    "$conduit" --hidden "$check" \
    --log-dir="$dir/logs" \
    --test-artifact-dir="$dir/driver" \
    --screenshot="$dir/final.png" > "$dir/stdout.txt" 2>&1
  status=$?
  elapsed=$(( $(date +%s) - started ))
  expected=cocoa
  [ "$check" = --clipboard-test ] && expected=offscreen
  backend=ok
  if ! grep -Fq "window backend $expected" "$dir"/logs/*.log 2>/dev/null; then
    backend="missing 'window backend $expected'"
  fi
  if [ "$status" -eq 0 ] && [ "$backend" = ok ]; then
    echo "PASS $check (${elapsed}s)" | tee -a "$summary"
  else
    failed=$((failed + 1))
    echo "FAIL $check exit=$status backend=$backend (${elapsed}s)" | tee -a "$summary"
    echo "::group::$check stdout (last 80 lines)"
    tail -n 80 "$dir/stdout.txt"
    echo "::endgroup::"
    echo "::group::$check log (last 80 lines)"
    tail -n 80 "$dir"/logs/*.log 2>/dev/null
    echo "::endgroup::"
  fi
  grep -hE "window backend|physical pixels per logical|window geometry|window .*: id" "$dir"/logs/*.log 2>/dev/null | head -n 4 | sed 's/^/  /'
done
echo "$failed of $# check(s) failed" | tee -a "$summary"
[ "$failed" -eq 0 ]
