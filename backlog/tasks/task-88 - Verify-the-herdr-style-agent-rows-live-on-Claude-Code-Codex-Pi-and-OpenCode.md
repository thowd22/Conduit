---
id: TASK-88
title: 'Verify the herdr-style agent rows live on Claude Code, Codex, Pi and OpenCode'
status: To Do
assignee: []
created_date: '2026-10-09 04:53'
labels:
  - agents
  - verification
milestone: m-6
dependencies:
  - TASK-85
  - TASK-86
  - TASK-87
priority: high
ordinal: 89000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-85, TASK-86 and TASK-87 are proven with the scripted fake and fixtures; the user asked for the loop to continue until the sidebar and view work across every supported harness. This task is that evidence: each real harness, started by hand in a driven Conduit on Linux against a local model stand-in (the Messages API stand-in used for TASK-84, the Codex mock provider under test/fixtures/agent/codex, Pi's loopback mock model, the conduit-opencode-check container with its fixed model), must show the coloured icon moving through working, blocked and done, its stripped title in the row where it sets one, the TUI on a row click, and the agent view's reasoning and tool-result rows where the harness has a structured channel (Claude Code transcript and hooks; Codex daemon thread; Pi session file; OpenCode HTTP). A harness that stops short gets its adapter fixed under this task (adapter and fixtures only; an app-level gap becomes a note for the coordinator). The hosted matrix must stay green and --agent-test must still gate on windows.yml.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Claude Code 2.1.292, hand-started and launched: icons, row title, click shows the TUI, view shows reasoning and tool results; evidence (driver inspect output and inspected screenshots) in the notes
- [ ] #2 Codex 0.160.1, hand-started with the mock provider: icons, row detail, click shows the TUI, view shows reasoning and command output; evidence in the notes
- [ ] #3 Pi 0.73.1, hand-started with the loopback mock model: icons, row detail, click shows the TUI, view shows thinking and tool results; evidence in the notes
- [ ] #4 OpenCode 1.18.35 in the check container: icons, row detail, click shows the TUI, view shows reasoning and tool output; evidence in the notes
- [ ] #5 The three-OS matrix, the Linux gate and a windows.yml dispatch with --agent-test are green on the final commit; omp and macOS/Windows real-harness screens are listed as unverified in AGENTS.md
<!-- AC:END -->
