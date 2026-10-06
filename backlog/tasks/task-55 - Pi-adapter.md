---
id: TASK-55
title: Pi adapter
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - agents
  - pi
milestone: m-6
dependencies:
  - TASK-52
priority: medium
ordinal: 55000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Adapter for the Pi coding agent CLI per the spike: launch and attach, map its events into the agent event stream, surface status and input requests, and read prompts/instructions where supported.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Pi launched from Conduit appears in the agent registry with live status
- [ ] #2 Waiting-for-input and completion produce agent events
- [ ] #3 A manually started pi process in a Conduit terminal is detected
<!-- AC:END -->
