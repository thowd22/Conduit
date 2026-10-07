---
id: TASK-70
title: User documentation and README
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 20:19'
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
- [x] #1 README explains what Conduit is, how to install and how to build from source
- [x] #2 Configuration and keybinding reference is complete
- [x] #3 Agent setup is documented for Claude Code, Codex and Pi
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. README: what Conduit is, screenshots from the deterministic checks, install (release assets: tar.gz, deb, AppImage) and build-from-source.
2. docs/config.md completeness pass plus a keybinding reference generated from the default binding tables; themes, fonts, scratchpad, palette, settings view.
3. Agent setup per harness (Claude Code, Codex, Pi, OpenCode) from doc-3/decision-7, marked as the current state; test driver and MCP usage for agents.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Agent: README.md (new) with four real screenshots under docs/images, docs/user-guide.md (keybinding tables generated from src/input.zig), docs/agents.md; fixed docs/config.md theme dir and docs/release.md licence list; install flow verified on v0.1.7 assets; found that Claude Code rejects conduit-test's MCP tool list (allOf wrapper without top-level type). Coordinator 2026-10-07: merged; fixed writeTool to emit "type":"object" with a test over every tool (657/665 unit tests pass); removed the Known-issue note.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
README with real screenshots, Linux install and build-from-source instructions, a user guide with the complete configuration and keybinding reference traced to the code, and per-harness agent setup documentation; the write-up surfaced and led to a fix of the MCP tool-schema bug that blocked Claude Code.
<!-- SECTION:FINAL_SUMMARY:END -->
