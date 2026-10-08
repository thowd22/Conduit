---
id: TASK-64
title: Link backlog tasks to agents
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 00:00'
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
- [x] #1 An agent can be launched from a task with the task content as initial prompt
- [x] #2 Task rows show the assigned agent and its state
- [x] #3 Agent manager shows the task an agent is working on
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. From a task row: agent.launch-from-task prefilling the initial prompt with the task id, title, description and acceptance criteria.
2. Agent ↔ task link kept on the agent record (task id) and shown in the task row (glyph + harness) and in the manager's task column; task status changes made by the agent (through the backlog CLI) appear live through Project.poll.
3. Covered by --backlog-test with the fake adapter; docs.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Agent: detail 'start agent' launches the chosen harness in the project directory with backlog.taskPrompt (id, title, description, criteria; 16 KiB bound, controls stripped); task id kept on the Runner across restart; cards/list/detail show the agent glyph and state live (backlog.task.<id>.agent.<state>); manager task column names the task. Proven in --backlog-test with the fake agent. Coordinator 2026-10-08: merged as b0cb8f0, gate green.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Task-agent linking: launch an agent from a task with the task content as its prompt, show the assigned agent and state on task rows and in the detail, and name the task in the agent manager; verified by --backlog-test with the fake adapter.
<!-- SECTION:FINAL_SUMMARY:END -->
