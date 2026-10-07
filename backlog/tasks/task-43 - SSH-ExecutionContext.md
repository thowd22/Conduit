---
id: TASK-43
title: SSH ExecutionContext
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 20:25'
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
- [ ] #1 An SSH workspace opens tabs and panes on the remote host with a single authentication
- [ ] #2 Host aliases and options from ~/.ssh/config are honored
- [ ] #3 Password, passphrase and host-key prompts are presented in terminal-style UI
- [ ] #4 Connection loss is detected and shown; sessions can be reconnected
- [ ] #5 Integration test runs against a local sshd container
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Part 1 (context and connection model, no app UI): 1. src/ssh.zig SshContext implementing ExecutionContext per decision-8: a master process (ssh -M -N with ControlPersist=no, ControlPath under a short 0700 dir with %C names, user ssh config honoured via no -F override except in tests) running in a Conduit PTY as a connection session kind; spawn runs ssh -tt -o ControlMaster=no over the master; readFile/listDir/statPath/run use ssh -T -o BatchMode=yes exec channels with a POSIX-sh helper; watch via a long-lived exec channel or polling.
2. Connection state machine (connecting, connected, lost, failed) driven by ssh -O check and client exit codes; explicit reconnect respawns sessions in their last OSC 7 cwd.
3. Integration tests against a local sshd container (docker; skipped when docker is absent) proving single authentication, two shells, exec channels, loss detection and reconnect.
Part 2 (after TASK-76/77 free main.zig): sidebar connection state, the connection session presented for prompts, --ssh-test, with TASK-44/45.
<!-- SECTION:PLAN:END -->
