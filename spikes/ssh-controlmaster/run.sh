#!/usr/bin/env bash
# TASK-42 spike (THROWAWAY): two shells and two exec channels over one authenticated
# OpenSSH ControlMaster connection to a disposable sshd container.
#
# Usage: spikes/ssh-controlmaster/run.sh <private-work-dir>
# The work dir receives a throwaway key pair, ssh_config, known_hosts, the transcript and the
# sshd log. Nothing touches ~/.ssh, the user's agent or the user's known_hosts.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="${1:?usage: run.sh <private-work-dir>}"
image=conduit-ssh-spike:latest
container="conduit-ssh-spike-$$"

umask 077
mkdir -p "$work"
chmod 700 "$work"

# The ControlPath must fit sockaddr_un.sun_path (108 bytes on Linux, 104 on macOS), so it lives in
# a short private 0700 directory rather than next to the (long) work dir.
ctl_root="${XDG_RUNTIME_DIR:-/tmp}/conduit-ssh-spike-$$"
mkdir -m 700 "$ctl_root"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$ctl_root"
}
trap cleanup EXIT

docker build -q -t "$image" "$here" >/dev/null

# Throwaway key with a throwaway passphrase, so the master must show a passphrase prompt.
passphrase="spike-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
rm -f "$work/id_ed25519" "$work/id_ed25519.pub" "$work/known_hosts"
ssh-keygen -q -t ed25519 -N "$passphrase" -C conduit-ssh-spike -f "$work/id_ed25519"

docker run -d --name "$container" -p 127.0.0.1::22 \
  -v "$work/id_ed25519.pub:/spike-key.pub:ro" "$image" >/dev/null
port="$(docker port "$container" 22/tcp | head -1 | sed 's/.*://')"
for _ in $(seq 1 50); do
  docker logs "$container" 2>&1 | grep -q 'Server listening' && break
  docker exec "$container" true # bounded readiness poll on the container itself
done

cat >"$work/ssh_config" <<EOF
Host spike
  HostName 127.0.0.1
  Port $port
  User spike
  IdentityFile $work/id_ed25519
  IdentitiesOnly yes
  IdentityAgent none
  UserKnownHostsFile $work/known_hosts
  GlobalKnownHostsFile /dev/null
  StrictHostKeyChecking ask
  UpdateHostKeys no
  ControlPath $ctl_root/%C
  ServerAliveInterval 15
  ServerAliveCountMax 3
EOF

mkdir -p "$here/zig-out" "$here/.zig-cache"
zig build-exe --cache-dir "$here/.zig-cache" --global-cache-dir "$here/.zig-cache" \
  -femit-bin="$here/zig-out/ssh-spike" \
  --dep pty -Mroot="$here/src/main.zig" -Mpty="$repo/src/pty.zig"

SPIKE_CFG="$work/ssh_config" SPIKE_HOST=spike SPIKE_PASSPHRASE="$passphrase" \
  "$here/zig-out/ssh-spike" 2>&1 | tee "$work/transcript.txt"

docker logs "$container" >"$work/sshd.log" 2>&1
echo "== sshd: authentications and sessions for the whole run"
grep -E 'Accepted publickey|Failed|Connection from|Disconnected|session' "$work/sshd.log" \
  | sed -E 's/SHA256:[A-Za-z0-9+\/=]+/SHA256:<fp>/' || true
auths="$(grep -c 'Accepted publickey' "$work/sshd.log" || true)"
conns="$(grep -c 'Connection from' "$work/sshd.log" || true)"
sessions="$(grep -c 'Starting session' "$work/sshd.log" || true)"
echo "accepted authentications: $auths, TCP connections: $conns, sessions: $sessions"
# Exactly one authentication carried all four sessions (2 shells + 2 execs). The second TCP
# connection is step 6's BatchMode exec after `ssh -O exit`: with no master, ControlMaster=no
# falls back to a direct connection, and BatchMode makes it fail without prompting or
# authenticating (it must not add an "Accepted" line).
if [ "$auths" != 1 ] || [ "$sessions" != 4 ] || [ "$conns" != 2 ] ||
  ! grep -q 'SPIKE RESULT: PASS' "$work/transcript.txt"; then
  echo "FAIL" >&2
  exit 1
fi
echo "OK: one authenticated connection carried two shells, two exec channels and the control checks"
