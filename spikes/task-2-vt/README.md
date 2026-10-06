# TASK-2 spike — libghostty-vt builds and runs on Linux (Zig 0.16.0)

**This is throwaway spike code.** It exists only to answer one question for TASK-2: *does
Ghostty's terminal-state artifact compile and run on this box with Zig 0.16.0, and does its grid
really reflect parsed VT bytes?* TASK-4 (the real project scaffold and module layout) **must not
absorb any of this**. Delete `spikes/task-2-vt/` when the decision record is written; nothing here
is production code, and `AGENTS.md`'s coding standards (scoped `std.log`, tests in the same file,
no `std.debug.print` in committed code) are deliberately not applied to it.

## Pinned versions

| Thing | Value |
|---|---|
| Ghostty `refs/heads/main` | `5dc28bb8eebaf57a6c793a406bfea8c632d4fa94` |
| Ghostty package version (its `build.zig.zon`) | `ghostty` `1.3.2-dev` |
| Zig | `0.16.0` — `/opt/zig-x86_64-linux-0.16.0/zig` (`zig version`) |
| Platform exercised | Linux x86_64 (Ubuntu, headless) |

The SHA was resolved with:

```shell-session
$ git ls-remote https://github.com/ghostty-org/ghostty refs/heads/main
5dc28bb8eebaf57a6c793a406bfea8c632d4fa94	refs/heads/main
```

## What the artifact is actually called

There is **no `libghostty-vt/` directory** in the tree. At the pinned commit the terminal-state
library is:

- the **Zig module named `ghostty-vt`**, whose root source file is `src/lib_vt.zig`;
- declared in `src/build/GhosttyZig.zig` — `initInner(b, cfg, deps, "ghostty-vt", "ghostty-vt-c")`,
  and `b.addModule(name, .{ .root_source_file = b.path("src/lib_vt.zig"), ... })`;
- plus the C-ABI siblings (`ghostty-vt-static`, `ghostty-vt` shared lib, `.xcframework`) declared in
  `src/build/GhosttyLibVt.zig` and `build.zig` (`libghostty_vt_shared` / `libghostty_vt_static`).

This spike consumes the **Zig module**, because that is what a Zig application links directly and
what Ghostty's own example consumes (`example/zig-vt/build.zig` in the pinned tree does exactly
`b.dependency("ghostty", …)` → `dep.module("ghostty-vt")` → `addImport`).

## Reproduce from a clean checkout

```shell-session
$ cd spikes/task-2-vt
$ zig build --fetch      # fetches the pinned Ghostty tarball into zig-pkg/ (~0.6 s)
$ zig build run
```

Nothing else is needed — no system packages, no GTK, no display. `zig build run` exits `0`.
`build.zig.zon` pins Ghostty by URL + Zig multihash, so the build is reproducible offline after
`--fetch`.

Measured on this box from a fully clean state (`rm -rf .zig-cache zig-out zig-pkg`):
`zig build --fetch` 0.56 s, `zig build run` **15.22 s** (compiles `libsimdutf.a` + `libhighway.a`
from C++ source and the Zig module, Debug, native target).

## Observed output

```
libghostty-vt grid: 44 cols x 9 rows
render state dirty: full
0 |Conduit VT spike                            | ****************............................
1 |plain: underlined tail                      | .......***************......................
2 |bg-palette-33                               | *************...............................
3 |reverse-video                               | *************...............................
4 |wide:漢 graph:é blocks:█▄░▒                 | ............................................
5 |                                            | ............................................
6 |             end                            | ............................................
7 |                                            | ............................................
8 |                                            | ............................................

distinct non-default styles in the grid:
  Style{ fg=palette(1), flags={bold} }
  Style{ flags={underline=single} }
  Style{ fg=palette(15), bg=palette(33) }
  Style{ flags={inverse} }
styled (non-default) cells: 57
cursor in viewport: x=16 y=6
cursor cell style: Style{  }

Terminal.plainString():
Conduit VT spike
plain: underlined tail
bg-palette-33
reverse-video
wide:漢 graph:é blocks:█▄░▒

             end
```

Reading the dump: the middle field is the row's text, the right field is a per-cell attribute map
(`*` = the cell carries a non-default style, `.` = default). The bytes fed in are:

```
\x1b[2J\x1b[H          erase display, home
\x1b[1;31m            SGR bold + red foreground   -> row 0, cells 0..15   Style{ fg=palette(1), flags={bold} }
\x1b[0m              SGR reset
\x1b[2;1H            CUP row 2 col 1
"plain: " \x1b[4m "underlined tail" \x1b[0m    -> row 1, cells 7..21   Style{ flags={underline=single} }
\x1b[3;1H \x1b[48;5;33m\x1b[97m "bg-palette-33" \x1b[0m
                                                  -> row 2, cells 0..12   Style{ fg=palette(15), bg=palette(33) }
\x1b[4;1H \x1b[7m "reverse-video" \x1b[0m       -> row 3, cells 0..12   Style{ flags={inverse} }
\x1b[5;1H "wide:漢 graph:é blocks:█▄░▒"         -> row 4: wide cell (spacer tail handled),
                                                              multi-codepoint grapheme "e"+U+0301
\x1b[7;14H "end"                                 -> cursor parked at x=16 y=6 (0-based), as reported
```

So the output proves parsing, not just that the binary started: 57 cells carry a non-default style,
four distinct SGR-derived styles were recovered from the grid, the CUP cursor moves landed on the
requested rows/columns, the wide CJK cell and the combining-mark grapheme survived, and
`Terminal.plainString()` agrees with the row dump.

The Debug-mode GPA handed to `main` by `std.process.Init` printed no leak report and the process
exited `0`.

## API actually exercised (read from the pinned source, not from memory)

| Call | Source of truth |
|---|---|
| `ghostty_vt.Terminal.init(io, alloc, .{ .cols, .rows })` | `src/lib_vt.zig:96` → `src/terminal/Terminal.zig:329` |
| `Terminal.resize(alloc, .{ .cols, .rows })` | `src/terminal/Terminal.zig:4080` (`Resize` at `:4038`) |
| `Terminal.vtStream()` → `Stream.nextSlice(bytes)` | `src/terminal/Terminal.zig:401`; `src/terminal/stream.zig:641` |
| `Terminal.plainString(alloc)` | `src/terminal/Terminal.zig:4952` |
| `ghostty_vt.RenderState` `.empty` / `.update` / `.rowDataRange()` / `.viewportY()` | `src/terminal/render.zig:118`, `:481`, `:1050`, `:1032` |
| per-cell `page.Cell` (`style_id`, `wide`, `content_tag`, `codepoint()`, `hasGrapheme()`) | `src/terminal/page.zig:2137` |
| `Terminal.init` takes a `std.Io`; `ghostty_vt.TinyIo` is exported if you have none | `src/lib_vt.zig:39-51` |

`RenderState` is the intended renderer-side entry point, not an internal hack: its doc comment in
`src/terminal/render.zig` says it exists so that *libghostty-vt can convert terminal state into a
renderable form* and is renderer-agnostic.

## Findings worth carrying into the decision record

1. **`ghostty-vt.Style` cannot be formatted from a Zig 0.16 consumer.** Its `format` methods still
   use the pre-0.16 signature with `std.fmt.FormatOptions`, which no longer exists in Zig 0.16, so
   the `{f}` specifier does not even compile. Verified:

   ```
   zig-pkg/ghostty-1.3.2-dev-5UdBC…/src/terminal/style.zig:253:25: error: root source file struct 'fmt' has no member named 'FormatOptions'
       options: std.fmt.FormatOptions,
   ```

   The same stale signature exists on `ghostty_vt.Style.Color` (`src/terminal/style.zig:71`) and on
   `ghostty_vt.osc.Terminator` (`src/terminal/osc.zig:338`). `src/font/**` has more. Conduit's `term`
   module must therefore build its own style description (as this spike does) instead of relying on
   `{f}`/`{s}` formatting. It does not affect terminal *state*, only diagnostics.

2. **Build knobs available to a consumer** (from `example/zig-vt/build.zig` and
   `src/build/Config.zig`): `simd = false` forces a pure static build that does not require libc.
   This spike uses the default (`simd = true`), which is why the build compiles `simdutf` and
   `highway` from C++ and links libc.

3. **Only Zig 0.16.0 was exercised.** Windows and macOS were not built or run here; see the
   research slice's report for those.

4. **What this spike does *not* prove**: that Conduit can render the grid (renderer, fonts, glyph
   atlas), PTY/conpty integration, scrollback, selection, key/mouse encoding, or any platform other
   than Linux x86_64. It proves only that the terminal-state artifact is consumable as a Zig module,
   builds under the pinned Zig, and yields a correct grid.