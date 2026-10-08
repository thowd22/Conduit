---
id: TASK-66
title: conduit CLI and single-instance IPC
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 00:00'
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

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. conduit CLI entry points in the same binary: 'conduit' (start), 'conduit .' / 'conduit <dir>' (open or focus a workspace for the directory), 'conduit ssh <host>' (open an SSH workspace), 'conduit workspace open <name>', 'conduit agent <claude|codex|pi|opencode>' (launch in the current workspace, inferred from CONDUIT_CONTROL_* when run inside Conduit), 'conduit control <method> [json]' (raw control request helper used by hook snippets).
2. Single-instance IPC: a per-user instance socket (platform-private dir) that a running instance serves through the TASK-60 control server with an instance-level token file (0600); a new 'conduit' process connects, forwards the command and exits, or starts the app when nothing answers.
3. --control-test covering the CLI round trip against a running test instance; docs/user-guide.md CLI section.
<!-- SECTION:PLAN:END -->
