---
id: TASK-24
title: conduit-test MCP server
status: Done
assignee:
  - '@codex'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 03:16'
labels:
  - testing
  - mcp
milestone: m-2
dependencies:
  - TASK-23
modified_files:
  - .mcp.json
  - src/conduit_test.zig
  - AGENTS.md
  - docs/architecture.md
priority: medium
ordinal: 24000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
MCP server exposing launch, inspect, click, key, type, screenshot, terminal_text and wait_for as tools so Claude Code, Codex and Pi share one testing interface. Screenshots are returned as image content. Include a project .mcp.json entry.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 MCP tools mirror the CLI capabilities
- [x] #2 Screenshot tool returns an image the model can view
- [x] #3 Project MCP configuration is checked in and documented
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Define a bounded stdio MCP transport and schemas that mirror every conduit-test CLI capability while reusing its strict command/request helpers.
2. Add launch/run selection and driver dispatch tools, returning text or JSON content and returning screenshot PNG bytes as MCP image content.
3. Check in a project .mcp.json entry and document installation, tool contract, isolation and security boundaries.
4. Unit-test framing/dispatch/schema/error handling, then drive the installed MCP server over stdio against a real isolated Conduit and inspect the returned screenshot.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented a bounded newline-delimited stdio MCP server in src/conduit_test.zig. It exposes all 14 installed CLI capabilities with strict JSON schemas and dispatches through the same run isolation and local driver transport. Current 2026-07-28 discovery requests require per-request metadata and explicit run selection; initialized legacy clients retain connection-local selection. Screenshot results validate the derived artifact path, enforce a 32 MiB bound and PNG signature, and return raw base64 image/png content. Added the Claude Code project .mcp.json and documented Claude Code, Codex and Pi host setup plus protocol and security constraints in AGENTS.md and docs/architecture.md.

Coordinator verification: zig fmt --check and zig build passed. zig build test --summary all passed 368/375 tests with 7 documented platform skips, including 13 conduit-test tests. A live 2026-07-28 stdio session exercised discovery and all 14 tools against a real offscreen 640x360 Conduit run; expected missing semantic IDs returned bounded tool errors, screenshot base64 exactly matched the private PNG, and the inspected image showed MCP_READY plus injected input. The live run kept root/run/manifest permissions at 0700/0700/0600 and left fake user locations untouched. A second live 2025-06-18 initialized session verified legacy tool listing and connection-local run selection. jq validated .mcp.json and git diff --check passed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added the conduit-test MCP server with complete CLI parity, current discovery and legacy initialization support, strict bounded requests, isolated launch/run routing, tool-level error results, and model-viewable PNG screenshot content. Checked in and documented the project MCP configuration and harness-specific setup. Unit, build, modern live, legacy live, image, isolation and permission evidence all pass on Linux; native macOS and Windows runtime coverage remains assigned to their platform CI tasks.
<!-- SECTION:FINAL_SUMMARY:END -->
