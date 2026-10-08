---
id: TASK-59
title: Prompt viewer and editor
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 01:36'
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
- [ ] #1 Prompts and instruction files for an agent are viewable from the agent view
- [ ] #2 Editable items can be modified and saved from within Conduit
- [ ] #3 Items a harness does not allow editing are shown read-only with an explanation
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Prompt viewer from the agent view (agent.prompts action and a row in the view): lists the user prompts sent (from the event log), project instruction files found through the workspace ExecutionContext (CLAUDE.md, AGENTS.md, .claude/*.md, .codex/instructions, AGENTS.md for Codex, Pi's config, OpenCode's instructions per the adapters' knowledge) and subagent/custom agent definitions where exposed (.claude/agents/*.md), each with editable/read-only state and a reason.
2. Editable items open in a terminal-style editor surface (reuse the inline Input for single-line, otherwise hand off to vi in a pane through the ExecutionContext) and save through writeFile; where a harness supports resend/apply (Claude --append-system-prompt on relaunch) offer it, else document.
3. Read-only items show the harness's reason. --agent-prompts-test with the fake adapter and a fixture project; docs.
<!-- SECTION:PLAN:END -->
