---
id: TASK-54
title: Codex CLI adapter
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - agents
  - codex
milestone: m-6
dependencies:
  - TASK-52
priority: high
ordinal: 54000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Adapter for Codex CLI per the spike: launch and attach, map its notification and session events into the agent event stream, surface status and approval requests, and read prompts/instructions where supported.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Codex launched from Conduit appears in the agent registry with live status
- [ ] #2 Approval requests and turn completion produce agent events
- [ ] #3 A manually started codex process in a Conduit terminal is detected
<!-- AC:END -->
