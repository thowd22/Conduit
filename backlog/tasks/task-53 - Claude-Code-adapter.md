---
id: TASK-53
title: Claude Code adapter
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 20:15'
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
