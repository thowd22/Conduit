---
id: TASK-53
title: Claude Code adapter
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 20:44'
labels:
  - agents
  - claude
milestone: m-6
dependencies:
  - TASK-52
priority: high
ordinal: 53000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Adapter for Claude Code CLI per the spike: launch and attach, map hook and transcript events into the agent event stream, surface status and permission requests, expose subagents, and read prompts/instructions where supported. Detect Claude Code started manually in any Conduit terminal.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Claude Code launched from Conduit appears in the agent registry with live status
- [ ] #2 Permission requests and completion produce agent events
- [ ] #3 Tool uses and file references are captured as structured events
- [ ] #4 A manually started claude process in a Conduit terminal is detected
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Implement agent.Adapter for Claude Code in src/agent/claude_code.zig per decision-7: detect via the context (claude --version), launch builds argv/env with --settings injecting hooks (SessionStart, UserPromptSubmit, Pre/PostToolUse, PermissionRequest, Notification, Stop, SubagentStart/Stop, SessionEnd) that append JSON lines to a per-agent sink file plus --session-id; poll tails the sink into typed Events; respondPermission answers through the PermissionRequest hook reply channel; transcript JSONL for history; stop sends SIGINT/kill through the owner.
2. Detect hand-started sessions by the correlation token in hook payloads or the undocumented PID registry (best effort).
3. Unit tests from recorded hook/transcript fixtures; an integration test runs the real hook command path without a model call.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Adapter landed (20df52f, dc3e464 rebased onto main as 626b155): ClaudeCodeAdapter writes a per-agent sink (settings.json hooks + POSIX hook.sh relay), launch = claude --settings <sink>/settings.json --session-id <uuid from token>; poll tails events.jsonl into typed events (Stop -> done; observed SessionEnd -> exited); PermissionRequest blocks up to 580 s until respondPermission writes <sink>/decisions/<id>, replying hookSpecificOutput.decision.behavior allow/deny; TranscriptReader; findRunningSession over the undocumented <config>/sessions/<pid>.json registry. 15 unit tests from fixtures recorded with 2.1.292 plus integration tests running the relay through a Local PTY, an unauthenticated real claude -p whose hooks reached poll, and a real interactive claude found, attached and seen to exit. 716/725 unit tests pass on main. Real 2.1.292 field names: SessionEnd.reason, StopFailure.error. Pending: UI gesture path (TASK-57/58), control endpoint instead of the sink (TASK-60), remote contexts (TASK-61); an authenticated live allow/deny was not run (no credentials).
<!-- SECTION:NOTES:END -->
