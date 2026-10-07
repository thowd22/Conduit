---
id: TASK-78
title: OpenCode adapter
status: To Do
assignee: []
created_date: '2026-10-07 15:38'
labels:
  - agents
  - opencode
milestone: m-6
dependencies:
  - TASK-52
  - TASK-51
priority: medium
ordinal: 79000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user runs OpenCode alongside Claude Code, Codex and omp (oh-my-pi) and wants it treated as a first-class coding agent in Conduit, exactly like the other three: a harness adapter behind the common agent adapter interface (TASK-52), so nothing outside agent/ special-cases it (invariant 9). Per the spike pattern of TASK-51 (which covered Claude Code, Codex and Pi but not OpenCode): launch and attach, map its session and tool events into the agent event stream, surface status, permission/approval and waiting-for-input states, and read prompts/instructions where its surfaces allow. Context a future agent cannot recover from the code: OpenCode exposes a local server/API with an event stream and session storage in addition to its TUI, so the adapter should prefer a structured surface over scraping terminal text, and the integration surface should be verified in a short spike before the adapter is built (either by extending TASK-51 or inside this task). OpenCode is not installed on the dev box (only claude, codex and omp are); installing it for integration tests needs the user's approval and must be recorded in the build docs. Like the other adapters it must work inside SSH and WSL workspaces through the ExecutionContext (TASK-61).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 OpenCode launched from Conduit appears in the agent registry with live status (idle, working, waiting for input, waiting for approval, done), mapped from its structured events rather than terminal text
- [ ] #2 Permission/approval requests, waiting-for-input and turn completion produce agent events that TASK-56 notifications and the sidebar agent state consume without any OpenCode-specific code outside agent/
- [ ] #3 A manually started opencode process in a Conduit terminal is detected and attached
- [ ] #4 Harness-neutral tests cover the adapter through the common interface with recorded event fixtures, and an integration check runs against a real opencode binary where it is installed, skipping with a clear message where it is not
- [ ] #5 The integration surface used (server/API, event stream, session files) is recorded as a Backlog decision; AGENTS.md and docs/architecture.md list OpenCode beside the other harnesses
<!-- AC:END -->
