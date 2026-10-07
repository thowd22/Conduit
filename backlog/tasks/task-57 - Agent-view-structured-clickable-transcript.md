---
id: TASK-57
title: 'Agent view: structured, clickable transcript'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 22:24'
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
- [ ] #1 Agent events render as terminal-styled structured content
- [ ] #2 File references are clickable and open at the referenced line
- [ ] #3 Permission choices can be answered by click or keyboard and reach the harness
- [ ] #4 Text in the view can be selected and copied
- [ ] #5 User can switch between structured view and raw terminal for the same agent
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Agent view as a per-agent presentation (toggle agent.view with the raw terminal) built from the four primitives: a scrollable Surface of Text/InteractiveText rows rendered from the runner's event log (messages by role, tool uses, file references as clickable rows opening the file at the line via the existing file-reference tab path, subagent markers, notifications), with inline permission choices as clickable InteractiveText (the harness's own decisions) and keyboard navigation.
2. Selection and copy of view text through the existing clipboard actions; search within the view through the existing search Input.
3. respondPermission routed to the runner worker through a request queue; answered rows show the outcome.
4. --agent-view-test with the fake adapter and a sixteenth e2e scenario; docs.
<!-- SECTION:PLAN:END -->
