---
id: TASK-52
title: Agent adapter interface and agent state model
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 19:57'
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

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Define agent.Adapter (type-erased vtable: detect, launch, attach, events, sendInput, respondPermission, prompt read/update, stop; each capability optional with explicit unsupported) and the typed Event stream and Agent state machine (idle, working, waiting_input, waiting_permission, done, errored) per decision-7, with a status source (structured vs heuristic).
2. agent.Registry keyed by workspace key holding Agent records under monotonic ids, each bound to an agent-kind session id; the scratchpad can never be an agent target.
3. PTY-baseline heuristics module shape (OSC 0/2, BEL, OSC 9/777, OSC 133, activity, exit) as the harness-neutral fallback contract.
4. Fake adapter driving every interface method in unit tests; registry state-transition tests; docs.
<!-- SECTION:PLAN:END -->
