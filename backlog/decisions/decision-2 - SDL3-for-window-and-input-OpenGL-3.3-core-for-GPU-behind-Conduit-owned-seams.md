---
id: decision-2
title: 'SDL3 for window and input, OpenGL 3.3 core for GPU, behind Conduit-owned seams'
date: '2026-10-04 20:31'
status: accepted
---
## Context
Conduit needs one window and GPU surface hosting two renderers, plus first-class IME (a v0.1
feature, TASK-12), HiDPI, clipboard, and a headless mode that produces real screenshots in CI.
Four spikes evaluated `GLFW 3.4 + OpenGL 3.3 core`, `SDL3 + OpenGL/Vulkan` and native per-OS shells
against those requirements on Zig 0.16.0.

## Decision
**Window and input: SDL3. GPU: OpenGL 3.3 core.** Both sit behind Conduit-owned seams in
`platform` and `render`; no OS call escapes them.

The deciding axis is IME. SDL3 exposes composition, candidate state and cursor placement
(`SDL_EVENT_TEXT_EDITING`, `SDL_EVENT_TEXT_EDITING_CANDIDATES`, `SDL_SetTextInputArea`) on macOS,
Windows, Wayland and X11. GLFW 3.4 exposes only a committed-code-point callback — its installed
header contains no composition API at all, and upstream issue #2097 closed unimplemented. IME is in
v0.1, so choosing GLFW would mean building a custom IME layer for three platforms, which no task
funds.

OpenGL 3.3 core needs no unproven Zig package (`zopengl` builds on 0.16), expresses the
two-renderers-one-surface rule as ordinary call order, and gives the test driver a
`glReadPixels`-from-an-FBO screenshot path. Metal, D3D12 and WebGPU were all rejected for v0.1
because no Zig binding for them is verifiable on Zig 0.16 today.

Headless is a hidden-but-real window, and the renderer always draws into an FBO that `present`
blits to the screen only when visible — so the headless and on-screen images are the same pixels by
construction.

Evidence, sources, correction of one slice's dead-repository claim, and the headless contract are in
`doc-2`. The prototype in `spikes/task-3-window/` was run locally and by the coordinator.

## Consequences

- **No third-party windowing binding.** SDL3 arrives through `castholm/SDL` plus a thin
  `@cImport`/extern seam Conduit owns; the GLFW fallback would use `zig-gamedev/zglfw`. Both
  libraries are dependencies Conduit pins and can replace.
- **GLFW stays a documented fallback** and stays credible: `spikes/task-3-window/` proves the GPU
  mechanics end to end on Linux, so swapping windowing later is a contained change.
- **Revisit the GPU choice** if Apple removes OpenGL on macOS, if a needed feature exceeds GL 3.3
  core, or if `zgpu`/`wgpu-native` reach a 0.16-stable release with current binaries. Target: M5.
- Conduit writes its own PNG encoder (`std.compress.flate` + `std.hash.crc`); `imagemagick` stays off
  the CI critical path.
- Windows CI rendering is not assumed in v0.1: GLFW's Win32 backend fails window creation when only
  GDI software OpenGL exists. Close it at TASK-49, do not pretend it into v0.1.
- The claim that no fence is needed on the FBO readback path is an inference, not a verified fact.
  TASK-7 must prove it before TASK-22 depends on it.

