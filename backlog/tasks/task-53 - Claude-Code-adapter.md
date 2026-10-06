---
id: TASK-53
title: Claude Code adapter
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - agents
  - claude
milestone: m-6
dependencies:
  - TASK-52
priority: high
ordinal: 53000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Adapter for Claude Code CLI per the spike: launch and attach, map hook and transcript events into the agent event stream, surface status and permission requests, expose subagents, and read prompts/instructions where supported. Detect Claude Code started manually in any Conduit terminal.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Claude Code launched from Conduit appears in the agent registry with live status
- [ ] #2 Permission requests and completion produce agent events
- [ ] #3 Tool uses and file references are captured as structured events
- [ ] #4 A manually started claude process in a Conduit terminal is detected
<!-- AC:END -->
