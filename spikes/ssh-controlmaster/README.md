# TASK-42 spike: SSH over one OpenSSH ControlMaster connection (THROWAWAY)

Proof for `decision-8` (SSH execution context architecture), acceptance criterion 4 of TASK-42:
two interactive shells, plus exec channels and control checks, over **one authenticated
connection**. Nothing here is part of the real build.

The driver (`src/main.zig`) imports Conduit's real `src/pty.zig` and starts every `ssh` process
with `pty.spawn` and a complete `SpawnRequest`, exactly as `LocalExecutionContext.spawn` does. That
is the point of the design: an SSH context's sessions are Local spawns of the system `ssh` client
that attach to a per-workspace master.

## Run it

Needs Docker (pulls `ubuntu:24.04` and installs `openssh-server` into a throwaway image), the
system OpenSSH client and Zig 0.16.0.

```sh
spikes/ssh-controlmaster/run.sh "$SCRATCH/ssh-spike"   # any private directory
```

`run.sh`:

1. builds `conduit-ssh-spike:latest` (key-only sshd, `LogLevel VERBOSE`, a `spike` user with
   `~/project/{notes.txt,alpha,beta}`);
2. generates a throwaway ed25519 key **with a throwaway random passphrase** in the work dir (never
   `~/.ssh`), and bind-mounts only the public half into the container;
3. writes a private `ssh_config` (`IdentitiesOnly`, `IdentityAgent none`, a private
   `UserKnownHostsFile`, `StrictHostKeyChecking ask`, `ControlPath <0700 dir>/%C`,
   `ServerAliveInterval 15`), so neither the user's agent nor their known_hosts is involved;
4. compiles the driver with
   `zig build-exe --dep pty -Mroot=src/main.zig -Mpty=../../src/pty.zig`;
5. runs it, saves `transcript.txt` and `sshd.log` in the work dir, counts authentications, and
   removes the container and the control directory on exit.

The control socket directory is `$XDG_RUNTIME_DIR/conduit-ssh-spike-<pid>` (mode 0700), **not**
the work dir: the scratchpad path is 105 bytes before `%C` adds 40, past `sun_path`'s 108-byte limit
(104 on macOS). Conduit has to choose a short private directory and check the length.

## What the driver does

| Step | Command (all via `pty.spawn`) | Proves |
|---|---|---|
| 1 | `ssh -F cfg -v -M -N -o ControlPersist=no spike` | OpenSSH's own host-key and passphrase prompts appear in the master's PTY; the driver types `yes` and the passphrase as a person would. Conduit parses nothing it then trusts. |
| 2 | `ssh -F cfg -O check spike`, repeated until exit 0 | Readiness comes from the control socket, not a timer. |
| 3 | 2 × `ssh -F cfg -tt -o ControlMaster=no spike` | Two independent remote shells (distinct `/dev/pts/N`, PIDs, variables), each with its own initial size; `Pty.resize` on one becomes a remote window-change (`stty size` → `50 132`). |
| 4 | `ssh ... -o BatchMode=yes spike 'cat project/notes.txt'` and `'ls -1 project'` | Exec channels (no TTY) ride the same master: the read/list path for remote files and commands. |
| 5 | `Pty.kill(.hangup)` on shell A | One session ends (`ssh` exits 255); the other keeps working. |
| 6 | `ssh -O exit`, then a BatchMode exec | The remaining shell's `ssh` exits **255** (connection lost, as opposed to the remote shell's own status); with no master a BatchMode exec fails at once rather than prompting. |

## Transcript shape (from a passing run; no key material)

```
== 2. readiness: poll ssh -O check (no timer-based guess)
  [check] Master running (pid=…)
  master ready after 3 check(s)
== 4. exec channels over the master (BatchMode=yes, no TTY)
  [exec-cat] SPIKE_CAT_OK
  [exec-ls] SPIKE_LS: alpha beta notes.txt
== 5. hang up shell A; shell B survives
  shell-a ended: .{ .code = 255 }
== 6. ssh -O exit: remaining shell sees the connection drop
  shell-b ended: .{ .code = 255 }
  master ended: .{ .code = 255 }
  BatchMode exec with no master: exit 255 (no prompt, no silent re-auth)
  [master] Are you sure you want to continue connecting (yes/no/[fingerprint])? yes
  [master] Warning: Permanently added '[127.0.0.1]:…' (ED25519) to the list of known hosts.
  [master] Enter passphrase for key '…':
  [master] Authenticated to 127.0.0.1 ([127.0.0.1]:…) using "publickey".
  [master] debug1: setting up multiplex master socket
  [master] debug1: multiplexing control connection          (once per check/shell/exec)
  [master] debug1: Sending command: cat project/notes.txt && echo SPIKE_CAT_OK
  [shell-a] debug2: mux_client_hello_exchange: master version 4
  [shell-a] debug1: mux_client_request_session: master session id: 2
  [shell-a] SPIKE_A tty=/dev/pts/0 pid=22 size=24 80
  [shell-b] SPIKE_B tty=/dev/pts/1 pid=23 size=30 100
  [shell-b] SPIKE_B_MARK=unset                               (A exported SPIKE_MARK; B is independent)
  [shell-b] SPIKE_B_RESIZED=50x132
  [shell-b] SPIKE_B_ALIVE                                    (after A was hung up)
SPIKE RESULT: PASS
== sshd: authentications and sessions for the whole run
Connection from 172.17.0.1 port 47264 …
Accepted publickey for spike from 172.17.0.1 port 47264 ssh2: ED25519 SHA256:<fp>
Starting session: shell on pts/0 … port 47264 id 0
Starting session: shell on pts/1 … port 47264 id 1
Starting session: command … port 47264 id 2   (cat)
Starting session: command … port 47264 id 2   (ls)
Disconnected from user spike 172.17.0.1 port 47264
Connection from 172.17.0.1 port 47278 …        (step 6: no master, BatchMode, never authenticated)
accepted authentications: 1, TCP connections: 2, sessions: 4
```

One `Accepted publickey`, one source port, four sessions on it. The second TCP connection is the
deliberate step-6 probe: `ControlMaster=no` with no live master **falls back to a direct
connection**. That is why the decision requires Conduit to check the master before every spawn
and to run every non-interactive command with `BatchMode=yes`.

Findings that fed the decision:

- `ssh -v` on the master logs every exec'd remote command (`Sending command: …`). Conduit must not
  run the master verbose by default, and master PTY output is terminal content: never logged above
  debug.
- Hanging up a mux client and losing the connection both exit 255; the session can tell them
  apart because Conduit knows when it hung up, and `ssh -O check` says whether the master is gone.

Tested on Linux only (OpenSSH_10.2p1 client, OpenSSH_9.6p1 server). macOS uses the same OpenSSH
client mechanism but was not run; Windows OpenSSH has no ControlMaster (see the decision).
