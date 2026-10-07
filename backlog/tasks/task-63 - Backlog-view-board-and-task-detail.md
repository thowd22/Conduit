---
id: TASK-63
title: 'Backlog view: board and task detail'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 23:19'
labels:
  - backlog
  - ui
milestone: m-7
dependencies:
  - TASK-19
  - TASK-62
priority: high
ordinal: 63000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Terminal-styled backlog view openable as a tab or pane: board by status and list by milestone, filters, clickable task rows opening a detail view (description, acceptance criteria, dependencies, notes), and basic edits (status, assignee, priority, checking acceptance criteria).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Board and list views render the workspace backlog
- [ ] #2 Clicking or pressing Enter on a task opens its detail
- [ ] #3 Status and acceptance criteria can be changed from the view
- [ ] #4 E2E scenario opens the backlog view and moves a task
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Backlog view (backlog.open, palette + chord) as a per-workspace presentation: board columns by status and a list mode, built from backlog.Project loaded through the workspace ExecutionContext and refreshed by Project.poll; task rows are InteractiveText with id, title, status, assignee/agent, labels.
2. Task detail: Enter/click opens a detail Surface with description, acceptance criteria rows (toggle via backlog.Cli.checkAcceptance), status cycle (backlog.Cli.setStatus), notes; failures shown in a status line.
3. --backlog-test against a fixture project copied into the isolated run plus an e2e scenario moving a task; docs.
<!-- SECTION:PLAN:END -->
