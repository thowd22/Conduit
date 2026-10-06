---
id: TASK-62
title: Backlog.md data layer
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - backlog
milestone: m-7
dependencies:
  - TASK-27
priority: high
ordinal: 62000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Read a workspace's Backlog.md project (backlog/ directory: tasks, milestones, docs, decisions, config) into a typed model, watch for changes, and perform writes through the backlog CLI when available. Works through the ExecutionContext so remote workspaces are supported.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Tasks, statuses, milestones, labels, dependencies and acceptance criteria are parsed
- [ ] #2 External changes to backlog files update the model live
- [ ] #3 Edits go through the backlog CLI and failures are reported
- [ ] #4 Unit tests parse fixture backlog directories
<!-- AC:END -->
