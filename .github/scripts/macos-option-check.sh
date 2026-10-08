#!/usr/bin/env bash
# TASK-48 AC3 with real keystrokes: what the child receives for Option+x.
#
# Usage: macos-option-check.sh <conduit> <conduit-test> <artifact-dir>
#
# Conduit runs in a visible window with a child that prints every byte it
# reads as [hh]. Keys are posted through the HID event tap by
# macos-keys.swift, so they pass through AppKit's text system like a real
# keyboard's:
#
#   plain x                          -> [78]            (injection works at all)
#   Option+x, macos.option_as_alt=false -> [e2][89][88] (the composed ≈, once)
#   Option+x, macos.option_as_alt=true  -> [1b][78]     (Alt: ESC x)
#
# The second setting is written to the run's isolated settings file and picked
# up by the hot reload, so the same window proves both.
set -euo pipefail

conduit="${1:?usage: macos-option-check.sh <conduit> <conduit-test> <artifact-dir>}"
driver="${2:?usage}"
out="${3:?usage}"
mkdir -p "$out"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(mktemp -d "${TMPDIR:-/tmp}/copt.XXXXXX")"
swiftc -O -o "$root/keys" "$here/macos-keys.swift"

run="$("$driver" --root="$root" launch --conduit="$conduit" --visible --width=640 --height=360 --scale=1 \
  --command="stty raw -echo; printf 'READY\\r\\n'; while :; do c=\$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \\n'); printf '[%s]' \"\$c\"; done")"
ct() { "$driver" --root="$root" --run="$run" "$@"; }
cleanup() {
  ct logs 1048576 > "$out/app.log" 2>&1 || true
  ct terminal-text > "$out/terminal.txt" 2>&1 || true
  ct quit > /dev/null 2>&1 || true
}
trap cleanup EXIT
ct wait-for terminal-text READY 10000 > /dev/null
pid="$(pgrep -n -f "$conduit")"

"$root/keys" "$pid" plain
ct wait-for terminal-text "[78]" 5000 > /dev/null || {
  echo "FAIL plain x never reached the child: the runner did not deliver posted keystrokes" >&2
  exit 1
}
echo "PASS posted plain x reached the child as [78]"

# Every byte the child has read so far, in order.
bytes() { ct terminal-text | grep -o '\[[0-9a-f][0-9a-f]\]' | tr -d '\n'; }

"$root/keys" "$pid" option
ct wait-for terminal-text "[e2][89][88]" 5000 > /dev/null || true
seen="$(bytes)"
if [ "$seen" = "[78][e2][89][88]" ]; then
  echo "PASS Option+x with macos.option_as_alt=false reached the child once, as ≈ ([e2][89][88]), with no ESC and no x"
else
  echo "FAIL Option+x with option_as_alt=false: the child read $seen after [78], expected [e2][89][88] alone" >&2
  exit 1
fi

config_dir="$root/$run/home/Library/Application Support/conduit"
mkdir -p "$config_dir"
printf 'macos.option_as_alt = true\n' > "$config_dir/config"
applied=no
for _ in $(seq 1 100); do
  ct logs 1048576 > "$root/reload.log"
  if grep -q "macOS Option as Alt: both" "$root/reload.log"; then applied=yes; break; fi
  # The watcher polls the settings file once a second; poll its log, do not sleep blind.
  perl -e 'select(undef, undef, undef, 0.1)'
done
[ "$applied" = yes ] || { echo "FAIL the settings reload never applied option_as_alt" >&2; exit 1; }

"$root/keys" "$pid" option
ct wait-for terminal-text "[1b][78]" 5000 > /dev/null || true
seen="$(bytes)"
if [ "$seen" = "[78][e2][89][88][1b][78]" ]; then
  echo "PASS Option+x with macos.option_as_alt=true reached the child once, as ESC x ([1b][78])"
else
  echo "FAIL Option+x with option_as_alt=true: the child's bytes are $seen, expected ...[1b][78] alone" >&2
  exit 1
fi
