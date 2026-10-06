---
id: TASK-2
title: 'Spike: libghostty integration boundary and Zig version pin'
status: Done
assignee:
  - '@omp'
created_date: '2026-10-03 21:38'
updated_date: '2026-10-04 20:11'
labels:
  - spike
  - terminal
milestone: m-0
dependencies: []
modified_files:
  - spikes/task-2-vt/build.zig
  - spikes/task-2-vt/build.zig.zon
  - spikes/task-2-vt/src/main.zig
  - spikes/task-2-vt/README.md
  - AGENTS.md
priority: high
ordinal: 2000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Determine exactly what Conduit consumes from Ghostty. Evaluate libghostty-vt (VT parser and terminal state as a Zig module / C API) against the full libghostty embedding API used by the Ghostty macOS app, including API stability, Windows support, what rendering and font code is or is not exposed, key/mouse encoders, and licensing. Pin the Zig version Ghostty requires. Build a throwaway program that feeds bytes into the terminal state and dumps the grid. Record the outcome as a backlog decision.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Decision record states which libghostty artifact is used, at which commit/version, and what Conduit must implement itself (renderer, fonts, PTY, etc.)
- [x] #2 Required Zig version is identified and documented
- [x] #3 Throwaway prototype feeds VT bytes into the terminal state and prints the resulting grid on Linux
- [x] #4 Windows and macOS build feasibility of the chosen artifact is confirmed or the gaps are listed
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Two agents ran in parallel with a shared contract: a read-only research slice (Ghostty tree inspection, no shell available so its claims are pinned-source citations plus upstream CI references) and a build slice (local prototype). Both independently resolved the same Ghostty SHA 5dc28bb8eebaf57a6c793a406bfea8c632d4fa94.
Key correction to the task's premise: there is no libghostty-vt/ directory. The consumable is the Zig module ghostty-vt (src/lib_vt.zig), plus a C ABI. The macOS embedding library is explicitly not for external use.
Decision: consume ghostty-vt only; Conduit implements PTY, renderer, fonts, windowing, GPU surface and all UI. Ghostty is MIT.
Coordinator verification: rm -rf .zig-cache zig-out && zig build run in spikes/task-2-vt exited 0 in 15.29s from a clean cache and printed a 44x9 grid containing the fed VT text plus 57 non-default-attribute cells across 4 SGR-derived styles (bold, underline, fg/bg palette, inverse), with wide/grapheme/block glyphs intact.
AGENTS.md now records both pins and the wiring shape. Full evidence in doc-1; ADR is decision-1 (its body was filled with the edit tool because 'backlog decision' has no update verb - create and list only).
Note: macOS and Windows feasibility is cited from upstream CI at the pinned commit; no build was run on those platforms.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Established the Ghostty boundary: the Zig module ghostty-vt at commit 5dc28bb8, on Zig 0.16.0 (the version that tree declares). Recorded in decision-1 with full evidence in doc-1. Proved it builds and runs here: spikes/task-2-vt feeds real VT bytes into Terminal, prints the resulting grid with styled-cell markers, and exits 0 from a clean cache (verified by the coordinator, 15.29s). Documented what Conduit must implement itself (PTY, renderer, fonts, windowing, GPU, UI), the MIT licence obligation, upstream CI evidence for macOS/Windows feasibility plus the gaps Conduit must close, and the ghostty_vt.Style formatting incompatibility with Zig 0.16. Updated AGENTS.md with the pins and the b.dependency + addImport wiring shape.
<!-- SECTION:FINAL_SUMMARY:END -->
