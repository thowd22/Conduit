---
id: TASK-58
title: Agent manager view
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 22:57'
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

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Agent manager as a modal Surface (agents.open, palette and chord) listing every agent across workspaces: harness, workspace, tab, task (placeholder for TASK-64), state glyph+word, last activity age, each row an InteractiveText; rows live from the registry.
2. Row actions by keyboard and mouse: focus (switch workspace/tab, open the view), stop, restart (respawn the same LaunchSpec in the same tab), send message (inline Input routed to the runner's worker sendInput), spawn new agent (harness choice, workspace choice, optional prompt) reusing agent.launch.
3. --agent-manager-test with two fake agents across two workspaces and a seventeenth e2e scenario; docs.
<!-- SECTION:PLAN:END -->
