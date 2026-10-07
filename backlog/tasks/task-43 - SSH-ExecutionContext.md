---
id: TASK-43
title: SSH ExecutionContext
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 22:24'
labels:
  - ssh
  - workspace
milestone: m-5
dependencies:
  - TASK-27
  - TASK-42
priority: high
ordinal: 43000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement the SSH context per the decision: a workspace bound to user@host where new tabs, panes and sessions open remote shells over a shared connection without re-authenticating. Honors ~/.ssh/config. Surfaces connection state (connecting, connected, lost) in the sidebar.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 An SSH workspace opens tabs and panes on the remote host with a single authentication
- [x] #2 Host aliases and options from ~/.ssh/config are honored
- [x] #3 Password, passphrase and host-key prompts are presented in terminal-style UI
- [x] #4 Connection loss is detected and shown; sessions can be reconnected
- [x] #5 Integration test runs against a local sshd container
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Part 1 (context and connection model, no app UI): 1. src/ssh.zig SshContext implementing ExecutionContext per decision-8: a master process (ssh -M -N with ControlPersist=no, ControlPath under a short 0700 dir with %C names, user ssh config honoured via no -F override except in tests) running in a Conduit PTY as a connection session kind; spawn runs ssh -tt -o ControlMaster=no over the master; readFile/listDir/statPath/run use ssh -T -o BatchMode=yes exec channels with a POSIX-sh helper; watch via a long-lived exec channel or polling.
2. Connection state machine (connecting, connected, lost, failed) driven by ssh -O check and client exit codes; explicit reconnect respawns sessions in their last OSC 7 cwd.
3. Integration tests against a local sshd container (docker; skipped when docker is absent) proving single authentication, two shells, exec channels, loss detection and reconnect.
Part 2 (after TASK-76/77 free main.zig): sidebar connection state, the connection session presented for prompts, --ssh-test, with TASK-44/45.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Part one landed (799e5f9 rebased onto main as 36bc5a2): src/ssh.zig SshContext (kind .ssh) over one ControlMaster per workspace per decision-8: master in a Conduit PTY (masterTerminal() for prompts), sessions via ssh -tt -o ControlMaster=no, exec/readFile/listDir/statPath/run/watch via ssh -T BatchMode with octal-escaped eval scripts (verified to decode in fish/tcsh/zsh/bash/dash), state machine disconnected/connecting/connected/lost/failed with a wake hook, poll() probing the control socket, reconnect/disconnect, 0700 control dir with m<pid>-<serial> names and sun_path check. 10 unit tests plus a Docker sshd integration test (test/fixtures/ssh) proving one authentication for two resizable shells + exec channels + watch, host-key and passphrase prompts answered through the master PTY, loss detection, reconnect and clean disconnect; 748/759 unit tests pass on main. Part two (app): connection session kind presenting masterTerminal, sidebar state, ChildSpec .ssh overlay should be the remote overlay with empty argv for the login shell, local_env/runtime_dir plumbing, --ssh-test; shell_integration .auto still behaves as .off; macOS/Windows create() returns Unsupported.

Part two landed (a55c858, 7bc259e, 01d3414 rebased onto main as 7c24e5e): connection session kind presenting the master's terminal under a workspace.<k>.connection header until connected; sidebar ↕/⚠/✗/○ with workspace.<k>.ssh.<state>; remote host name learned for OSC 7 (term.setWorkingDirectoryHost); remote.reconnect respawns disconnected sessions under their ids at their last cwd; remote.disconnect/show-connection; ChildSpec.buildSshClient/buildRemote split; --ssh-test (5/5 runs) against the container through real SDL input. Coordinator 2026-10-07: full gate green (827/838 unit tests, 24 checks incl. --ssh-test, 15 scenarios); prompt, connected and lost screenshots inspected. Unverified: password/2FA/changed-host-key prompts, remote shell integration (.auto behaves as .off), macOS/Windows (comptime-guarded).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
SSH ExecutionContext end to end: one ControlMaster per SSH workspace spawned through Conduit's PTY machinery (decision-8), tabs, panes, editor tabs and the scratchpad over ssh -tt sessions and file/command access over BatchMode exec channels, OpenSSH's own prompts shown verbatim in a connection session, ~/.ssh/config honoured, loss detected and shown with user-driven reconnect that respawns every session in its last remote cwd; verified by unit tests, a Docker sshd integration test of the context and the deterministic --ssh-test driving the app through real SDL input.
<!-- SECTION:FINAL_SUMMARY:END -->
