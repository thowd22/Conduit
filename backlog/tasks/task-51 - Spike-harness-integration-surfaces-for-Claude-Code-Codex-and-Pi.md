---
id: TASK-51
title: 'Spike: harness integration surfaces for Claude Code, Codex and Pi'
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - spike
  - agents
milestone: m-6
dependencies: []
priority: high
ordinal: 51000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Investigate, for each of Claude Code CLI, Codex CLI and Pi, what Conduit can observe and control: hooks and notification events, session transcript files and formats, headless/JSON/RPC or SDK modes, permission prompt handling, how prompts/instructions and subagents are exposed, how to resume sessions, and what works over SSH. Produce a capability matrix and record the adapter strategy as a backlog decision.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Capability matrix covers status, notifications, transcript access, permission prompts, prompt/instruction access and subagents for all three harnesses
- [ ] #2 For each harness the chosen integration mechanism is named with a minimal working proof
- [ ] #3 Gaps where a harness cannot support a feature are listed with fallbacks
<!-- AC:END -->
