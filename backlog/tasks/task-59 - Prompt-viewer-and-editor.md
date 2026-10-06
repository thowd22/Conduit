---
id: TASK-59
title: Prompt viewer and editor
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - agents
  - ui
milestone: m-6
dependencies:
  - TASK-57
priority: medium
ordinal: 59000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
View the prompts behind an agent: the user prompts sent, project instruction files (CLAUDE.md, AGENTS.md and harness equivalents), and subagent/custom agent definitions where the harness exposes them. Edit in a terminal-style editor surface or hand off to $EDITOR in a pane, then save and, where supported, resend or apply.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Prompts and instruction files for an agent are viewable from the agent view
- [ ] #2 Editable items can be modified and saved from within Conduit
- [ ] #3 Items a harness does not allow editing are shown read-only with an explanation
<!-- AC:END -->
