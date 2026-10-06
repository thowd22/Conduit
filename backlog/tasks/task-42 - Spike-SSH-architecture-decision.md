---
id: TASK-42
title: 'Spike: SSH architecture decision'
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
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
- [ ] #1 Decision record covers Linux, macOS and Windows
- [ ] #2 Authentication prompts and host key verification UX are specified
- [ ] #3 Connection reuse strategy for tabs, panes and scratchpad is specified
- [ ] #4 Prototype opens two shells over one authenticated connection
<!-- AC:END -->
