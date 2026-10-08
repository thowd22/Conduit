---
id: decision-13
title: >-
  Windows control transport over named pipes and Claude Code hooks without
  bin-sh
date: '2026-10-08 19:41'
status: accepted
---
## Context

TASK-82. The control API (TASK-60) and the single-instance endpoint (TASK-66) were Unix sockets
inside a private 0700 runtime directory, so neither started on Windows (`runtimeDirectory`
returned null there), `conduit control agent.event` had nothing to talk to, and `conduit <dir>`
always started a new window. Independently, the Claude Code adapter registered every hook as
`/bin/sh '<sink>/hook.sh' <Hook>`, which a Windows machine cannot run, so a launched Claude Code
reported nothing structured on Windows: no state, no tool uses, no permission requests in the
agent view.

The test driver (TASK-21) already had a protected Windows named-pipe seam in `platform`:
`CreateNamedPipeW` with an SDDL descriptor that grants only the current logon SID read and write
(`D:P(A;;GRGW;;;<logon SID>)`), `PIPE_REJECT_REMOTE_CLIENTS`, `FILE_FLAG_FIRST_PIPE_INSTANCE`, and
overlapped IO cancelled through a stop event. It serves one client at a time; the control server
serves up to 32 concurrent clients with reply deadlines.

## Decision

**Transport.** `platform.LocalSocketListener` is the control server's listener on every platform:
an AF_UNIX socket on Linux and macOS (unchanged), and on Windows a multi-instance named pipe built
from the driver's seam. Every instance carries the driver pipe's descriptor and rejects remote
clients; the first instance is created with `FILE_FLAG_FIRST_PIPE_INSTANCE`, so a name another
process already holds is refused (`EndpointOccupied`) and nobody can pre-create the endpoint. One
instance always waits: `accept` hands the connected instance to its connection thread and creates
the next before returning. Connections are `platform.LocalStream` (overlapped read and write with
a per-connection stop event). `DriverClient.connect` waits briefly (`WaitNamedPipeW`) when every
instance is momentarily busy. Token scoping, framing, limits and the scratchpad refusal are
unchanged: the server code is the same on every platform.

**Names.** On Windows `control.runtimeDirectory` is a pipe-name prefix,
`\\.\pipe\conduit-<user SID>`, with `-x<16 hex>` (a hash of `XDG_RUNTIME_DIR`) appended when that
variable is set, so `conduit-test launch` and `--control-test` runs, which set it, get pipes of
their own exactly as they get private socket directories elsewhere. The run endpoint is
`<prefix>-r-<8 hex>` and the instance endpoint `<prefix>-instance`; `CONDUIT_CONTROL_ENDPOINT`
carries the pipe name. The instance token file is `%LOCALAPPDATA%\conduit\instance.token`, or
`$XDG_STATE_HOME\conduit\instance.token` when that is set (again for isolated runs).

**Claude Code hooks on Windows.** No `/bin/sh` is involved. Every hook runs the Conduit executable
itself, double-quoted so `cmd.exe` and Git Bash read the command alike:
`"<conduit.exe>" control agent.event --event=<Hook>`. `PermissionRequest` runs
`"<conduit.exe>" control agent.permission --wait`, a blocking client mode that does what `hook.sh`
does in the same line format: it chooses a request id, sends the `PermissionRequest` line (over the
endpoint as `agent.event`, else appended to the agent's sink), waits up to 580 s for the answer the
human gives in the agent view (`respondPermission` writes `<sink>/decisions/<id>`, as for the
relay), sends a `PermissionEnd` line with the outcome, and prints Claude Code's
`hookSpecificOutput.decision.behavior` allow or deny reply. A timeout reports `aborted` (resolved
elsewhere) and prints nothing, so Claude Code's own dialog decides; when that dialog answers first,
Claude Code ends the hook process and a later hook resolves the request, as on POSIX. The helper
path must be drive-absolute and free of `"`, `%`, `$`, `` ` ``, `!` and control characters
(`claude_code.isValidWindowsPath`), and on Windows it is set whether or not the endpoint runs:
`conduit control agent.event` falls back to appending to `$CONDUIT_AGENT_SINK/events.jsonl` (now with
`FILE_APPEND_DATA` on Windows, `O_APPEND` elsewhere, through `platform.appendToFile`). Windows
agent sinks live under `%LOCALAPPDATA%\conduit\agents\<run>`. POSIX hosts, and every remote (SSH)
sink, keep the `/bin/sh` relay unchanged.

The control server needs no new method: `agent.permission --wait` is a client mode over the
existing `agent.event` and the sink's `decisions/` directory, so a waiting hook holds no server
connection or reply deadline open for minutes.

## Consequences

- `--control-test` runs on the hosted Windows runner with PowerShell 7 tabs and separate
  `conduit.exe` client processes, and a stand-in Claude Code there runs the generated hook
  commands through `cmd.exe`, so the whole hook path, permission answer included, is exercised on
  Windows. The same stand-in runs on Linux, where it also calls `agent.permission --wait` directly.
- A Windows process of another user (or an anonymous token) cannot open the pipes, and remote
  clients are rejected by the pipe itself; a platform unit test impersonates the anonymous token
  and opens `\\localhost\pipe\…` to prove both.
- Codex and OpenCode keep their own servers (they were never sink harnesses). Pi's extension still
  writes its sink file directly and has no Windows-specific change; on Windows it has not been run.
- Claude Code's own choice of shell for hook commands on Windows was not verified against a real
  Claude Code there; the command is spelled to be read identically by `cmd.exe` and Git Bash. A
  real authenticated Claude Code on Windows remains unverified.
