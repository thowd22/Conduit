---
id: TASK-70
title: User documentation and README
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 19:57'
labels:
  - docs
milestone: m-8
dependencies:
  - TASK-37
priority: medium
ordinal: 70000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
README with screenshots and install instructions, plus docs for configuration, keybindings, themes, scratchpad, SSH workspaces, agent setup per harness and the test driver.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 README explains what Conduit is, how to install and how to build from source
- [ ] #2 Configuration and keybinding reference is complete
- [ ] #3 Agent setup is documented for Claude Code, Codex and Pi
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. README: what Conduit is, screenshots from the deterministic checks, install (release assets: tar.gz, deb, AppImage) and build-from-source.
2. docs/config.md completeness pass plus a keybinding reference generated from the default binding tables; themes, fonts, scratchpad, palette, settings view.
3. Agent setup per harness (Claude Code, Codex, Pi, OpenCode) from doc-3/decision-7, marked as the current state; test driver and MCP usage for agents.
<!-- SECTION:PLAN:END -->
