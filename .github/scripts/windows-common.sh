# Shared helpers for the Windows check scripts; source it after setting
# `driver` (conduit-test.exe) and `root` (the run root, a Windows path).

export MSYS_NO_PATHCONV=1

# launch <shell> <conduit-test launch args...>: start an isolated run whose
# interactive shell is <shell> and print its run id.
#
# The id goes through a file, never a command substitution: on Windows the
# app conduit-test starts inherits conduit-test's own stdout handle, so a
# `$(...)` pipe would stay open, and the shell would wait, until the app
# exits. Each id file is left in place because the running app holds it open.
launch() {
  local shell="$1"
  shift
  local id_file
  id_file="$(mktemp "${RUNNER_TEMP:-/tmp}/crun.XXXXXX")"
  # stderr too: the step's own log pipe must not be held open by the app.
  if ! SHELL="$shell" timeout -k 5 120 "$driver" --root="$root" launch "$@" > "$id_file" 2> "$id_file.err"; then
    cat "$id_file.err" >&2
    return 1
  fi
  tr -d '\r\n' < "$id_file"
}

# ct <command...>: one conduit-test command against the current $run.
ct() { timeout -k 5 120 "$driver" --root="$root" --run="$run" "$@"; }

# png_size <file>: WIDTHxHEIGHT from the PNG header.
png_size() { python -c 'import struct,sys; d=open(sys.argv[1],"rb").read(24); print("%dx%d" % struct.unpack(">II", d[16:24]))' "$1"; }

# choice_row <label-prefix>: the id of the first palette choice row whose
# label starts with <label-prefix> in the current run's semantic tree, or
# nothing.
choice_row() {
  local py tree
  py="$(command -v python || command -v python3)"
  tree="$(mktemp "${RUNNER_TEMP:-/tmp}/ctree.XXXXXX")"
  ct --json inspect > "$tree" || return 0
  # Read as UTF-8 from a file: Windows Python decodes a pipe with the ANSI
  # code page, which cannot decode every UTF-8 label.
  "$py" -c '
import json, sys
prefix = sys.argv[2]
with open(sys.argv[1], encoding="utf-8") as tree:
    reply = json.load(tree)
# `--json` prints the raw JSON-RPC reply; the tree is its result.
for element in reply.get("result", reply).get("elements", []):
    if element.get("id", "").startswith("palette.choice.") and element.get("label", "").startswith(prefix):
        print(element["id"])
        break
' "$tree" "$1"
}

# open_profile_tab <profile>: open a new tab running the built-in shell
# profile <profile> (TASK-46) by clicking its row in the palette's New tab
# with profile chooser; that tab is then the active terminal. The default
# local shell is the first detected profile (pwsh on the runner), so a check
# that drives another shell must ask for it explicitly.
open_profile_tab() {
  local row
  ct click sidebar.palette > /dev/null || return 1
  ct wait-for element palette.query focused true 10000 > /dev/null || return 1
  ct type "New tab with profile" > /dev/null || return 1
  ct key ENTER > /dev/null || return 1
  row="$(choice_row "$1  ")"
  if [ -z "$row" ]; then
    echo "no '$1' row in New tab with profile" >&2
    ct key ESCAPE > /dev/null
    return 1
  fi
  ct click "$row" > /dev/null
}
