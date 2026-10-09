---
id: TASK-87
title: Agent view shows reasoning and tool output from every harness
status: Done
assignee:
  - '@opus-5.5'
created_date: '2026-10-09 04:52'
updated_date: '2026-10-09 05:40'
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
- [x] #1 agent.Event has reasoning and tool_result variants with bounded copies through EventQueue and the view's EventLog; the all-kinds unit tests cover them
- [x] #2 The Claude Code adapter emits reasoning from transcript thinking blocks and tool_result from PostToolUse and the transcript's tool results, proven by fixtures recorded from Claude Code 2.1.292
- [x] #3 The Codex adapter emits reasoning from item/reasoning notifications and tool_result from completed command and file-change items, proven by fixtures recorded from Codex 0.160.1
- [x] #4 The Pi adapter emits reasoning from session thinking content and tool_result from tool results, proven by fixtures recorded from Pi 0.73.1
- [x] #5 The OpenCode adapter emits reasoning from reasoning parts and tool_result from completed tool parts, proven by fixtures recorded from OpenCode 1.18.35
- [x] #6 The agent view renders reasoning as dim wrapped rows and a tool result under its tool use, within the existing entry and byte budgets, and the fake adapter's script plus --agent-view-test and the agent-view scenario show both
- [x] #7 docs/agents.md describes what each harness contributes to the view; AGENTS.md records the change
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. agent.Event gains reasoning {text, truncated} and tool_result {name, summary, failed, truncated}; StoredEvent and the view EventLog copy them under the existing bounds; event.summaryLine gives every adapter the same one-line summary.
2. agent_view: Kind.reasoning (dim wrapped rows under '∴ ') and Kind.tool_result (one row '  ↳ <summary>' under its tool, .danger when failed, naming the tool only when the rows above are not its own); Row.ordinal numbers both for stable semantic ids.
3. Adapters, each proven by a fixture recorded from the pinned version against a local model stand-in: Claude Code 2.1.292 (transcript thinking, PostToolUse/PostToolUseFailure hooks, transcript tool_result blocks without hooks); Codex 0.160.1 (completed reasoning, commandExecution and fileChange items; rollout reasoning and tool outputs); Pi 0.73.1 (conduit.js forwards thinking and tool output; sink, RPC and session readers); OpenCode 1.18.35 (ended reasoning parts, completed/error tool parts, bash metadata.exit).
4. docs/agents.md section; the fake's lifecycle test replays both kinds.
5. Hand the coordinator a verified diff for src/app_agents.zig (fake scripts), src/main.zig (ids agent.view.<a>.reasoning.<n> and .result.<n>, --agent-view-test checks) and e2e/scenarios.zig (agent-view waits), which other agents own.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented on branch worktree-agent-a7ce4213cedc76323 (commits 6fb3851..).

Recordings (all against local model stand-ins, no account, no network model; private paths scrubbed to /home/user, /work):
- Claude Code 2.1.292: `claude -p --permission-mode default --allowedTools Bash,Read` in an isolated HOME against a Messages API stand-in that answers every request with a thinking block and walks printf (two lines), a failing `ls`, a Read. Fixtures: src/agent/claude_code/fixtures/transcript-tools.jsonl (user/assistant records only), hooks-tools.jsonl (PostToolUse, PostToolUseFailure, PostToolUse wrapped as the relay writes them). Real shapes: PostToolUse tool_response {stdout, stderr, interrupted, ...} for Bash and {type, file:{filePath, content, numLines,...}} for Read; PostToolUseFailure carries `error` ("Exit code 2\nls: ..."); transcript tool_result blocks carry string content and is_error.
- Codex 0.160.1: the real app-server over stdio (approvalPolicy never, danger-full-access) against a Responses stand-in whose responses carry a reasoning item with a summary; printf, failing ls, apply_patch through the shell. item/completed reasoning has summary:[string], content:[]; commandExecution has aggregatedOutput, exitCode, status completed|failed; fileChange has changes[{path, kind:{type}, diff}], status. Fixtures test/fixtures/agent/codex/app-server-reasoning-0.160.1.jsonl and rollout-reasoning-0.160.1.jsonl (developer instructions and environment context trimmed as before).
- Pi 0.73.1: `pi --mode rpc -e conduit.js` against a Chat Completions stand-in streaming reasoning_content (Pi turns it into thinking blocks). Fixtures src/agent/pi/testdata/rpc_reasoning_events.jsonl (update lines dropped), sink_reasoning_events.jsonl, session_reasoning_v3.jsonl. tool_execution_end carries result.content and isError; a failing bash's text ends "Command exited with code 2".
- OpenCode 1.18.35: `opencode serve` inside conduit-opencode-check:1.18.35 (nothing installed on the host), permission bash/read allow, stand-in streams reasoning_content. Fixtures test/fixtures/agent/opencode/recorded-reasoning-turn.sse (startup announcements dropped, header comment) and recorded-reasoning-messages.json. Finding: a bash that exits 2 stays `completed` with metadata.exit = 2; a read of a missing file is status `error` with `error`.

Design notes: transcript tool results are emitted only when no hook channel reports them (as tool uses already were); Claude transcript results carry no tool name (the view shows them under the tool use above). Codex and OpenCode prefix a non-zero exit as `exit N: <first line>`. Pi's extension cuts tool output to 500 characters and thinking to 4000 and flags the cut. Codex's max file references per message dropped by one to leave room for the result. OpenCode keys a tool part's result separately in its seen-set so a part reports its use once and its result once.

Verification: zig fmt; zig build; zig build test = 1044/1068 passed, 22 skipped, 2 failed: both platform driver-transport tests fail with EndpointTooLong because this worktree's path makes the temp Unix socket path exceed the sockaddr_un limit (environmental, not this change). The agent module's 3 skips include the live OpenCode test (opencode not installed on the host). xvfb-run -a zig build run -- --agent-view-test: 0 failures. With the coordinator diff applied locally: --agent-view-test, --agent-test, --agent-manager-test 0 failures each, zig build test clean except the same two platform tests, `zig build e2e` 22/22 passed; the view screenshots showed the dim wrapped ∴ reasoning and the red ↳ result row.

Coordinator diff (not committed here; other agents own those files): scratchpad t87/coordinator.diff, reproduced in the hand-off report.

AGENTS.md paragraph (proposed): TASK-87 is complete on Linux. agent.Event gained `reasoning` (text, truncated) and `tool_result` (name, one-line summary, failed, truncated), copied through EventQueue and the view's EventLog under the existing bounds. The agent view draws reasoning as dim rows wrapped under a `∴` prefix and a tool result as one `↳ <first line>` row under its tool, in the danger colour when it failed; the first row of each reasoning block and each result row register as `agent.view.<a>.reasoning.<n>` and `agent.view.<a>.result.<n>`. Claude Code reports transcript thinking blocks and PostToolUse/PostToolUseFailure results (transcript tool_result blocks when no hooks run); Codex completed reasoning summaries and commandExecution/fileChange results, and its rollout reader both; Pi's extension forwards thinking and tool output, and its sink, RPC and session readers map them; OpenCode ended reasoning parts and completed or errored tool parts, where a bash that exits non-zero stays `completed` with `metadata.exit`. Each is proven by fixtures recorded from the pinned version (Claude Code 2.1.292, Codex 0.160.1, Pi 0.73.1, OpenCode 1.18.35 in its container) against local model stand-ins; the fake's scripts carry both kinds, and --agent-view-test and the agent-view scenario check them. Reasoning only appears when the model returns it; real accounts were not used.

Coordinator: merged at d329749; the coordinator diff (fake scripts, view ids agent.view.<a>.reasoning.<n>/.result.<n>, agent-view scenario waits) landed in ce0e881; --agent-view-test, --agent-test, --agent-manager-test and the full gate passed on main.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
agent.Event gained reasoning and tool_result; all four adapters emit them from their structured channels, proven by fixtures recorded from Claude Code 2.1.292, Codex 0.160.1, Pi 0.73.1 and OpenCode 1.18.35 against local stand-ins; the agent view draws reasoning as dim ∴ rows and results as ↳ rows (danger when failed). Verified by the adapter and view unit tests, --agent-view-test, the agent-view scenario and the full local gate.
<!-- SECTION:FINAL_SUMMARY:END -->
