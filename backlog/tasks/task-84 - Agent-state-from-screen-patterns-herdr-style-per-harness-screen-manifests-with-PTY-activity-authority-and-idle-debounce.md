---
id: TASK-84
title: >-
  Agent state from screen patterns: herdr-style per-harness screen manifests
  with PTY-activity authority and idle debounce
status: To Do
assignee: []
created_date: '2026-10-09 00:26'
updated_date: '2026-10-09 00:27'
labels:
  - agents
  - heuristics
milestone: m-6
dependencies:
  - TASK-81
  - TASK-80
priority: medium
ordinal: 85000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Observed (hand-started) agents and launched agents whose structured events are missing or late get their state only from Conduit's PTY heuristics (agent.Heuristics: output, title, BEL, OSC 9/777, OSC 133, human input, quiet, child exit), so a hand-started Claude Code, Codex, Pi/omp or OpenCode shows idle or working but never 'input' or 'permission' unless its hooks or API are wired. herdr (Apache-2.0, Rust) solves this with a per-agent manifest of screen patterns: each harness ships regexes matched against the visible terminal screen (the last N rows) that classify what the TUI is showing (a permission or approval prompt, a question or input request, a spinner or 'thinking' line, an error, the idle prompt). PTY output activity is the authority for 'working' (any output within a short window means working, whatever the screen says), the screen classifies the quiet states, and idle is debounced (herdr requires 3 consecutive idle confirmations with a 700 ms cap before leaving working) so spinner frames and short pauses do not flap the sidebar glyph. Do the same for Conduit under invariant 9: the manifest lives in each adapter under src/agent/ (claude_code, codex, pi, opencode) as compile-time data, agent.Heuristics gains a screen classifier that reads a bounded snapshot of the session's visible rows through the existing term read path (never scrollback, never logged), and structured events keep precedence as today. Screen text is untrusted: it may only move the heuristic state, never answer a prompt or trigger an action. Record the pattern lists with the exact harness version they were captured from, and capture fixtures (scrubbed screen snapshots) under src/agent/<harness>/fixtures or testdata. Reference: https://github.com/herdrdev/herdr (Apache-2.0; clone it fresh into scratch, the coordinators 2026-10-08 clone was removed). Look at its per-agent manifests and the idle debounce logic before designing Conduits version.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each adapter under src/agent/ publishes a ScreenManifest of bounded patterns for working, input, permission and errored, matched by agent.Heuristics against a bounded snapshot of the visible rows only, with structured events still taking precedence and screen text never triggering any action
- [ ] #2 Output activity is the authority for working, and leaving working for idle requires a debounce (consecutive quiet confirmations with a time cap) so spinner frames do not flap the glyph; unit tests with recorded screen fixtures cover every harness and the debounce
- [ ] #3 A hand-started real Claude Code on Linux shows '? claude input' at its prompt-for-input and '! claude permission' at a tool approval prompt, observed through the sidebar agent row, with the evidence recorded in the task
- [ ] #4 The deterministic Linux --agent-test and the agent-notifications e2e scenario drive the fake agent's screen patterns through real PTYs and SDL input, including the debounce, and AGENTS.md and docs/agents.md describe the screen layer and its limits
<!-- AC:END -->
