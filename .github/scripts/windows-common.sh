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
