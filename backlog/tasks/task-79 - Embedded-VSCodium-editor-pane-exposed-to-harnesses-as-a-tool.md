---
id: TASK-79
title: Embedded VSCodium editor pane exposed to harnesses as a tool
status: Done
assignee: []
created_date: '2026-10-08 03:39'
updated_date: '2026-10-08 14:26'
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
- [x] #1 A Backlog decision records the per-platform embedding strategy (X11 reparenting into a pane-tracked child window, Wayland fallback, macOS and Windows native hosting) and which parts are implemented now
- [x] #2 With VSCodium installed, 'Editor: open file' from the palette and 'Open in editor' from the context menu over a file reference open VSCodium in a new split pane of the current tab at the referenced file and line; the pane follows focus, resize, zoom and close like any other pane, and Escape/close returns the space to the sibling
- [x] #3 A process inside a Conduit terminal (and therefore a harness) can call editor.open, editor.goto, editor.diff, editor.reveal and editor.close through the control API scoped to its workspace; a second editor.open or editor.goto reuses the open editor pane instead of spawning another; the scratchpad cannot be targeted
- [x] #4 The editor launches through the workspace ExecutionContext with a per-workspace user-data-dir and never touches the user's own VSCodium instance or settings; when VSCodium is not installed the actions are hidden and 'conduit control editor.open' replies with a clear fault naming how to install it
- [x] #5 The harness-facing documentation (docs/control-api.md and docs/agents.md) shows each harness how to use the editor tool, and a conduit-test/MCP tool mirrors editor.open and editor.goto for driving the app
- [x] #6 A deterministic Linux check (and an e2e scenario where the runner can provide a stand-in 'codium') proves open-at-line, goto in the open pane, diff, reveal and close through the real input and control paths, with an inspected screenshot of the editor pane beside a terminal pane; behaviour without VSCodium installed is covered too
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Phase one merged to main (94847f5): decision-12, src/editor.zig model, editor.* control methods and faults, conduit-test/MCP editor tools, docs, and the X11 foreign-window hosting seam in platform (dlopen'ed Xlib, tested under Xvfb with xlogo). The app answers Unavailable until phase two wires main.zig and the workspace pane leaf.

Phase two merged to main (7864057, rebased cleanly). Evidence: --editor-test (29+ checks through real SDL events and a real tab shell typing conduit control editor.*), the twenty-second e2e scenario editor-pane, 22/22 scenarios locally, X root captures of a visible run showing the stand-in's xlogo window hosted beside the terminal pane under the 'editor ─ notes.txt:2  × close' header; not-installed path proven (no palette row, control fault with the vscodium.com hint). Known limits: restore saves the editor pane as a terminal pane; quitting leaves a hosted window on the desktop; closing a last tab's only editor pane quits. Unverified: real VSCodium (never installed on this box), typing into a reparented Electron window, the Wayland separate-window fallback, macOS and Windows hosting (decision-12 records them as later work).

Coordinator 2026-10-08, with the user's approval: real VSCodium 1.135.06055 (private tarball under .zig-cache/vscodium, checksum verified) driven through Conduit under Xvfb with a visible window: editor.open hosted the real window over pane 2 within 1.6 s, the real file showed, editor.goto moved the cursor and header to notes.txt:4:1, XTest typing inserted at the cursor, editor.close ended the process; root captures inspected. Findings: the tarball needs a wrapper with --no-sandbox on this AppArmor-restricted kernel (package installs set the setuid helper); relative paths from a shell without OSC 7 resolve against the workspace dir; VSCodium shows Restricted Mode in the fresh user-data-dir.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Embedded editor pane: VSCodium is detected (editor.command or codium) and launched through the workspace ExecutionContext with a per-workspace user-data-dir into a split pane that behaves like any pane; harnesses drive it through the control API's editor.open/goto/diff/reveal/close (reusing the pane, never the scratchpad), humans through the palette and the context menu; on X11 the window is reparented over the pane. Proven with a stand-in editor by --editor-test and the editor-pane scenario; real VSCodium and non-X11 hosting remain unverified.
<!-- SECTION:FINAL_SUMMARY:END -->
