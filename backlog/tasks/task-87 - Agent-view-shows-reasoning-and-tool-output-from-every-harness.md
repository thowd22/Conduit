---
id: TASK-87
title: Agent view shows reasoning and tool output from every harness
status: To Do
assignee: []
created_date: '2026-10-09 04:52'
labels:
  - agents
  - ui
milestone: m-6
dependencies:
  - TASK-57
  - TASK-78
priority: high
ordinal: 88000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user wants to see an agent's output and reasoning when they open it. The structured agent view (TASK-57) shows messages, tool uses, file references, permissions and dim status lines, but every adapter drops the harness's reasoning and tool results: Claude Code's transcript reader skips thinking blocks (src/agent/claude_code.zig, TranscriptReader) and PostToolUse hook inputs carry tool_response that is not surfaced; the Codex adapter ignores item/reasoning/* notifications and command output items (src/agent/codex.zig); the Pi adapter leaves thinking and tool results out of SessionReader (src/agent/pi.zig); the OpenCode adapter drops reasoning message parts and tool part output (src/agent/opencode.zig). Add two event kinds to the typed agent.Event union, reasoning (bounded text, truncated flag) and tool_result (tool name, one-line summary, failed flag), copied and queued like messages, emitted by each adapter from its structured channel (hooks and transcript, app-server JSON-RPC and rollout, session JSONL and RPC, SSE and message replay), and rendered by the view as dim wrapped rows (reasoning) and as a result line under the tool use (tool_result). Reasoning text is untrusted: sanitised, bounded by the view's existing byte budget, displayed only, never acted on, never logged. Keep invariant 9: the view knows the event kinds, not the harnesses. Fixtures: extend the recorded fixtures under src/agent/*/fixtures and testdata with scrubbed samples containing reasoning and tool output from the real harness versions already pinned there (Claude Code 2.1.292, Codex 0.160.1, Pi 0.73.1, OpenCode 1.18.35); the scripted fake (src/agent/fake.zig) gains both kinds so --agent-view-test can show them.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 agent.Event has reasoning and tool_result variants with bounded copies through EventQueue and the view's EventLog; the all-kinds unit tests cover them
- [ ] #2 The Claude Code adapter emits reasoning from transcript thinking blocks and tool_result from PostToolUse and the transcript's tool results, proven by fixtures recorded from Claude Code 2.1.292
- [ ] #3 The Codex adapter emits reasoning from item/reasoning notifications and tool_result from completed command and file-change items, proven by fixtures recorded from Codex 0.160.1
- [ ] #4 The Pi adapter emits reasoning from session thinking content and tool_result from tool results, proven by fixtures recorded from Pi 0.73.1
- [ ] #5 The OpenCode adapter emits reasoning from reasoning parts and tool_result from completed tool parts, proven by fixtures recorded from OpenCode 1.18.35
- [ ] #6 The agent view renders reasoning as dim wrapped rows and a tool result under its tool use, within the existing entry and byte budgets, and the fake adapter's script plus --agent-view-test and the agent-view scenario show both
- [ ] #7 docs/agents.md describes what each harness contributes to the view; AGENTS.md records the change
<!-- AC:END -->
