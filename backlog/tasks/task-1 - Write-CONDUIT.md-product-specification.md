---
id: TASK-1
title: Write CONDUIT.md product specification
status: Done
assignee:
  - '@omp'
created_date: '2026-10-03 21:38'
updated_date: '2026-10-04 18:37'
labels:
  - docs
milestone: m-0
dependencies: []
modified_files:
  - CONDUIT.md
  - AGENTS.md
priority: high
ordinal: 1000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Distill conversation.md into a durable product spec at the repo root: product concept, principles (terminal look and feel, keyboard/mouse parity, no button chrome, scratchpad belongs to the human), feature list with primary/secondary priority (WSL and PowerShell are secondary), glossary (Workspace, ExecutionContext, Session, Scratchpad, Agent, Harness), and explicit v0.1 scope vs later.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 CONDUIT.md exists at the repo root and covers every feature area discussed in conversation.md
- [x] #2 v0.1 scope and non-goals are listed explicitly
- [x] #3 Glossary defines Workspace, ExecutionContext, Session, Scratchpad, Agent and Harness
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Read conversation.md (915 lines) and the 70-task backlog; enumerate every feature area and fix terminology.
2. Write CONDUIT.md at the repo root: concept, principles, architecture invariants, feature catalogue with Primary/Secondary priority, v0.1 scope + explicit non-goals, glossary, testing strategy.
3. Update AGENTS.md truth table so CONDUIT.md is the source of product truth.
4. Verify coverage: every conversation.md feature area maps to a spec section and a backlog task; check all three ACs with evidence.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision (user): v0.1 = milestones M0-M3, not M0-M4. Config/theme/font v2, SSH, agents and backlog.md all land after v0.1.
Decision (user): TASK-31 AC #3 amended via CLI - v0.1 palette covers new tab and split pane; commands for features that have not landed appear when they land. Keeps the v0.1 boundary; TASK-31 stays in M3.
Two independent read-only audits were run against conversation.md and all 70 task files. First audit found 8 coverage gaps, 2 milestone-attribution errors, 6 scope contradictions and 4 glossary defects; all were fixed and a second audit confirmed every fix with no regressions.
Mechanical verification: 65 catalogue rows parsed against task frontmatter - v0.1 column equals 'milestone in M0-M3' on every row, no missing task ids. Section 6 ranges partition TASK-1..70 exactly and agree with every task's milestone. All six required glossary terms defined (plus Adapter). 30 code fences balanced, 0 duplicated adjacent lines.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Created CONDUIT.md at the repo root (702 lines, 14 sections): product concept and name rationale, 12 product principles P1-P12, the Workspace/ExecutionContext/Session model, a 65-row feature catalogue with Primary/Secondary priority and a v0.1 column, explicit v0.1 scope (M0-M3) with seven non-goals, the full milestone map, interaction model, fonts, scratchpad lifecycle, testing and agent development loop, safety invariants, open questions keyed to spikes, and a glossary (Workspace, ExecutionContext, Session, Scratchpad, Agent, Harness, Adapter). Updated AGENTS.md so CONDUIT.md is the source of product truth and conversation.md is history. Verified by two independent audits against conversation.md and all 70 backlog tasks plus a scripted check that the v0.1 column, the M0-M8 ranges and the glossary match the backlog. Amended TASK-31 AC #3 per user decision so the v0.1 palette does not require commands for unlanded features.
<!-- SECTION:FINAL_SUMMARY:END -->
