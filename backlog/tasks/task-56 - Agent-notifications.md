---
id: TASK-56
title: Agent notifications
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - agents
  - notifications
milestone: m-6
dependencies:
  - TASK-28
  - TASK-52
priority: high
ordinal: 56000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Notify when an agent needs attention (permission, input, finished, errored): status glyphs on sidebar tabs and workspaces, an in-app terminal-styled notification list reachable from the palette, and native OS notifications when the window is unfocused. Clicking a notification focuses the agent. Also honor terminal notification sequences (OSC 9/777, bell). Per-harness and per-event settings.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Sidebar shows per-agent state glyphs that update live
- [ ] #2 OS notification is raised when an agent needs attention and the window is unfocused
- [ ] #3 Activating a notification focuses the relevant workspace and agent
- [ ] #4 Notification types can be enabled or disabled in config
- [ ] #5 E2E scenario with the fake adapter covers the notification flow
<!-- AC:END -->
