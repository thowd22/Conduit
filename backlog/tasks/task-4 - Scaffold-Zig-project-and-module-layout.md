---
id: TASK-4
title: Scaffold Zig project and module layout
status: Done
assignee:
  - '@omp'
created_date: '2026-10-03 21:38'
updated_date: '2026-10-05 20:35'
labels:
  - infra
milestone: m-0
dependencies:
  - TASK-2
  - TASK-3
modified_files:
  - build.zig
  - build.zig.zon
  - .gitignore
  - src/main.zig
  - docs/architecture.md
priority: high
ordinal: 4000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create build.zig / build.zig.zon with the pinned Zig version and the libghostty dependency. Lay out modules matching the architecture: app, platform (window, clipboard), pty, term (libghostty wrapper), render, font, ui, input, workspace, session, config, theme, agent, backlog, testdriver. Add a main executable that starts and exits cleanly, and wire 'zig build', 'zig build run' and 'zig build test'.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 'zig build' produces a conduit executable on Linux
- [x] #2 'zig build test' runs at least one unit test per created module
- [x] #3 Module layout is documented in CONDUIT.md or docs/architecture.md
- [x] #4 .gitignore covers zig-out and the Zig cache
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Ran as three agent waves with disjoint file ownership, then verified by the coordinator.
Wave 1: BuildScaffold wrote build.zig, build.zig.zon, .gitignore and src/main.zig. build.zig declares all 15 modules in one table; a module joins the build automatically when its source file exists, proven empirically by dropping a throwaway module in and watching zig build test pick it up with no build-file change. ArchDoc wrote docs/architecture.md (666 lines, 9 sections, 15 module entries, each with Owns/Never/Depends, plus the dependency DAG, threading/ownership, memory rules, how to add a module, and the testing map).
Wave 2: three agents created the 14 remaining module roots, split by layer so their files never collide.
One slice failed and was redone by the coordinator: LeafModules wrote src/platform.zig containing 18 NUL bytes (not valid UTF-8), never created pty.zig/config.zig/font.zig, and returned a malformed report. The coordinator rewrote platform.zig and wrote the three missing leaves by hand.
Coordinator then found and fixed three real defects in that hand-written code: a syntax error in platform.zig from a botched edit, a wrong invariant in Scale.toPhysical (it clamped the surface up to the logical size, which is wrong for a fractional display scale below 1x), and two compile errors in config.zig (a parameter shadowing the text method, and std.math.order on an enum).
Coordinator verification after the fix: zig build exit 0; zig build run headless exit 0; zig build test --summary all = 76/76 steps, 49/49 tests, with one test binary per module (platform 4, pty 5, config 5, font 5, theme 2, term 3, render 3, ui 4, input 3, session 3, workspace 3, agent 2, backlog 3, testdriver 3, app 1); zig fmt --check . clean.
Note for the next milestone: TASK-6's logging lives in the app module rather than a new module, because docs/architecture.md fixes the module list at 15 and adding one is an architecture change for the user to agree to, not a task detail.

2026-10-05 reconciliation audit: the module table still builds and tests, but docs/architecture.md has stale dependency edges and stale SDL build-step text (it documents sdl-check although addSdlCheck is not registered). ACs remain checked because the layout is present and documented; documentation needs resynchronizing before a later task relies on the edge list.

2026-10-05 documentation repair: docs/architecture.md is synchronized with the current build.zig module table and dependency graph. It now documents SDL3 as part of the normal build/run/test graph, removes the obsolete sdl-check step, and updates module edges, seam wording and module/test wiring instructions. The earlier reconciliation caveat is resolved.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Scaffolded the project: root build.zig/build.zig.zon with the pinned Ghostty, SDL3 and zopengl dependencies, a module table covering all 15 Conduit modules that auto-wires a module the moment its file exists, .gitignore, a headless-clean 'conduit' executable, and docs/architecture.md documenting the module layout, the dependency direction, threading and state ownership, memory rules and how to add a module. All 15 modules now have a source root with at least one real unit test. Verified: zig build exit 0, zig build run exit 0 headless, zig build test 76/76 steps and 49/49 tests passing, zig fmt --check clean. One agent slice corrupted src/platform.zig with NUL bytes and delivered a malformed report; the coordinator rewrote it and wrote the three missing leaf modules by hand, then fixed three real defects in that code including a wrong HiDPI scale invariant.
<!-- SECTION:FINAL_SUMMARY:END -->
