---
id: doc-2
title: 'TASK-3 spike: windowing, GPU stack and headless screenshot path'
type: other
created_date: '2026-10-04 20:31'
updated_date: '2026-10-04 20:31'
---
TASK-3 spike report. Window/input layer, GPU strategy, and the headless screenshot path that TASK-21, TASK-22 and TASK-25 depend on.

## Evidence and its strength

Four slices ran in parallel against the same candidate set (`GLFW 3.4 + OpenGL 3.3 core`, `SDL3 + OpenGL/Vulkan`, native per-OS shells):

- **Windowing evaluation** — read-only, primary-source research (upstream docs, headers, backend sources, issue trackers). No builds.
- **GPU evaluation** — read-only research; verified GL and SDL entry points against the installed headers on this box.
- **Headless/readback design** — read-only design work; cited GLFW and SDL source lines and Khronos reference pages.
- **Prototype** — built and run locally on this headless Linux box, and re-run by the coordinator.

Two claims were checked by hand afterwards and are corrected here: the SDL3 IME API and the GLFW IME gap were confirmed directly in the installed headers, and the "Zig GLFW binding is dead" claim was traced to a repository name that does not exist.

## Decision in one line

**SDL3 for window and input, OpenGL 3.3 core for GPU, both behind Conduit-owned seams, with GLFW + zglfw as the documented fallback.** The deciding axis is IME, which is a v0.1 feature (TASK-12, M1).

## Why SDL3 wins the windowing axis

IME is the decisive capability, and the difference is not marginal:

- SDL3 exposes composition, candidate state and cursor placement: `SDL_EVENT_TEXT_EDITING` (SDL_events.h:172), `SDL_EVENT_TEXT_EDITING_CANDIDATES` (:178), `SDL_SetTextInputArea`/`SDL_GetTextInputArea` (SDL_keyboard.h:550, :571), with the composition/candidates hint contract documented at SDL_hints.h:1196-1199. **Verified in the installed SDL 3.4.2 headers on this box.**
- GLFW 3.4 exposes only a committed-code-point callback. **Verified by hand: a search of `/usr/include/GLFW/glfw3.h` for `TextInput|Candidat|Composition|Preedit` returns zero matches.** Upstream source agrees: the Cocoa backend stores marked text without reporting it and returns a zero rect from `firstRectForCharacterRange` (so a macOS candidate window would land in the wrong place), the Wayland backend binds no text-input protocol, the Win32 backend handles `WM_CHAR` only. GLFW issue #2097 ("Add IME support for each platform") closed unimplemented; GLFW 3.5 adds no IME API, so this is version-independent.

SDL3 also wins on the other axes TASK-3 must document:

| Capability | SDL3 | GLFW 3.4 |
|---|---|---|
| IME composition + candidates + cursor placement | yes, all four platforms | none |
| HiDPI | `SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED`, `SDL_GetDisplayContentScale`, `SDL_GetWindowPixelDensity` / `SDL_GetWindowDisplayScale` (per-window vs display base scale) | `GLFW_SCALE_TO_MONITOR` / `GLFW_SCALE_FRAMEBUFFER`, integer monitor scale only |
| Clipboard | `SDL_clipboard.h`, text plus X11/Wayland primary selection, deferred MIME API | present, but Wayland path is serial-based and coarse |
| Linux display servers | X11 and Wayland | X11 and Wayland; `GLFW_PLATFORM_NULL` exists but its source cannot produce a GL context |
| Zig story | `castholm/SDL` build package (verified alive; declares `.minimum_zig_version = 0.16.0`); **no** maintained SDL3 Zig binding, so Conduit owns a thin extern seam | `zig-gamedev/zglfw` (verified alive, HTTP 200) + `zopengl` |
| Headless | `SDL_WINDOW_HIDDEN`, dummy and offscreen (EGL device + pbuffer) drivers | hidden window only; no null-platform GL context |

Native per-OS shells give full IME but mean writing windowing on three platforms with no headless mode. That is not a v0.1 trade Conduit should make.

### Correction to a slice's finding

One slice reported that no maintained Zig GLFW binding exists, citing 404s for `zig-gamedev/glfw` and `mach-gamedev/glfw`. Both of those names are indeed dead, but the repository that matters is `zig-gamedev/zglfw`, which resolves (HTTP 200) and whose CI builds against Zig 0.16. The dead names were not the right repositories to check. The practical consequence is unchanged: **Conduit will not depend on a third-party windowing binding** — SDL3 gets a hand-written `@cImport`/extern seam, and GLFW would come through `zglfw`.

## Why OpenGL 3.3 core wins the GPU axis

- It is the only candidate that needs **no unproven Zig package** for v0.1. `zopengl` (0.6.0-dev) declares `.minimum_zig_version = 0.16.0` and built and ran here; it is pure Zig.
- It expresses principle P6 (two renderers, one surface) as ordinary call order plus viewport/scissor: the grid renderer and the UI renderer draw in sequence into the same target. No extra abstraction layer.
- It gives the test driver the simplest screenshot path: `glReadPixels` from an FBO.
- Every GL 3.3 core entry point the design needs is present in the installed `glcorearb.h` — `glBindFramebuffer`, `glDrawBuffers`, `glViewport`, `glBlendFuncSeparate`, `glTexImage2D`, `glReadPixels`, `glBlitFramebuffer`.
- Ghostty itself makes exactly this split: Metal on Darwin, OpenGL elsewhere (`src/renderer/backend.zig`).

Rejected for v0.1, with the reason:

- **Platform-native (Metal / D3D12 / OpenGL-Vulkan)** — no first-class Zig Metal or D3D12 binding is verifiable on Zig 0.16 (`mach` requires its own `2026.4.10-mach` Zig fork), and it triples the renderer code.
- **wgpu-style** — `zgpu` still declares 0.15.2 while landing 0.16 fixes; the wgpu-native Zig binding has been idle since 2025-08-18. Neither is verifiable on Zig 0.16 today. Note that Zig 0.16's `std.gpu.zig` is SPIR-V *build-time* shader authoring only; there is no std WebGPU binding.

**Revisit triggers**, recorded so the decision is revisited deliberately rather than by drift: Apple removing OpenGL on macOS; a feature need beyond GL 3.3 core; or a 0.16-stable `zgpu`/`wgpu-native` with current prebuilt binaries. Target for revisiting: M5 (platform polish).

## Headless rendering and screenshots (the design TASK-21, TASK-22 and TASK-25 implement)

- The headless path is a **peer** of the on-screen path, not a separate renderer. `platform.window` always creates a real window and a real GL context; headless means a hidden window that is never shown.
- The renderer **never** draws into the window's default framebuffer. It always renders into an FBO owned by `render` (RGBA8 colour texture, size = window size x scale, 0 samples). `present` blits that texture to the default framebuffer only when the window is visible. GLFW's own offscreen-context guidance recommends FBOs precisely because a hidden window's framebuffer may not be usable or modifiable.
- Consequence: the visible and headless images are the same pixels by construction, so an E2E screenshot proves what a user would see.
- `render.capture` binds the FBO, sets `GL_PACK_ALIGNMENT` to 1, calls `glReadPixels(GL_RGBA, GL_UNSIGNED_BYTE)` into a reused buffer, flips vertically, and writes a PNG. Zig 0.16.0 ships no PNG encoder, so Conduit writes one: RGBA8, colour type 6, one filter byte per scanline, zlib via `std.compress.flate`, CRC-32 via `std.hash.crc`. That is roughly 150 lines and no new dependency; `imagemagick` drops off the CI critical path.
- The test driver runs on the app's main thread inside the same event loop, so `key`/`type`/`click`/`screenshot` are FIFO-ordered, and `screenshot` (force render, readback, encode, reply) needs no sleeps and no fences.
- Linux CI: `xvfb-run -a --server-args="-screen 0 1280x800x24"`.

Determinism hazards and their mitigations:

| Hazard | Mitigation |
|---|---|
| GPU work still in flight at readback | force a render immediately before `glReadPixels`, which implicitly synchronises the read on this path; no sleeps |
| First frame differs from steady state (atlas warm-up, lazily built caches) | tests wait on a semantic condition, never on a fixed frame count; the test driver exposes `wait_for` |
| Async readback path | never use `PIXEL_PACK_BUFFER`; read synchronously into a reused buffer, so no fence or map is needed |
| MSAA readback | FBO uses 0 samples, which avoids `GL_INVALID_OPERATION` on MSAA reads entirely |
| Row alignment | `GL_PACK_ALIGNMENT` set to 1 before every read |
| Window size / DPI drift | window size and scale are fixed by flags at startup, never taken from the desktop |
| Font atlas state leaking between runs | each run gets an isolated state dir (already TASK-23's `launch`) |

Labelled inference, not verified: that no explicit fence is needed on the FBO readback path. It follows from the implicit synchronisation rules but was not proven here; TASK-7 should prove it before TASK-22 depends on it.

## Prototype evidence (locally executed)

`spikes/task-3-window/` — self-contained, throwaway, not part of the project build.

Re-run by the coordinator on this box:

```
cd spikes/task-3-window && zig build && xvfb-run -a ./zig-out/bin/glfw-gl-quad
→ exit 0
```

It creates a 256x256 window on the X11 backend under Xvfb, creates a core-profile context reporting `4.5 (Core Profile) Mesa 26.0.8-1ubuntu0.3` / GLSL 4.50 / llvmpipe, resolves every GL 3.3 core entry point through `glfwGetProcAddress` via `zopengl`, uploads a procedural 2x2 RGBA texture, draws a textured quad with GLSL 3.30 shaders, reads the framebuffer back with `glReadPixels`, writes `readback.ppm`, and asserts six pixels. The coordinator's independent run passed all six: the four texture quadrants and two clear-border samples.

What this prototype proves, and what it does not: it proves the **GPU mechanics** — context creation, texture upload, quad draw, `glReadPixels` readback — and that `zopengl` works on Zig 0.16.0. It does **not** prove GLFW is the right windowing choice; the decision above goes with SDL3 for IME. GLFW remains the documented fallback, and this prototype is the reason that fallback is credible rather than hypothetical.

Useful Zig 0.16 facts confirmed against the installed std during the spike:

- `std.Build.Step.TranslateC.create(...).createModule()` replaces `b.addTranslateC`.
- `std.zig.allocator` no longer exists; `main` takes `std.process.Init`.
- `zopengl`'s `glGetShaderInfoLog`/`glGetProgramInfoLog` return `void` with a non-optional `[*c]Sizei` out-param.
- `glVertexAttribPointer`'s last argument is a **byte offset** into the buffer bound to `GL_ARRAY_BUFFER`, not a host pointer. Passing a host address silently produces a fully clipped draw with no GL error. In Zig 0.16, an offset of 0 must be passed as `null`, because a non-optional `*const anyopaque` may not be the null pointer.
- `glReadPixels` must run before `glfwSwapBuffers`; reading a swapped-out back buffer returns all-clear.
- `translate-c` keeps the `GLFW_` macro prefix, so the enum is `GLFW_CONTEXT_VERSION_MAJOR`, not `CONTEXT_VERSION_MAJOR`.

## Consequences for later tasks

- TASK-4 wires `zopengl` and the SDL3 seam into the root build, and keeps every OS-specific call behind `platform`.
- TASK-7 implements the window/context/loop with the hidden-window + FBO contract above.
- TASK-21 and TASK-22 implement `render.capture` and the PNG encoder against this contract; TASK-25 runs Linux CI under Xvfb.
- Windows CI rendering with OpenGL in v0.1 is **not** assumed: GLFW's own Win32 backend fails window creation when only GDI software OpenGL is available, so the Windows path is called out as a gap to close at TASK-49 rather than pretended into v0.1.
