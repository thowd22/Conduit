---
id: TASK-61
title: Agents in SSH workspaces
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - agents
  - ssh
milestone: m-6
dependencies:
  - TASK-43
  - TASK-53
priority: medium
ordinal: 61000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Run and observe harnesses on the remote host of an SSH workspace: launch remotely through the ExecutionContext and carry adapter events (hooks, transcripts) back over the connection so status, notifications and agent views work the same as locally.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 An agent launched in an SSH workspace runs on the remote host
- [ ] #2 Status and notifications work for the remote agent
- [ ] #3 Agent view renders the remote agent's structured events
<!-- AC:END -->
