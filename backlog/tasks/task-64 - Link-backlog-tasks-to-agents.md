---
id: TASK-64
title: Link backlog tasks to agents
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 23:19'
labels:
  - backlog
  - agents
milestone: m-7
dependencies:
  - TASK-58
  - TASK-63
priority: medium
ordinal: 64000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Start an agent on a task (prefilled prompt from the task), show which agent is working on which task in both the backlog view and the agent manager, and reflect task status changes made by agents live.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 An agent can be launched from a task with the task content as initial prompt
- [ ] #2 Task rows show the assigned agent and its state
- [ ] #3 Agent manager shows the task an agent is working on
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. From a task row: agent.launch-from-task prefilling the initial prompt with the task id, title, description and acceptance criteria.
2. Agent ↔ task link kept on the agent record (task id) and shown in the task row (glyph + harness) and in the manager's task column; task status changes made by the agent (through the backlog CLI) appear live through Project.poll.
3. Covered by --backlog-test with the fake adapter; docs.
<!-- SECTION:PLAN:END -->
