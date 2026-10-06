---
id: TASK-52
title: Agent adapter interface and agent state model
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - agents
  - architecture
milestone: m-6
dependencies:
  - TASK-27
  - TASK-51
priority: high
ordinal: 52000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Define the harness-neutral AgentAdapter interface (detect installation, launch in a workspace context, attach to an existing session, event stream, send input, respond to permission requests, read/update prompt where supported, stop) and the Agent state model (idle, working, waiting for input, waiting for permission, done, errored) with a registry of agents per workspace. Agents get their own managed sessions and never the scratchpad.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Adapter interface is implemented by a fake adapter used in unit tests
- [ ] #2 Agent registry tracks agents per workspace with state transitions
- [ ] #3 Agent events are a typed stream (message, tool use, file reference, permission request, status change)
- [ ] #4 Agent-owned sessions are separated from human sessions in the model
<!-- AC:END -->
