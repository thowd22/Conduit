---
id: TASK-34
title: Clickable links and file references in terminals
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 21:13'
labels:
  - mouse
  - terminal
milestone: m-3
dependencies:
  - TASK-14
  - TASK-19
modified_files:
  - e2e/scenarios.zig
  - e2e/runner.zig
priority: high
ordinal: 34000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Detect URLs, OSC 8 hyperlinks and file references (path, path:line, path:line:col) in terminal output. Hover with the modifier underlines them; Ctrl+click (Cmd+click on macOS) opens URLs in the browser and file references through a configurable editor action, resolving relative paths against the session cwd.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Ctrl/Cmd+click on a URL opens the system browser
- [x] #2 OSC 8 hyperlinks are honored
- [x] #3 path:line references open the configured editor command at that location
- [x] #4 Detected links appear in the semantic tree so the test driver can ctrl_click them
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add a bounded pure detector/parser for http/https URLs and explicit file/path:line[:col] references with conservative punctuation, UTF-8, control and overflow rules.
2. Expose borrowed OSC 8 URI metadata from the terminal cell API and combine it with lexical detection, giving OSC 8 precedence.
3. Add platform URL opening and ExecutionContext-owned file/editor dispatch after resolving the editor presentation contract.
4. Register visible spans once in the semantic tree, add modifier-only decoration/routing, and preserve ordinary terminal click/drag/mouse-report behavior.
5. Add deterministic real-SDL E2E coverage, docs, formatting/build/unit/all Linux checks, screenshot inspection and independent AC audit.

6. Implement decision-5 file-reference dispatch: register file matches as terminal_link elements, open a new tab through the workspace ExecutionContext with shell-free argv vi +<line> -- <path> resolved against the session's tracked cwd, cover it in --links-test and a scripted E2E scenario.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
URL/OSC 8 slice implemented and coordinator-verified. `--links-test` passed under real X11/SDL/OpenGL: lexical and OSC 8 links appeared in the semantic tree, malformed OSC 8 metadata masked URL-looking labels, plain clicks remained DEC mouse gestures, modifier hover painted decoration-only underline, and modified clicks dispatched the exact copied lexical/OSC targets through the injected opener seam. Platform URL opening independently validates bounded HTTP(S) input before SDL_OpenURL. Stable semantic ids now use a domain-separated 128-bit SHA-256 fingerprint rather than a collision-prone non-cryptographic hash. Full unit/build gate passed. AC3 awaits the user-selected v0.1 editor default; AC4 awaits an actual conduit-test ctrl_click scenario rather than only the built-in real-SDL path.

AC4 coordinator evidence: the scripted E2E runner now includes a `terminal-links` scenario. A deterministic child prints only the reserved TEST-NET URL `https://192.0.2.1/conduit-e2e`; the runner waits for its exact production-derived `terminal_link` semantic id, invokes `conduit-test ctrl-click`, and captures the result. `zig build e2e` reported all four scenarios PASS. The retained semantic-tree JSON contains the expected id and the visually inspected 640x360 PNG shows the URL underlined. Unit tests independently recompute the domain-separated fingerprint/id and pin the `ctrl-click` CLI dispatch.

2026-10-06 AC3 landed under decision-5: lexical file references (path, path:line, path:line:col) register as terminal_link elements with a .file fingerprint id; ctrl-click snapshots the source session's OSC 7 cwd (workspace cwd fallback), resolves a relative path against it without touching the filesystem, creates a new tab labelled with the file name and spawns shell-free argv vi +<line> -- <path> (or vi -- <path>) through the workspace ExecutionContext with job-owned argv freed on every Load completion path; an EditorSpawnObserver seam exposes the exact argv/cwd to tests while the real path always spawns vi. Found and fixed: in --command mode childGone() returned true while a new tab's spawn worker was in flight, so the app quit right after creating a tab. Evidence: --links-test 15 ok / 0 failures (exact 'vi +3 -- /tmp/conduit-notes.txt' with cwd /tmp and 'vi -- /tmp/conduit-abs.txt', plain click stays a DEC report with no tab, real vim draws its path in the new tab); new scripted scenario terminal-file-reference passes through conduit-test ctrl-click and the coordinator inspected its 640x360 PNG showing the selected cdt-e2e.txt tab and vim's '"/tmp/cdt-e2e.txt" [New]' status line; zig build test 511 passed / 7 skipped; e2e 5/5 PASS.
<!-- SECTION:NOTES:END -->

## Comments

<!-- COMMENTS:BEGIN -->
created: 2026-10-06 19:53
---
User approved the Linux-first v0.1 default: open file references in a new Conduit tab through the workspace ExecutionContext using shell-free argv vi +<line> -- <path> (or vi -- <path> without a line). Recorded as decision-5.
---
<!-- COMMENTS:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Terminal links are complete on Linux: visible HTTP(S) URLs, OSC 8 hyperlinks and file references are bounded, stable terminal_link semantic elements; Ctrl+click (Command on macOS) opens URLs through platform.openUrl and opens file references in a new tab running vi +line -- path via the workspace ExecutionContext (decision-5), while plain clicks, drags and DEC mouse reporting stay terminal input. Verified by unit tests, the deterministic real-SDL --links-test (15 checks), the terminal-links and terminal-file-reference scripted E2E scenarios with inspected screenshots, and the full zig build test gate. macOS/Windows runtime behaviour remains unverified.
<!-- SECTION:FINAL_SUMMARY:END -->
