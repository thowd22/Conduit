---
id: decision-8
title: SSH execution context architecture
date: '2026-10-07 20:07'
status: accepted
---
## Context

CONDUIT.md P7 and AGENTS.md invariant 5 say everything spawns through the workspace's
`ExecutionContext` (Local, SSH, WSL); §3 says an SSH workspace's tabs, panes, scratchpad, agents and
backlog view all operate against the remote host; §9 "Remote inheritance" says the scratchpad never
runs `ssh server` itself but spawns inside the context near the invoking session's cwd; §12 leaves
"how do tabs, panes and the scratchpad share one connection?" to this spike. TASK-43 needs a single
authentication for all tabs and panes, `~/.ssh/config` honoured, password/passphrase/host-key
prompts in terminal-style UI, loss detection and reconnect, and an sshd-container integration test.
TASK-45 needs a remote scratchpad and OSC 7 cwd inheritance; TASK-61 needs remote agents with their
side channels (decision-7 rule 5); TASK-62 is adding bounded file read, directory listing, change
observation and command run to `ExecutionContext`.

What exists today (`src/workspace.zig`, `src/pty.zig`): `ExecutionContext` is a type-erased owner
with `spawn(pty.SpawnRequest) -> pty.Pty` and `kind()`; `Pty` offers write, resize, kill,
takeBytes, state, waitReadable and destroy; POSIX and ConPTY backends exist. TASK-73's rule is
"Local inherits; remote contexts supply their own", and `ChildSpec` currently gives `.ssh` children
only the curated identity-plus-fallback environment.

Evidence gathered by TASK-42:

- **Prototype** (`spikes/ssh-controlmaster/`, verified on Linux, OpenSSH_10.2p1 client against an
  OpenSSH_9.6p1 sshd in a throwaway container): a driver built on Conduit's real `pty.spawn` started
  a dedicated `ssh -M -N` master in its own PTY; OpenSSH's host-key prompt
  (`continue connecting (yes/no/[fingerprint])?`) and key passphrase prompt appeared in that PTY and
  were answered by typing; `ssh -O check` reported `Master running`; two `ssh -tt
  -o ControlMaster=no` shells each logged `mux_client_request_session: master session id: 2`, got
  distinct `/dev/pts/0` and `/dev/pts/1`, independent shell state and independent sizes, and a
  `Pty.resize` crossed the mux (`stty size` → `50 132`); two BatchMode exec channels (`cat`, `ls`)
  rode the same master. sshd logged exactly one `Accepted publickey`, one source port and four
  sessions. Hanging up one shell left the other alive; `ssh -O exit` made the surviving client exit
  255; and with no master, `ControlMaster=no` silently **fell back to a direct TCP connection**
  (stopped only by BatchMode). The master's `-v` output logs each exec'd command
  (`Sending command: …`). The scratchpad path (105 bytes) plus `%C` (40) exceeds `sun_path`.
- **Read from documentation, not run here**: Win32-OpenSSH has no ControlMaster support
  (PowerShell/Win32-OpenSSH issue #405, open since 2016, `muxclient socket(): Unknown error`);
  Windows ships OpenSSH from Windows 10 1809 / Server 2019 and its server supports only `password`
  and `publickey` authentication. libssh2 1.11.1 is BSD-licensed, offers password, public-key,
  host-based and keyboard-interactive auth, shell/exec/subsystem channels and SFTP v3 over OpenSSL,
  libgcrypt, mbedTLS, wolfSSL or WinCNG; a Zig package exists (`allyourcodebase/libssh2`, defaults
  to WinCNG on Windows and OpenSSL elsewhere). libssh is LGPL-2.1, adds gssapi-with-mic, and uses
  OpenSSL, mbedTLS or gcrypt. Neither is in Conduit's or Ghostty's dependency tree today. macOS ships
  the OpenSSH client with ControlMaster; it was not run here.

## Decision

**The SSH transport is the system OpenSSH client, started by the SSH `ExecutionContext` through
Conduit's own local PTY backend. On Linux and macOS one ControlMaster per SSH workspace carries every
tab, pane, scratchpad, agent and exec channel. On Windows, whose OpenSSH has no multiplexing, each
session is its own `ssh.exe` and single authentication relies on the Windows ssh-agent service.**
Conduit links no SSH library and never handles a credential: every prompt is OpenSSH's own,
shown in a Conduit terminal, answered by the person typing.

An SSH context is therefore "a Local spawn of `ssh`": its `spawn` builds a local `SpawnRequest`
whose argv is `ssh` and whose remote command carries the target argv, cwd and environment, and
returns the `Pty` from `pty.spawn` unchanged. Everything above `workspace` (sessions, grids,
resize, pumping, the read thread) is untouched.

| | Linux | macOS | Windows |
|---|---|---|---|
| Client | `ssh` from the inherited `PATH` | `/usr/bin/ssh` (Apple OpenSSH) | `%SystemRoot%\System32\OpenSSH\ssh.exe` or `ssh.exe` on `PATH` (Win10 1809+) |
| PTY for the client | POSIX backend | POSIX backend | ConPTY (TASK-16) |
| Sharing | one ControlMaster per workspace | one ControlMaster per workspace | none: one `ssh.exe` (TCP connection + auth) per session and per exec |
| Control socket dir | `$XDG_RUNTIME_DIR/conduit/ssh`, else `/tmp/conduit-<uid>/ssh` | `$TMPDIR/conduit-ssh` (per-user `/var/folders/…/T/`) | n/a |
| `sun_path` budget | 108 bytes; refuse > 100 | 104 bytes; refuse > 96 | n/a |
| Agent | inherited `SSH_AUTH_SOCK` | inherited `SSH_AUTH_SOCK` (launchd agent, Keychain via `UseKeychain`) | `ssh-agent` service named pipe |
| Single authentication | always | always | only when auth is non-interactive (agent/unencrypted key); password, passphrase-without-agent and 2FA hosts prompt once per session |
| Verified | prototype | documentation only | documentation only |

Windows is the one place the design is weaker than the product promise (TASK-43 AC1). The
decision accepts that for the first SSH release and records two upgrade paths for a later task,
each needing its own decision: an opt-in "SSH via WSL" transport that runs this exact Linux design
inside a WSL distribution (`wsl.exe -d <distro> -- ssh …`, the distro's own `~/.ssh`), and a
Windows-only embedded libssh2 transport (WinCNG backend, no new system dependency) behind the same
seam. The second would put keyboard-interactive answers in Conduit's memory and is why it is not
the default. **This trade-off is the open point for the user** before the decision is accepted.

### Processes

- **Master (Linux/macOS).** Each SSH workspace owns one connection session (a new session kind,
  never the scratchpad, never addressable by agents or the control API) running
  `ssh -M -N -o ControlMaster=yes -o ControlPersist=no -o ControlPath=<dir>/%C
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -- <destination>` in its own PTY. Conduit owns
  this process: it is not daemonised (no `ControlPersist`), so closing the workspace or Conduit
  ends it, and no orphan master outlives Conduit. Conduit's `ControlPath`/`ControlMaster` options
  override the user's for this connection so the lifecycle is Conduit's; every other option comes
  from the user's `~/.ssh/config` (aliases, `ProxyJump`, `Match`, `IdentityFile`, certificates,
  `Include`).
- **Sessions.** Tabs, panes, the scratchpad, `vi` file-reference tabs and agent TUIs run
  `ssh -tt -o ControlMaster=no -o ControlPath=<dir>/%C -- <destination> <remote command>`. They never
  become masters. Because a client with no live master falls back to a direct connection, a session
  is spawned only while the workspace is `connected` (the spawn worker waits, bounded and
  cancellable, on the connection state); the remaining race shows OpenSSH's prompt in that tab
  rather than hiding anything.
- **Exec channels.** Non-interactive work (`run`, file reads, listings, watching, the remote
  `$SHELL`/hostname probe, shell-integration install) runs
  `ssh -T -o BatchMode=yes -o ControlMaster=no -o ControlPath=… -- <destination> <command>` with
  pipes rather than a PTY, so stdout and stderr stay separate and binary-clean. `BatchMode=yes` means
  an exec can never prompt where nobody can see it; with no master it fails at once (exit 255).
- **Control commands.** `ssh -O check` (readiness and liveness) and `ssh -O exit` (shutdown), also
  with `BatchMode=yes`.
- **Remote command.** Built by one quoting function (unit-tested): `exec /bin/sh -c '<script>'`, where
  the script is `cd -- '<cwd>' 2>/dev/null || cd; exec env TERM_PROGRAM=conduit COLORTERM=truecolor
  <integration variables> '<argv0>' '<argv1>' …`. Every value is single-quoted with `'\''`
  escaping, so a cwd from OSC 7 or a file reference (untrusted terminal data) is only ever a quoted
  argument. Wrapping in `/bin/sh -c` makes it independent of the remote login shell (bash, zsh,
  fish, tcsh). `TERM` reaches the remote through the PTY request from the local client's `TERM`
  (`xterm-256color`), so it needs no `AcceptEnv`. Remote hosts must provide a POSIX `/bin/sh`;
  Windows remote hosts are out of scope until TASK-46 adds profiles.
- **Environment.** The local `ssh` process is a Local child and inherits Conduit's environment
  (TASK-73), because it needs `SSH_AUTH_SOCK`, `SSH_ASKPASS`/`DISPLAY` when the user configured
  them, `KRB5CCNAME` and the user's proxies. The curated identity set TASK-73 reserves for `.ssh`
  is the **remote** overlay rendered into `env …` above, not the local client's environment.

## Authentication and host-key UX

- **Where prompts appear.** When an SSH workspace connects, its first tab slot shows the connection
  session's terminal (`ssh <destination> ─ connecting`), focused. Every OpenSSH prompt appears there
  verbatim: unknown host key with fingerprint, key passphrase, password, keyboard-interactive and
  2FA/OTP challenges, FIDO "confirm user presence", PKCS#11 PIN, and the `REMOTE HOST
  IDENTIFICATION HAS CHANGED` refusal. The person types into it like any terminal; Conduit does
  not parse, detect, store or log prompts or answers (terminal input and contents are never logged
  above debug). TASK-43 AC3 is met by this terminal, which is a normal Conduit terminal view.
- **Readiness.** The workspace is `connected` when `ssh -O check` exits 0 (`Master running`). It is
  polled while connecting (on master output and on a short cadence; a condition check, not a
  timeout guess) and is `failed` if the master exits first. On `connected` the connection terminal
  is hidden (the session keeps running) and the first tab's shell is spawned. Shell-integration
  marks are not used for readiness: they arrive only after a shell starts and are absent when
  integration is off.
- **Host keys.** Conduit never passes `StrictHostKeyChecking=no` or `accept-new`, never overrides
  `UserKnownHostsFile`, and never auto-answers. The user's config decides; the default `ask`
  produces the prompt above. A changed key makes OpenSSH refuse; the connection session exits 255
  with its output still visible and a clickable `reconnect` control. Conduit offers no "remove the
  old key" action; the user runs `ssh-keygen -R` themselves.
- **No credential plumbing.** No `sshpass`, no passwords in argv or environment, no Conduit-set
  `SSH_ASKPASS`/`SSH_ASKPASS_REQUIRE` (a user's own setting is inherited and honoured), no agent
  forwarding unless the user's config enables it. Saved connection profiles (TASK-44) hold a
  destination and options only.
- **Windows.** Each session's own terminal shows its `ssh.exe` prompts; there is no separate
  connection terminal. Readiness of a session is its first output; the workspace is `connected`
  once any session or a BatchMode probe has authenticated.

## Connection reuse and reconnect

- **One master per SSH workspace** carries every tab, pane, the scratchpad, agent TUIs and all exec
  channels. Two SSH workspaces to the same host get two masters (`%C` includes nothing
  workspace-specific, so the path is `<dir>/<workspace-key>-%C`). The scratchpad is a remote shell
  started over the master in the background when the workspace connects (§9), hidden like a local
  one.
- **sshd `MaxSessions`** (default 10 per connection) bounds concurrent channels. Conduit counts
  live channels per master, runs exec work through a small bounded queue (at most two concurrent
  short execs plus one long-lived watch channel), and reports an `open failed: administratively
  prohibited` refusal as "the server limits sessions per connection (MaxSessions)" in the affected
  tab rather than opening a second, separately authenticated connection.
- **Loss detection.** The master exits (network drop after `ServerAliveInterval` ×
  `ServerAliveCountMax` = 45 s, server shutdown, sleep/resume) → the workspace is `lost`, shown in
  the sidebar. Each session's client then exits 255. A session classifies its end as
  **disconnected** when its client exited 255 and the master is gone (`-O check` fails or the
  master session has exited) and Conduit did not hang it up itself; any other end is **exited**
  with the remote status. A disconnected session keeps its grid and scrollback and shows
  `── connection lost ──` with a clickable `reconnect`.
- **Reconnect** is a user gesture (sidebar control, palette `workspace.reconnect`), never an
  automatic loop, because it can prompt. It starts a new master in the connection terminal (shown
  again for any prompts), and once connected respawns every disconnected session in place, under
  its existing session id, at its last OSC 7 cwd (the same atomic replacement as
  `scratchpad.restart`). Remote processes do not survive a lost connection; persistence across
  drops (tmux, a remote multiplexer) is out of scope. The scratchpad is restarted the same way, so
  TASK-45 AC3's "restored where possible" means a fresh shell in its last directory.
- **Close.** Closing an SSH workspace hangs up its sessions, runs `ssh -O exit`, then ends and
  destroys the master session and removes its socket; teardown order stays sessions before
  context.

## Remote cwd and shell integration

- Remote cwd comes from OSC 7 emitted by Conduit's own shell integration running on the remote
  shell. For SSH workspaces the OSC 7 host check accepts the remote host's name (learned with one
  exec at connect) instead of the local one, and the path is a remote path that is never resolved
  or opened locally. New tabs, panes and the scratchpad pass it as the quoted remote `cd` target
  (TASK-45 AC2), falling back to the remote home.
- **Install:** after `connected`, one exec writes the embedded MIT scripts to
  `${XDG_CACHE_HOME:-$HOME/.cache}/conduit/shell-integration/<content-hash>/` (write to a temp name,
  then `mv`, so concurrent Conduits never see a partial file), and reads the remote `$SHELL`
  (must be an absolute path). Spawns then use the same per-shell handshake as Local (bash
  `--posix` + `ENV`, zsh `ZDOTDIR`, fish `XDG_DATA_DIRS`) through the `env` overlay. A setting
  `ssh.shell_integration = auto | off` controls this; `off` writes nothing remotely and yields no
  remote cwd or prompt marks (tabs then start in the workspace's remote directory).
- File-reference clicks in an SSH workspace open `vi +<line> -- <path>` remotely (decision-5's argv
  becomes the quoted remote command); the path is resolved against the remote cwd without touching
  the local filesystem.

## Remote file reads, commands and agents

- **`run(argv, cwd, limits)`**: an exec channel as above, stdout/stderr captured up to byte limits,
  a timeout that kills the local client, and the remote exit status. Exit 255 with a dead master is
  `error.Disconnected`.
- **`readFile(path, max_bytes)`, `listDir(path)`, `stat`**: implemented with `run` over a small
  POSIX-sh helper (`conduit-remote.sh`) installed next to the shell integration, emitting
  length-prefixed records (`head -c max+1` to detect truncation; a portable listing without GNU
  `find -printf`, since macOS and BSD remotes lack it). Paths are quoted arguments.
- **`watch(path)`**: one long-lived exec running the helper's watch loop (`inotifywait` when present,
  otherwise an mtime/size poll every 2 s), streaming change records; one per workspace, counted
  against `MaxSessions`.
- **Agents (TASK-61, decision-7 rule 5)**: the harness TUI is an ordinary remote session. Its
  structured side channel uses, in order: a second exec channel for stdio protocols; a remote JSONL
  sink that hooks/extensions append to, tailed over an exec channel (works even where
  `AllowStreamLocalForwarding` is off); optionally a reverse Unix-socket forward added to the master
  with `ssh -O forward -R <remote sock>:<local control sock>`. Hooks still only report; nothing
  remote can issue commands to Conduit.
- **Windows**: every `run`/read/list is its own `ssh.exe` connection and authentication with
  `BatchMode=yes`, so it works only with agent or unencrypted-key auth and costs a full handshake;
  the backlog view should prefer the single long-lived watch channel and batch reads.

## Security

- Control directory created 0700, owner and type checked with `lstat` (not a symlink, owned by
  this uid, mode exactly 0700) before use; socket names are `%C` hashes, so no hostnames or users
  appear in file names; the full path is length-checked against `sun_path`; a stale socket whose
  `-O check` fails is removed before a new master binds. Anyone with this uid can use the socket,
  the same trust boundary as `ssh-agent`.
- The master and sessions never run with `-v` by default (OpenSSH's verbose master logs every
  remote command). Master and session PTY output is terminal content: debug level at most. Exec
  output that is file content is never logged.
- Conduit persists nothing SSH-related except non-secret profile data (TASK-44); `known_hosts`
  changes are OpenSSH's, made only after the user typed `yes`.
- Remote writes are limited to the content-addressed integration/helper directory, disabled by
  `ssh.shell_integration = off`, and documented.
- The control API and test driver cannot address the connection session, consistent with the
  scratchpad rule; TASK-60 must not expose `ssh -O` operations.

## Consequences

- **TASK-43** implements `SshExecutionContext` in `workspace` (or a new `ssh` module below it) as
  above, plus the connection session kind and sidebar states connecting / connected / lost / failed.
  `ChildSpec` splits into the local client's environment (inherited) and the remote overlay
  (curated). The integration test reuses `spikes/ssh-controlmaster/`'s throwaway-key sshd container;
  because OpenSSH reads `~/.ssh` from the passwd database rather than `$HOME` (OpenSSH behaviour, not
  re-run here), `conduit-test`'s isolated HOME does not isolate ssh, so the context needs a
  test-only config-file override (`ssh -F <file>`) and tests must never read the user's `~/.ssh`.
  macOS and Windows behaviour need their CI runners.
- **Interface for TASK-43 against TASK-62's extension:** keep `spawn` returning a `pty.Pty`, but
  make the request context-neutral (argv, context-path cwd, environment overlay, size) and let each
  context build the local `SpawnRequest`; add a connection state with a wake hook (Local: always
  ready); make `readFile`/`listDir`/`watch`/`run` asynchronous and off the render thread, bounded
  (`max_bytes`, timeout, cancel), with `error.Disconnected` and `error.Unsupported` in their error
  sets and paths typed as context paths never resolved locally. `run` needs a pipe-based process
  spawn (stdout/stderr separate, exit status) beside `pty.spawn`; that primitive is a shared
  contract TASK-62 and TASK-43 must name once, owned by `pty` (or a sibling process module), not
  invented twice.
- **TASK-44** lists non-wildcard `Host` entries from `~/.ssh/config` (following `Include`), resolves
  display details with `ssh -G <alias>`, and stores profiles without secrets.
- **TASK-45**: scratchpad and cwd inheritance as specified; OSC 7 host validation becomes
  context-aware.
- **TASK-47**: WSL spawns through `wsl.exe -d <distro> --cd <path> -- <argv>` under ConPTY and needs
  no SSH; the opt-in "SSH via WSL" transport above is a later follow-up, not part of TASK-47.
- **TASK-61**: transports as listed; a remote JSONL sink is the baseline.
- No new system dependency: OpenSSH is already a prerequisite of the use case; documentation must
  state it (and that Windows needs the optional OpenSSH Client feature).

## Alternatives considered

- **Embedded libssh2 everywhere.** Permissive licence and a Zig package exist, but on Linux/macOS it
  needs OpenSSL (a new system dependency) or a vendored mbedTLS; it does not read `~/.ssh/config`
  (`Include`, `Match`, `ProxyJump`, `ProxyCommand`, certificates, `CanonicalizeHostname`), lacks
  GSSAPI, and makes Conduit render password/2FA prompts and implement known_hosts UX itself, so
  credentials pass through Conduit. Rejected as the default; kept as the Windows upgrade path.
- **Embedded libssh.** Better config and GSSAPI coverage, but LGPL-2.1 static linking into an MIT
  binary carries relinking obligations, and the same credential-handling and dependency costs.
  Rejected.
- **Hybrid: system `ssh` for shells, a library for files and commands.** Two connections and two
  authentications (2FA twice), two host-key paths. Exec channels over the master already cover
  files and commands. Rejected.
- **`ControlMaster=auto` in the first tab with `ControlPersist`.** No extra session, but the master
  daemonises with a detached TTY, so later prompts (reconnect, `ProxyJump` hops) have nowhere to
  appear, closing that tab has surprising effects, and orphan masters outlive Conduit. Rejected.
- **One `ssh` per session everywhere.** Simple and portable, but re-prompts password/2FA users per
  tab and doubles handshakes. Used only on Windows, by necessity.
- **A remote Conduit multiplexer daemon** (VS Code server style) over one `ssh` stdio stream. Would
  give Windows multiplexing and session survival across drops, but needs a per-architecture remote
  binary deployment. Deferred; out of scope for M5.
