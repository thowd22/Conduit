---
id: TASK-59
title: Prompt viewer and editor
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 02:10'
labels:
  - agents
  - ui
milestone: m-6
dependencies:
  - TASK-57
priority: medium
ordinal: 59000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
View the prompts behind an agent: the user prompts sent, project instruction files (CLAUDE.md, AGENTS.md and harness equivalents), and subagent/custom agent definitions where the harness exposes them. Edit in a terminal-style editor surface or hand off to $EDITOR in a pane, then save and, where supported, resend or apply.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Prompts and instruction files for an agent are viewable from the agent view
- [x] #2 Editable items can be modified and saved from within Conduit
- [x] #3 Items a harness does not allow editing are shown read-only with an explanation
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Prompt viewer from the agent view (agent.prompts action and a row in the view): lists the user prompts sent (from the event log), project instruction files found through the workspace ExecutionContext (CLAUDE.md, AGENTS.md, .claude/*.md, .codex/instructions, AGENTS.md for Codex, Pi's config, OpenCode's instructions per the adapters' knowledge) and subagent/custom agent definitions where exposed (.claude/agents/*.md), each with editable/read-only state and a reason.
2. Editable items open in a terminal-style editor surface (reuse the inline Input for single-line, otherwise hand off to vi in a pane through the ExecutionContext) and save through writeFile; where a harness supports resend/apply (Claude --append-system-prompt on relaunch) offer it, else document.
3. Read-only items show the harness's reason. --agent-prompts-test with the fake adapter and a fixture project; docs.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Landed in 5416a2c: InstructionProfile per adapter, src/agent_prompts.zig discovery through the context on a worker, agent.prompts modal with editable/read-only rows and reasons, vi (or vi -R) editing through openEditorTab with re-read on exit, 'restart with updated instructions' for Claude Code; --agent-prompts-test (30 checks) and the twentieth scenario agent-prompts; --ui-test registry now 83 actions. Coordinator 2026-10-08: merged; screenshot inspected; discovery uses ~ paths only.

Coordinator 2026-10-08: gate green; prompts view screenshot inspected.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Prompt viewer and editor: an agent's sent prompts and the instruction files its harness reads are listed from the agent view with editable or read-only state and a reason, editable files open in vi through the ExecutionContext and are re-read on save, and Claude Code can be restarted with updated instructions; verified by unit tests, --agent-prompts-test and the agent-prompts scenario.
<!-- SECTION:FINAL_SUMMARY:END -->
