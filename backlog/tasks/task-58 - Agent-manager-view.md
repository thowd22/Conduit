---
id: TASK-58
title: Agent manager view
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - agents
  - ui
milestone: m-6
dependencies:
  - TASK-31
  - TASK-52
priority: high
ordinal: 58000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
One place to see and manage every agent across workspaces: harness, workspace, task, state, last activity. Actions: focus, send message, stop, restart, spawn new agent (choose harness, workspace and initial prompt). Reachable from palette and sidebar.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Manager lists all agents across workspaces with live state
- [ ] #2 Agents can be focused, stopped and spawned from the manager
- [ ] #3 A message can be sent to an agent without leaving the manager
- [ ] #4 All rows and actions are mouse and keyboard operable
<!-- AC:END -->
