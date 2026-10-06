---
id: TASK-43
title: SSH ExecutionContext
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
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
