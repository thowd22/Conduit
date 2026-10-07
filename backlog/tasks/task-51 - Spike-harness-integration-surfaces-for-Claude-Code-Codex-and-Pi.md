---
id: TASK-51
title: 'Spike: harness integration surfaces for Claude Code, Codex and Pi'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 17:29'
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
- [x] #1 Capability matrix covers status, notifications, transcript access, permission prompts, prompt/instruction access and subagents for all three harnesses
- [x] #2 For each harness the chosen integration mechanism is named with a minimal working proof
- [x] #3 Gaps where a harness cannot support a feature are listed with fallbacks
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. For each harness (Claude Code, Codex CLI, Pi) read the installed CLI's help, docs and on-disk session/transcript layout; probe hooks, notification events, headless/JSON/RPC/SDK modes, permission prompt handling, prompt/instruction exposure, subagents, session resume and SSH behaviour with minimal local proofs inside an isolated HOME.
2. Record the capability matrix as a backlog doc and the adapter strategy as a backlog decision, listing gaps and fallbacks per harness.
3. Note anything that changes TASK-52's adapter interface shape.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Spike evidence recorded in doc-3 (capability matrix) and decision-7 (adapter strategy, status proposed). Versions: Claude Code 2.1.292, Codex 0.160.1, Pi 0.73.1, omp 18.6.1; OpenCode not installed (docs only, marked unverified).
Proven live (structure only logged, no transcript content):
- Claude Code: claude -p stream-json with --permission-prompt-tool stdio emitted control_request can_use_tool, answered allow, tool ran; --include-hook-events and --settings command hooks covered SessionStart/UserPromptSubmit/PreToolUse/PermissionRequest/PostToolUse/Stop/SessionEnd. Interactive TUI in tmux: a PermissionRequest hook waiting on an external decision answered the prompt; ~/.claude/sessions/<pid>.json tracked status waiting/idle (undocumented).
- Codex (isolated CODEX_HOME + local mock Responses endpoint, account at usage limit): codex exec --json events, hooks and notify agent-turn-complete; app-server stdio approval round-trip (thread/status waitingOnApproval, item/commandExecution/requestApproval accepted); a manually started TUI on the shared daemon was observed and its approval answered by a second WebSocket-over-Unix-socket client; hooks inherit the PTY environment with and without the daemon.
- Pi (isolated PI_CODING_AGENT_DIR + local mock Chat Completions endpoint): pi --mode rpc events agent_start..agent_end, a gate extension's ctx.ui.confirm surfaced as extension_ui_request confirm and was answered over RPC; session JSONL v3 written.
Not proven: OpenCode, omp live, Claude Notification hook/OSC 9, Codex TUI OSC 9, SSH. Side effects outside the repo: Claude folder-trust entry for a scratch dir in ~/.claude.json and two scratch transcripts under ~/.claude/projects; no harness settings changed.

Coordinator review 2026-10-07: doc-3 covers status, notifications, transcripts, permissions, instructions and subagents for Claude Code 2.1.292, Codex 0.160.1 and Pi 0.73.1 (omp 18.6.1 and OpenCode from docs only). Live proofs: Claude headless stream-json + hooks + PermissionRequest hook in the TUI; Codex exec --json, hooks, notify and app-server approval round trip against a local mock Responses endpoint (account at usage limit, isolated CODEX_HOME); Pi RPC gate extension with confirm answered over RPC. Decision-7 accepted as the adapter strategy.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Produced doc-3 (capability matrix with per-harness verdicts, minimal proofs, gaps/fallbacks, SSH section and TASK-52 implications) and decision-7 (TUI in a Conduit PTY plus each harness's structured side channel, PTY heuristics as the harness-neutral baseline). Verified by live probes of Claude Code, Codex (mock endpoint) and Pi inside isolated homes; OpenCode and omp documented from docs/help only.
<!-- SECTION:FINAL_SUMMARY:END -->
