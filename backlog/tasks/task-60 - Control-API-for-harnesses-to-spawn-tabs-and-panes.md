---
id: TASK-60
title: Control API for harnesses to spawn tabs and panes
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - agents
  - cli
milestone: m-6
dependencies:
  - TASK-30
  - TASK-52
priority: medium
ordinal: 60000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A local control endpoint and matching 'conduit' subcommands (and MCP tools) that let a harness running inside Conduit open a tab or pane, show an agent view or backlog view, set tab status and raise notifications, scoped to its own workspace. The scratchpad is not addressable through this API.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A process inside a Conduit terminal can open a tab or split pane in its workspace through the API
- [ ] #2 API exposes agent view and backlog view creation
- [ ] #3 Scratchpad cannot be targeted or taken over through the API
- [ ] #4 API is documented for harness configuration
<!-- AC:END -->
