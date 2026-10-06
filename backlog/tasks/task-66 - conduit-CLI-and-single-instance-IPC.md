---
id: TASK-66
title: conduit CLI and single-instance IPC
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - cli
milestone: m-8
dependencies:
  - TASK-33
  - TASK-43
  - TASK-60
priority: medium
ordinal: 66000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Command-line entry points that talk to a running instance or start one: 'conduit', 'conduit .', 'conduit ssh <host>', 'conduit workspace open <name>', 'conduit agent <claude|codex|pi>'.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 'conduit .' opens or focuses a workspace for the current directory
- [ ] #2 'conduit ssh <host>' opens an SSH workspace
- [ ] #3 'conduit agent <harness>' launches the harness in the current workspace
- [ ] #4 Commands reuse a running instance when one exists
<!-- AC:END -->
