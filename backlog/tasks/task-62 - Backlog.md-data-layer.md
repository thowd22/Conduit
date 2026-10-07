---
id: TASK-62
title: Backlog.md data layer
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 19:57'
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

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend the type-erased ExecutionContext with bounded file read, directory listing, change observation and command run capabilities (Local implementation), so backlog, git and remote features share one seam.
2. backlog.zig: typed model (tasks with status, priority, labels, milestone, dependencies, acceptance criteria; milestones, docs, decisions, config) parsed from a backlog/ directory through that seam with bounded, never-fatal parsing and per-file diagnostics.
3. Live update: directory change observation re-parses changed files into the model.
4. Writes through the backlog CLI (run through the context) with reported failures.
5. Fixture backlog directories under test data; unit tests for parsing, live update and CLI failure reporting.
<!-- SECTION:PLAN:END -->
