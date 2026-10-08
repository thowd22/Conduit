#!/usr/bin/env bash
# TASK-48 AC4: a configured family installed in a macOS system or per-user font
# location is discovered and loaded.
#
# Usage: macos-font-check.sh <conduit> <artifact-dir> <family>=<expected-dir>...
#
# For each pair the family must already be installed (the workflow installs
# DejaVu into ~/Library/Fonts; Menlo ships in /System/Library/Fonts). The check
# first proves where the file lives, then runs Conduit with `--font=<family>`
# against the real HOME, so discovery walks the real system and per-user
# directories, and requires the log line the app writes once the face is the
# one drawing ("drawing with <family>"). A frame is kept for inspection. A
# family that is not installed anywhere is run last as a negative control: it
# must fall back to the bundled face rather than claim to have loaded.
set -euo pipefail

conduit="${1:?usage: macos-font-check.sh <conduit> <artifact-dir> <family>=<dir>...}"
out="${2:?usage}"
shift 2
mkdir -p "$out"
alarm() { perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$@"; }

run_family() {
  local family="$1" tag="$2"
  local log="$out/$tag.log"
  rm -f "$log"
  alarm 120 "$conduit" --hidden --width=640 --height=200 --scale=2 --font="$family" \
    --command="printf 'family: $family  0O 1lI {}[] => !=\\n'; sleep 3" \
    --screenshot="$out/$tag.png" --log-file="$log" > /dev/null 2>&1 || true
}

for pair in "$@"; do
  family="${pair%%=*}"
  dir="${pair#*=}"
  tag="$(printf '%s' "$family" | tr -c 'A-Za-z0-9' '-')"
  # Where the family's files are, by the name table, before Conduit looks.
  found="$(fc-list 2>/dev/null | grep -F ": $family" | head -n 1 || true)"
  if [ -z "$found" ]; then
    found="$(ls "$dir" | grep -i "$(printf '%s' "$family" | tr -d ' ' | cut -c1-6)" | head -n 3 | tr '\n' ' ')"
  fi
  [ -n "$found" ] || { echo "FAIL $family: nothing in $dir looks like it" >&2; exit 1; }
  echo "INFO $family in $dir: $found"
  run_family "$family" "$tag"
  line="$(grep -E "drawing with $family," "$out/$tag.log" | tail -n 1 || true)"
  if [ -n "$line" ]; then
    echo "PASS $family: ${line#*: }"
  else
    echo "FAIL $family was not loaded; the log says:" >&2
    grep -E "font|drawing with" "$out/$tag.log" | tail -n 20 >&2 || true
    exit 1
  fi
done

control="Conduit Missing Family"
run_family "$control" control
if grep -qE "drawing with $control," "$out/control.log"; then
  echo "FAIL the negative control claims to draw with '$control'" >&2
  exit 1
fi
echo "PASS negative control: '$control' fell back ($(grep -E 'drawing with' "$out/control.log" | tail -n 1 | sed 's/.*drawing with/drawing with/'))"
