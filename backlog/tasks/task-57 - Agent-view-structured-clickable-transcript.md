---
id: TASK-57
title: 'Agent view: structured, clickable transcript'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 22:58'
labels:
  - agents
  - ui
milestone: m-6
dependencies:
  - TASK-19
  - TASK-34
  - TASK-53
priority: high
ordinal: 57000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A view that looks like terminal output but is built from structured agent events: messages, tool calls, file references (clickable, open at line), prompts, subagents and inline permission choices (Allow once, Always allow, Reject as clickable text). Supports selection, copy, scroll and search. Toggle between the agent view and the raw agent terminal.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Agent events render as terminal-styled structured content
- [x] #2 File references are clickable and open at the referenced line
- [x] #3 Permission choices can be answered by click or keyboard and reach the harness
- [x] #4 Text in the view can be selected and copied
- [x] #5 User can switch between structured view and raw terminal for the same agent
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Agent view as a per-agent presentation (toggle agent.view with the raw terminal) built from the four primitives: a scrollable Surface of Text/InteractiveText rows rendered from the runner's event log (messages by role, tool uses, file references as clickable rows opening the file at the line via the existing file-reference tab path, subagent markers, notifications), with inline permission choices as clickable InteractiveText (the harness's own decisions) and keyboard navigation.
2. Selection and copy of view text through the existing clipboard actions; search within the view through the existing search Input.
3. respondPermission routed to the runner worker through a request queue; answered rows show the outcome.
4. --agent-view-test with the fake adapter and a sixteenth e2e scenario; docs.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Agent: src/agent_view.zig View/EventLog/Rows; agent.view toggle (Ctrl+Shift+A); rows for messages (wrapped), tool uses, clickable file references opening vi +line through the context, permission decision controls answered by click or keyboard through the runner worker queue with outcome rows, subagent/notification/state lines; drag/Shift selection and copy; literal search over rows; --agent-view-test and the sixteenth scenario agent-view; --ui-test registry assertion now 77 actions. Coordinator 2026-10-07: merged as 7c53cc6; fixed two stale scenario-count assertions (15 -> 16) in e2e tests; full gate green (838/849 unit tests, 25 checks incl. --agent-view-test, 16 scenarios); screenshot inspected (messages, tool uses, reference, permission blocks, subagents).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Structured agent view: a terminal-styled transcript built from the agent's structured events with clickable file references, inline permission decisions that reach the harness through the runner worker, selection, copy and search, toggled against the raw terminal; verified by unit tests, the deterministic --agent-view-test with the fake adapter, the agent-view scenario and the full local gate.
<!-- SECTION:FINAL_SUMMARY:END -->
