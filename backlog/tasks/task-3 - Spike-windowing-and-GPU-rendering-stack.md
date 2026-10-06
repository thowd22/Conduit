---
id: TASK-3
title: 'Spike: windowing and GPU rendering stack'
status: Done
assignee:
  - '@omp'
created_date: '2026-10-03 21:38'
updated_date: '2026-10-05 20:35'
labels:
  - spike
  - rendering
milestone: m-0
dependencies:
  - TASK-2
modified_files:
  - spikes/task-3-window/build.zig
  - spikes/task-3-window/build.zig.zon
  - spikes/task-3-window/src/main.zig
  - spikes/task-3-window/README.md
  - AGENTS.md
priority: high
ordinal: 3000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Choose the window/input layer (e.g. GLFW, SDL3, or native per-OS shells) and the GPU API strategy (e.g. OpenGL everywhere, Metal + D3D + OpenGL/Vulkan, or a wgpu-style abstraction) for one shared surface that hosts both the terminal grid renderer and the terminal-styled UI renderer. Weigh IME support, HiDPI, Wayland and X11, clipboard access, framebuffer readback for screenshots, and offscreen/headless operation for tests. Record as a backlog decision.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Decision record names the windowing library and GPU API per platform with rationale
- [x] #2 Prototype opens a window and draws a textured quad on Linux
- [x] #3 Headless/offscreen rendering and framebuffer readback approach for the test driver is identified
- [x] #4 IME, HiDPI and clipboard capabilities of the chosen stack are documented
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Four agents ran in parallel against a shared candidate set: windowing evaluation (IME/HiDPI/clipboard/Wayland/Zig bindings), GPU evaluation, headless+readback design, and a locally built GLFW+GL textured-quad prototype.
Agents disagreed on windowing: the GPU slice and the prototype took GLFW, the windowing slice took SDL3 on IME. IME is a v0.1 feature (TASK-12) and decides it: GLFW's installed header contains zero composition/candidate API (verified by hand with a search of /usr/include/GLFW/glfw3.h), while SDL 3.4.2 on this box exposes SDL_EVENT_TEXT_EDITING, SDL_EVENT_TEXT_EDITING_CANDIDATES and SDL_SetTextInputArea/GetTextInputArea (verified by hand in the installed headers). Decision: SDL3 + OpenGL 3.3 core, GLFW documented as fallback.
GPU: OpenGL 3.3 core everywhere for v0.1. No Zig Metal/D3D12/WebGPU binding is verifiable on Zig 0.16 (mach needs its own Zig fork; zgpu declares 0.15.2; wgpu-native Zig idle since 2025-08). Revisit triggers recorded for M5.
Corrected a slice's finding: 'no maintained Zig GLFW binding exists' cited 404s for zig-gamedev/glfw and mach-gamedev/glfw, which are not the real repo. zig-gamedev/zglfw resolves HTTP 200 and builds against 0.16. Consequence unchanged - Conduit will not depend on a third-party windowing binding either way.
Coordinator verification: cd spikes/task-3-window && zig build && xvfb-run -a ./zig-out/bin/glfw-gl-quad exited 0; window 256x256 on X11 under Xvfb, GL 4.5 core (Mesa 26.0.8, llvmpipe), zopengl resolved the GL 3.3 core loader, textured quad drawn, glReadPixels wrote readback.ppm, all 6 pixel assertions OK.
Headless contract: hidden-but-real window, renderer always draws into an FBO that present blits only when visible, so headless and on-screen pixels are identical by construction; screenshots via glReadPixels + a hand-written PNG encoder (no PNG encoder in Zig 0.16 std). Labelled as inference: that no fence is needed on the FBO readback path - TASK-7 must prove it.
Windows CI rendering is not assumed for v0.1 and is recorded as a TASK-49 gap.
Full evidence in doc-2; ADR is decision-2.

2026-10-05 documentation reconciliation: the retained spike README now corrects its stale repository survey. The prototype still documents its translated GLFW header, while zig-gamedev/zglfw is accurately named as the viable fallback from decision-2. Destructive cache-cleanup guidance was removed and generated readback/cache evidence was clarified.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Decided the rendering stack: SDL3 for window and input, OpenGL 3.3 core for GPU, both behind Conduit-owned platform/render seams, with GLFW + zglfw documented as a credible fallback. IME decided the windowing axis - SDL3 exposes composition, candidates and cursor placement on all four platform stacks while GLFW 3.4 exposes none of it, and IME is a v0.1 requirement. Metal/D3D12/WebGPU rejected for v0.1 because no Zig binding is verifiable on Zig 0.16; revisit triggers and the M5 target are recorded. Also designed the headless path TASK-21/22/25 depend on: a hidden-but-real window with the renderer always drawing into an FBO, so headless and on-screen images are the same pixels, plus glReadPixels and a hand-written PNG encoder. Evidence in doc-2, ADR in decision-2, and AGENTS.md now carries the pins, the wiring shape and the Zig 0.16 gotchas. Proof: spikes/task-3-window opens a 256x256 window under Xvfb, draws a textured quad and reads the framebuffer back; the coordinator re-ran it to exit 0 with all six pixel assertions passing.
<!-- SECTION:FINAL_SUMMARY:END -->
