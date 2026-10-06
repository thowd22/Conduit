---
id: TASK-7
title: 'Window, GPU surface and event loop'
status: Done
assignee:
  - '@omp'
created_date: '2026-10-03 21:38'
updated_date: '2026-10-04 23:30'
labels:
  - platform
  - rendering
milestone: m-1
dependencies:
  - TASK-3
  - TASK-4
modified_files:
  - src/platform.zig
  - src/render.zig
  - src/main.zig
priority: high
ordinal: 7000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement the application window using the stack chosen in the windowing spike: create the window and GPU surface, run the event loop, handle resize, focus, DPI scale changes and close. Establish the frame scheduling model (render on demand when dirty, not a busy loop).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Conduit opens a resizable window that clears to a background color on Linux
- [x] #2 Resize and DPI scale changes are delivered to the app as events
- [x] #3 Idle CPU usage is near zero when nothing is changing
- [x] #4 Window closes cleanly with no leaks reported in debug builds
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Window, GPU surface, event loop and frame scheduling implemented in src/platform.zig, src/render.zig and src/main.zig. headless contract from doc-2 honoured: a real window and a real GL context always, hidden when --hidden, renderer always draws into an FBO, present blits only when visible, capture reads the FBO back with glReadPixels. Existing Scale/LogicalSize/SurfaceSize kept; the OS-reported scale enters only through Scale.fromPlatform.
Coordinator verification on this box: zig build exit 0; zig build test 109/109 tests (was 72) with platform 11, render 7, app 33; zig fmt --check . clean.
AC1: xvfb-run -a ./zig-out/bin/conduit --self-test creates a real SDL3 window (960x640, resizable) and a real GL 3.3 core context, and proves the clear with pixels rather than a log line: 614400/614400 pixels read back as (22,26,34,255), background 0x16,0x1a,0x22.
AC2: resize delivered as an event (960x640 then 480x320, surface reallocated and redrawn, re-captured 153600/153600); display-scale change delivered through SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED and the app re-reads the display and compares.
AC3: coordinator measured idle cost directly, which is better than the slice's own figure: 0.09s CPU total for a 3s run and the same 0.09s for a 20s run, so marginal idle cost is zero within measurement resolution; the contrast is a forced-redraw run at 5.08s CPU over 5.14s wall (~99% of a core), a 56x difference. Box is headless Ubuntu + Xvfb + llvmpipe; no claim is made about real hardware.
AC4: close goes through a real SDL_EVENT_WINDOW_CLOSE_REQUESTED, teardown runs in reverse, exit 0, and stderr contains no leak/error/panic line. The sink deliberately stays installed at close so leak lines are not swallowed.
Three bugs the slice found and fixed in its own code: a frame owed when --run-ms expired was never drawn; the self-test's resize wait was satisfied by SDL's creation-time configure so the after-resize capture was taken before the frame; --force-redraw still used the blocking wait so it measured no busy loop at all.
New flags documented in --help: --width --height --hidden --run-ms --force-redraw --self-test. The M0 logging flags and crash reporting still work.
Not verified here: macOS, Windows, real GPU, non-llvmpipe performance.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented the application window, GPU surface and event loop on the decided stack: a real SDL3 window with a real OpenGL 3.3 core context, the FBO-plus-present-plus-capture path the headless screenshot contract requires, and render-on-demand frame scheduling. Resize and display-scale changes arrive as events and the OS-reported scale enters only through Scale.fromPlatform; the window closes through the normal path with no leak output. Verified by the coordinator: a real window under Xvfb clearing every one of 614400 pixels to the background colour as read back through glReadPixels, resize and scale-change events observed, idle CPU measured at 0.09s over a 20s run against 5.08s over a 5s forced-redraw run, and a clean close at exit 0. 109/109 tests pass and formatting is clean.
<!-- SECTION:FINAL_SUMMARY:END -->
