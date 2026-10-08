---
id: TASK-63
title: 'Backlog view: board and task detail'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 00:00'
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
- [x] #1 Board and list views render the workspace backlog
- [x] #2 Clicking or pressing Enter on a task opens its detail
- [x] #3 Status and acceptance criteria can be changed from the view
- [x] #4 E2E scenario opens the backlog view and moves a task
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Backlog view (backlog.open, palette + chord) as a per-workspace presentation: board columns by status and a list mode, built from backlog.Project loaded through the workspace ExecutionContext and refreshed by Project.poll; task rows are InteractiveText with id, title, status, assignee/agent, labels.
2. Task detail: Enter/click opens a detail Surface with description, acceptance criteria rows (toggle via backlog.Cli.checkAcceptance), status cycle (backlog.Cli.setStatus), notes; failures shown in a status line.
3. --backlog-test against a fixture project copied into the isolated run plus an e2e scenario moving a task; docs.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Agent: src/backlog_view.zig board/list/detail model; backlog.open (Ctrl+Shift+K; B is the sidebar toggle); project at <OSC 7 cwd>/backlog read through the ExecutionContext and polled; status cycle and criteria toggles through backlog.Cli on a bounded worker with CLI failures shown in backlog.message; open-in-vi; --backlog-test with a copied fixture and a fake backlog CLI; eighteenth scenario backlog-board moving a task via CONDUIT_TEST_BACKLOG_CLI (driver-only, never inherited). Coordinator 2026-10-08: merged as b0cb8f0; full gate green (873/884 unit tests, 27 checks, 18 scenarios); board and detail screenshots inspected. Local workspaces only; the real backlog CLI is never run by a check.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Backlog view: a per-workspace board and list of the workspace's Backlog.md project with a task detail where status and acceptance criteria are changed through the backlog CLI and reflected live; verified by unit tests, the deterministic --backlog-test and the backlog-board scenario.
<!-- SECTION:FINAL_SUMMARY:END -->
