---
id: TASK-42
title: 'Spike: SSH architecture decision'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 20:11'
labels:
  - spike
  - ssh
milestone: m-5
dependencies: []
priority: high
ordinal: 42000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Decide how SSH execution contexts work: system OpenSSH with ControlMaster multiplexing versus an embedded library (libssh2/libssh), including the Windows story (Windows OpenSSH lacks ControlMaster), authentication UX (agent, keys, passwords, 2FA prompts, host key verification), connection sharing across tabs, panes and scratchpad, reconnect behavior, remote cwd tracking, and how agents and file reads (backlog) run remotely. Record as a backlog decision.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Decision record covers Linux, macOS and Windows
- [x] #2 Authentication prompts and host key verification UX are specified
- [x] #3 Connection reuse strategy for tabs, panes and scratchpad is specified
- [x] #4 Prototype opens two shells over one authenticated connection
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Survey system OpenSSH ControlMaster vs libssh2/libssh for Linux, macOS and Windows (no ControlMaster on Windows OpenSSH), auth UX (agent, keys, passwords, 2FA, host keys), connection sharing, reconnect, remote cwd, remote file reads and agents.
2. Prototype: two shells over one authenticated connection against a local sshd container.
3. Record the decision and the UX specification as a Backlog decision; note implications for TASK-43/44/45/61.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Spike outcome 2026-10-07: decision-8 (accepted by the coordinator under the user's 'do not pause' instruction) chooses the system OpenSSH client spawned through pty.spawn with one ControlMaster per SSH workspace on Linux/macOS (tabs/panes/scratchpad/vi/agent TUIs over 'ssh -tt -o ControlMaster=no'; exec work over 'ssh -T -o BatchMode=yes'); Windows gets one ssh.exe per session with the Windows ssh-agent (no ControlMaster), with WSL-transport and libssh2/WinCNG recorded as later opt-in upgrades needing their own decisions. OpenSSH's own prompts (host key, passphrase, password, 2FA) appear verbatim in a connection session's terminal; Conduit never parses, stores or logs them and never relaxes StrictHostKeyChecking. Prototype spikes/ssh-controlmaster (Docker sshd, throwaway key, driver built against src/pty.zig) proved one authentication, two independent resizable shells and two exec channels on one master; findings: ControlMaster=no silently falls back to a direct connection without a live master (so BatchMode everywhere), ssh -v logs remote commands, control socket paths need a short 0700 dir and a sun_path length check.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Recorded decision-8: system OpenSSH with a per-workspace ControlMaster on Linux/macOS, per-session ssh.exe on Windows, OpenSSH-native auth and host-key prompts shown in a connection session, explicit reconnect, remote shell integration and bounded exec channels for files/commands/agents. The ControlMaster prototype against a local sshd container proved two shells and two exec channels over a single authenticated connection.
<!-- SECTION:FINAL_SUMMARY:END -->
