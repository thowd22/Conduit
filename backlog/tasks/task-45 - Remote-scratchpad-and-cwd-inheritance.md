---
id: TASK-45
title: Remote scratchpad and cwd inheritance
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - ssh
  - scratchpad
milestone: m-5
dependencies:
  - TASK-17
  - TASK-32
  - TASK-43
priority: high
ordinal: 45000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
In an SSH workspace the scratchpad is a remote shell started in the background over the shared connection, and new tabs, panes and the scratchpad start in the remote working directory of the originating session when shell integration reports it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Scratchpad in an SSH workspace runs on the remote host
- [ ] #2 New panes and tabs start in the originating session's remote cwd when known
- [ ] #3 Scratchpad session persists across hide/show and is restored after reconnect where possible
<!-- AC:END -->
