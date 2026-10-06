---
id: decision-1
title: >-
  Consume Ghostty as the ghostty-vt Zig module, pinned at 5dc28bb8, on Zig
  0.16.0
date: '2026-10-04 20:10'
status: accepted
---
## Context
Conduit needs VT parsing and terminal state from Ghostty, and nothing else. Ghostty ships three
consumable surfaces: the Zig module `ghostty-vt`, a C ABI for the same, and a macOS-only embedding
library. The macOS one's own header says it is "not designed for external use" and `build.zig:221-224`
says "This is NOT libghostty". The full application (GTK4 on Linux/Windows, Swift + Metal on macOS)
holds all the rendering, font and PTY code, which Conduit intends to write itself.

## Decision
Conduit depends on the **Zig module `ghostty-vt`** (root `src/lib_vt.zig`), pinned to Ghostty commit
`5dc28bb8eebaf57a6c793a406bfea8c632d4fa94`, on **Zig 0.16.0** — the `.minimum_zig_version` declared in
that tree's `build.zig.zon`, which confirms the AGENTS.md pin.

Conduit implements itself: PTY, grid renderer, fonts and shaping, windowing, GPU surface, input
routing and all UI. Licence is MIT; the only obligation is retaining the copyright and permission
notice. Platform feasibility for macOS and Windows is based on upstream CI at the pinned commit, not
on builds Conduit ran on those platforms.

Full evidence, API mapping with source line references, and the reproduction commands are in
`doc-1` (TASK-2 spike report). The prototype lives in `spikes/task-2-vt/` and was run locally.

## Consequences
- The terminal engine contributes no rendering code, so TASK-3 owns the entire windowing and GPU
  decision.
- The Zig API is explicitly unstable upstream; the C ABI is the fallback seam if churn bites. That
  trade is revisited at TASK-9.
- `ghostty_vt.Style` formatting does not compile on Zig 0.16 (`std.fmt.FormatOptions` signature).
  The terminal module needs its own style describer.
- Bumping either pin is its own task with its own decision record.
