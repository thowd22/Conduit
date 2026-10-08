---
id: TASK-79
title: Embedded VSCodium editor pane exposed to harnesses as a tool
status: To Do
assignee: []
created_date: '2026-10-08 03:39'
labels:
  - editor
  - agents
  - ui
milestone: m-6
dependencies:
  - TASK-60
  - TASK-30
  - TASK-34
priority: medium
ordinal: 80000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user wants VSCodium embedded in Conduit and exposed to the coding-agent harnesses as a tool, the way Conduit already exposes tabs, panes and views through the control API (TASK-60). An LLM running in a harness inside Conduit (Claude Code, Codex, Pi, OpenCode) must be able to spawn the editor like it would spawn $EDITOR, open a file at a line (and column), jump to another file or line in an editor that is already open, and perform the other editor tasks a harness commonly needs (open a diff, reveal a file, close the editor); a human must get the same actions from the palette and the context menu. The editor appears as a split pane in the current tab, exactly like a new pane created by pane.split, and behaves like a pane for focus, resize, zoom and close.

Design notes a future agent cannot recover from the code: (1) VSCodium is an Electron application with its own native window; Conduit draws into one SDL/OpenGL window, so 'embedded' needs a decision: on X11 the VSCodium window can be reparented into a child window that Conduit positions over the pane rectangle (XEmbed/XReparentWindow; the pane rectangle tracks resizes and sidebar changes), Wayland has no reparenting, so there the fallback is a separate VSCodium window placed and sized beside Conduit and tracked, and macOS/Windows need native child-window hosting (NSView/HWND SetParent) behind platform; record the chosen strategy per platform as a Backlog decision before implementing. (2) VSCodium must be launched through the workspace ExecutionContext (invariant 5): locally as 'codium' (or a configured path, editor.vscodium setting) with --reuse-window/--goto file:line:col and a per-workspace --user-data-dir so Conduit-owned instances never fight the user's own; in an SSH workspace the pane should drive VSCodium's remote tunnel or fall back to vi in a pane with an explicit message. (3) The harness surface is the control API: new methods editor.open {path, line?, column?, split?: right|down}, editor.goto {path, line?, column?}, editor.diff {left, right}, editor.reveal {path}, editor.close, scoped to the caller's workspace and never the scratchpad, reachable via 'conduit control' and documented for each harness (hook/tool snippets in docs/control-api.md) and as a conduit-test/MCP tool; paths are resolved by the context, never locally for remote workspaces, and nothing executes editor text. (4) VSCodium is not bundled: Conduit detects an installed 'codium' through the context (editor.detect, like the harness detect), offers the actions only when found, and tells the user how to install it otherwise (no silent installs). (5) Keyboard and mouse parity: palette 'Editor: open file…', context-menu 'Open in editor' over a file reference, and the same pane chords; the editor pane is a semantic element the driver can inspect and wait for.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A Backlog decision records the per-platform embedding strategy (X11 reparenting into a pane-tracked child window, Wayland fallback, macOS and Windows native hosting) and which parts are implemented now
- [ ] #2 With VSCodium installed, 'Editor: open file' from the palette and 'Open in editor' from the context menu over a file reference open VSCodium in a new split pane of the current tab at the referenced file and line; the pane follows focus, resize, zoom and close like any other pane, and Escape/close returns the space to the sibling
- [ ] #3 A process inside a Conduit terminal (and therefore a harness) can call editor.open, editor.goto, editor.diff, editor.reveal and editor.close through the control API scoped to its workspace; a second editor.open or editor.goto reuses the open editor pane instead of spawning another; the scratchpad cannot be targeted
- [ ] #4 The editor launches through the workspace ExecutionContext with a per-workspace user-data-dir and never touches the user's own VSCodium instance or settings; when VSCodium is not installed the actions are hidden and 'conduit control editor.open' replies with a clear fault naming how to install it
- [ ] #5 The harness-facing documentation (docs/control-api.md and docs/agents.md) shows each harness how to use the editor tool, and a conduit-test/MCP tool mirrors editor.open and editor.goto for driving the app
- [ ] #6 A deterministic Linux check (and an e2e scenario where the runner can provide a stand-in 'codium') proves open-at-line, goto in the open pane, diff, reveal and close through the real input and control paths, with an inspected screenshot of the editor pane beside a terminal pane; behaviour without VSCodium installed is covered too
<!-- AC:END -->
