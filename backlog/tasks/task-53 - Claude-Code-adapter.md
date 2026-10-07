---
id: TASK-53
title: Claude Code adapter
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 23:39'
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
- [x] #1 Claude Code launched from Conduit appears in the agent registry with live status
- [x] #2 Permission requests and completion produce agent events
- [x] #3 Tool uses and file references are captured as structured events
- [x] #4 A manually started claude process in a Conduit terminal is detected
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

Coordinator 2026-10-07: with TASK-56/57 landed the app path exists end to end: Runtime launches claude --settings <sink>/settings.json --session-id ..., tails the hook relay into the registry (sidebar glyphs, notifications), and the agent view answers PermissionRequest through Runner.answerPermission -> adapter.respondPermission -> decision file -> hook reply. Evidence: adapter integration tests against the real 2.1.292 binary (relay through a Local PTY blocking until the decision file appears and printing the allow/deny reply; an unauthenticated claude -p whose SessionStart/UserPromptSubmit/StopFailure hooks reached poll as idle/working/errored; a hand-started interactive claude found in the registry, attached and seen to exit), transcript fixtures recorded from 2.1.292, and the fake-adapter --agent-test/--agent-view-test for the UI gesture. Not run: an authenticated session answering a real tool-permission prompt (no credentials on this box).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Claude Code adapter: hook-based live status including waiting-for-permission, permission answers delivered through a blocking hook relay from Conduit's agent view, transcript JSONL parsed into structured events, and detection/attachment of hand-started sessions through Claude's session registry; verified against the real 2.1.292 binary in isolated homes plus recorded fixtures, with the UI gesture proven through the fake adapter.
<!-- SECTION:FINAL_SUMMARY:END -->
