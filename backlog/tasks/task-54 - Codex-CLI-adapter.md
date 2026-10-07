---
id: TASK-54
title: Codex CLI adapter
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 20:15'
labels:
  - agents
  - codex
milestone: m-6
dependencies:
  - TASK-52
priority: high
ordinal: 54000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Adapter for Codex CLI per the spike: launch and attach, map its notification and session events into the agent event stream, surface status and approval requests, and read prompts/instructions where supported.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Codex launched from Conduit appears in the agent registry with live status
- [ ] #2 Approval requests and turn completion produce agent events
- [ ] #3 A manually started codex process in a Conduit terminal is detected
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Implement agent.Adapter for Codex in src/agent/codex.zig per decision-7: detect (codex --version, version-gated), launch argv for the TUI on the shared daemon plus hooks/notify fallback, poll via the app-server JSON-RPC over the daemon socket (thread/status/changed, items, approval server requests) with a tolerant parser, respondPermission answers approval requests, rollout JSONL for history.
2. Unit tests from recorded app-server/exec --json fixtures; integration test against a fake app-server speaking the protocol over a local socket (no OpenAI call).
<!-- SECTION:PLAN:END -->
