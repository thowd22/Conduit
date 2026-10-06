---
id: doc-1
title: 'TASK-2 spike: libghostty consumption boundary and Zig pin'
type: other
created_date: '2026-10-04 20:09'
updated_date: '2026-10-04 20:10'
---
TASK-2 spike report. What Conduit consumes from Ghostty, at which commit, and what Conduit builds itself.

## Evidence and its strength

Two independent slices ran on this machine:

- **Prototype (locally executed).** `spikes/task-2-vt/` builds and runs here with Zig 0.16.0 on Linux. Reproduced from a clean cache: `cd spikes/task-2-vt && zig build --fetch && zig build run` exits 0 in ~15 s and prints a grid produced from real VT bytes.
- **Research (source citations, no local build).** The other slice inspected the exact pinned tree through the GitHub git-tree API and `raw.githubusercontent.com`; it had no shell, so it ran no builds. Its platform and licence claims are pinned-source citations plus upstream CI workflow references.

Claims below are labelled with which kind of evidence backs them. Nothing here was verified by running a Windows or macOS build on those platforms.

## Pinned versions

| Thing | Value | Evidence |
|---|---|---|
| Ghostty commit | `5dc28bb8eebaf57a6c793a406bfea8c632d4fa94` (tree `ba0e3f364dbf4643910660ffb76d2cd750e20fc4`) | `git ls-remote ... refs/heads/main`; both slices independently resolved the same SHA |
| Ghostty package version | `ghostty 1.3.2-dev` | `build.zig.zon:3` in the pinned tree |
| Required Zig version | `0.16.0` | `.minimum_zig_version = "0.16.0"`, `build.zig.zon:6`; enforced at `build.zig:14,17` |

This confirms the AGENTS.md pin: Zig 0.16.0 is the minimum Ghostty's main branch declares.

## Which artifact Conduit uses

**The Zig module `ghostty-vt`** — root source file `src/lib_vt.zig`, registered in `src/build/GhosttyZig.zig` (`initVt`, `root_source_file = b.path("src/lib_vt.zig")`).

There is **no `libghostty-vt/` directory** in the tree. The name appears only as build artifact names and C-ABI library names (`ghostty-vt-static`, shared `ghostty-vt`, `.xcframework`), produced by `src/build/GhosttyLibVt.zig` and `build.zig:128-208`. Headers exist at `include/ghostty/vt.h` and `include/ghostty/vt/*.h` for C consumers.

`initVt` sets `vt_options.artifact = .lib` and `oniguruma = false` and adds only the unicode tables, `uucode`, optional `wuffs` and SIMD dependencies. That proves the module's dependency cone is terminal state and parsing only — no renderer, no fonts, no apprt, no PTY.

Consumption mechanism, verified locally: a URL + multihash dependency on the `ghostty` package in `build.zig.zon`, then `b.dependency("ghostty", .{})` plus `mod.addImport("ghostty-vt", ghostty.module("ghostty-vt"))`. This mirrors upstream's own `example/zig-vt/`.

### The artifact Conduit must not use

The macOS-oriented "libghostty" is `src/main_c.zig` + `src/apprt/embedded.zig` + `include/ghostty.h`. Its own header says it is "not designed for external use", its platform enum covers only macOS/iOS, and `build.zig:221-224` says "This is NOT libghostty … just the glue between Ghostty GUI on macOS and the full Ghostty GUI core". Conduit depends on `ghostty-vt` only.

The Ghostty app itself (GTK4 on Linux/Windows, Swift + Metal on macOS) is where rendering, fonts, PTY and windowing live, and is unreachable from `ghostty-vt`.

## What Conduit implements itself

Conduit owns: the PTY layer, the terminal grid renderer, the whole font stack (discovery, shaping, glyph atlas, fallback), windowing, GPU surface management, input routing, and every piece of UI. It consumes only VT parsing and terminal state.

## The API surface, read from source

Public Zig API root is `src/lib_vt.zig`. It exports `Terminal`, `Screen`, `ScreenSet`, `Page`, `PageList`, `Cell`, `Stream`, `TerminalStream`, `Parser`, `RenderState`, `Selection`, `SelectionGesture`, `search`, `formatter`, `snapshot`, `Style`, `sys`, `TinyIo`, the `input` namespace (`encodeKey`/`encodeMouse`/`encodeFocus`/`encodePaste`) and `unicode.codepointWidth`/`graphemeWidth`. Its header carries the warning: "The API is not guaranteed to be stable."

The C ABI is emitted at `src/lib_vt.zig:165-583` and is gated by `terminal.options.features`: `ghostty_terminal_*`, `ghostty_render_state_*`, `ghostty_search_*`, `ghostty_snapshot_*`, `ghostty_key_*`, `ghostty_mouse_*`, `ghostty_paste_*`, `ghostty_kitty_graphics_*`, `ghostty_color_*`, `ghostty_grid_ref_*`, `ghostty_cell_get*`, `ghostty_alloc`/`ghostty_free`. Feature gates are declared in `src/terminal/build_options.zig` (snapshot, formatter, selection, search, render_state, input_encode, color, grid_introspection, glyph_protocol, kitty_graphics — all default true, tunable with `-Dvt-features`).

Conduit's mapping (prototype-verified locally):

| Need | Zig API | Declared at |
|---|---|---|
| Create terminal | `ghostty_vt.Terminal.init(io, alloc, .{ .cols, .rows })` | `src/lib_vt.zig:96` to `src/terminal/Terminal.zig:329` |
| Feed PTY bytes | `Terminal.vtStream()` + `Stream.nextSlice(bytes)` | `Terminal.zig:401`, `src/terminal/stream.zig:641` |
| Resize | `Terminal.resize(alloc, .{ .cols, .rows })` | `Terminal.zig:4038-4080` |
| Damage tracking | `ghostty_vt.RenderState` `.empty` / `.update` / `.rowDataRange()` / `.viewportY()` | `src/terminal/render.zig:118,481,1032,1050` |
| Cell access | `page.Cell` — `style_id`, `wide`, `content_tag`, `codepoint()`, `hasGrapheme()` | `src/terminal/page.zig:2137` |
| Plain text dump | `Terminal.plainString(alloc)` | `Terminal.zig:4952` |
| No `std.Io` embedders | `ghostty_vt.TinyIo` | `src/lib_vt.zig:39-51` |

### Known sharp edge (prototype finding)

`ghostty_vt.Style`, `Style.Color` and `osc.Terminator` still carry the pre-0.16 formatting signature that references `std.fmt.FormatOptions`, so `{f}` does not compile for a Zig 0.16 consumer. Terminal state itself is fine. Conduit's terminal module will need its own style describer rather than relying on Ghostty's formatting. Recorded so nobody rediscovers it mid-implementation.

## Licensing

MIT (`LICENSE` at the pinned commit, "Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors"). The obligation is retaining the copyright notice and permission notice in copies or substantial portions. No share-alike, no redistribution restriction.

Dependencies of the `vt` module: uucode (MIT), simdutf (MIT), Highway (Apache-2.0 OR BSD-3-Clause), wuffs (MIT OR Apache-2.0, pulled in only when the kitty graphics protocol is enabled).

## Platform feasibility (citation-based, not locally built on those platforms)

Upstream CI builds and tests `libghostty-vt` on Linux (including musl), macOS (plus iOS via xcframework), and a native Windows runner. MSVC cross-compilation is explicitly disabled upstream, so Conduit builds Windows artifacts on a Windows runner.

Gaps Conduit must solve itself, because none of this is in `ghostty-vt`: windowing, GPU surface, renderer, fonts and shaping, PTY (POSIX and ConPTY), clipboard, and every UI surface.

## Consequences for later tasks

- TASK-3 chooses the windowing and GPU stack knowing the terminal engine contributes **no** rendering code.
- TASK-4 wires the `ghostty` package into the root `build.zig.zon` with the same `b.dependency` + `addImport` shape the spike validated.
- The Zig API is explicitly unstable; the C ABI is the more conservative seam if upstream churn bites. That trade is revisited when TASK-9 wraps terminal state.
