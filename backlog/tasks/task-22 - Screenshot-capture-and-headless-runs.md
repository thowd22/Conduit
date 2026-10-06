---
id: TASK-22
title: Screenshot capture and headless runs
status: Done
assignee:
  - '@codex'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 02:42'
labels:
  - testing
  - rendering
milestone: m-2
dependencies:
  - TASK-7
  - TASK-21
modified_files:
  - AGENTS.md
  - docs/architecture.md
  - src/main.zig
  - src/platform.zig
  - src/render.zig
  - src/testdriver.zig
priority: high
ordinal: 22000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Framebuffer readback to PNG exposed through the test driver, plus a headless mode for CI and agents (offscreen surface, or Xvfb/headless Wayland compositor on Linux) with a fixed window size and scale factor for deterministic images.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 screenshot writes a PNG of the current frame to a per-run artifact directory
- [x] #2 Conduit can run and be driven without a visible display on Linux
- [x] #3 Window size and scale can be fixed by flag for reproducible screenshots
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add deterministic RGBA8 PNG encoding with focused format and decoding tests.
2. Add an explicit fixed-scale window option and wire validated --scale, --width, and --height flags into hidden runs.
3. Implement per-run artifact directories and asynchronous screenshot persistence for the JSON-RPC driver; force a current frame before readback and return its unique PNG path.
4. Extend the hidden driver self-check to capture and validate a PNG, update architecture/user guidance, then run format, build, unit, and all Linux headless checks and inspect the image.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented deterministic dependency-free RGBA8 PNG encoding in render with validation, PNG chunk/CRC coverage, zlib round-trip tests, and top-down scanline evidence. Added --scale with strict finite/minimum validation and a persistent platform fixed-scale override; --width/--height remain the logical dimensions. Driver screenshots now force a fresh shared-surface frame, read the FBO on the main thread, copy pixels into one bounded worker, encode and exclusively persist off-thread, and reply only after the file is complete. Driver artifact paths are sequential inside an explicit --test-artifact-dir or a unique generated per-run directory; generated POSIX directories/files are 0700/0600. Standalone --screenshot now writes PNG through the same encoder.

Evidence: zig build passed; zig build test --summary all passed 355/362 with the seven existing platform skips; all eight Linux headless checks passed under xvfb-run, including --driver-test with 12/12 exchanges and a decoded 640x360 PNG. The driver PNG was visually inspected. A separate hidden --width=320 --height=200 --scale=2 run produced an identified 640x400 8-bit RGBA PNG. Explicit artifact permissions measured 700/600. Windows MinGW cross-analysis reached the final link and remains blocked by the pre-existing Ghostty native targets.o/abort.o/simdutf.o object-format inputs; native macOS and Windows runtime rendering were not claimed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Completed deterministic PNG screenshot capture and reproducible hidden runs. The driver now forces the current shared FBO frame, returns an exclusively written PNG from a private per-run artifact directory, and keeps encoding/filesystem IO off the render thread. Window width, height, and scale are independently fixed by flags. Linux build, unit tests, all eight Xvfb checks, artifact decoding, visual inspection, 2x geometry, and POSIX permissions passed; native macOS/Windows runtime verification remains for their CI runners.
<!-- SECTION:FINAL_SUMMARY:END -->
