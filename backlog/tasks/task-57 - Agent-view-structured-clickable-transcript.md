---
id: TASK-57
title: 'Agent view: structured, clickable transcript'
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
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
