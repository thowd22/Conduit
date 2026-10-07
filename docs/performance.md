# Performance: benchmarks and budgets (TASK-67)

Conduit's performance is measured by four benchmark programs under `bench/`, run from the build,
and held to the budgets in `bench/budgets.zig`. This document records the method, the reference
machine, the numbers measured on it, and the budgets derived from them.

## Running

```sh
zig build bench                                  # run everything, print JSON lines and a summary
zig build bench -- --json=.zig-cache/bench/run.jsonl   # also write the JSON lines to a file
zig build bench -- --only=frame,memory --quick   # a subset; --quick skips the 64 MiB inputs
zig build bench-check                            # the same, then fail on any budget breach
```

- The benchmarks build **ReleaseSafe** (the shipped mode) unless `-Doptimize` or `--release` names
  a mode explicitly. When that differs from the main build's mode the modules, third-party seams
  and the app are wired a second time at the benchmark mode, so the startup benchmark launches an
  optimised `conduit`, not the installed Debug one. The Ghostty engine is always at least
  ReleaseSafe (TASK-72).
- Each benchmark is its own process (`conduit-bench-throughput`, `-frame`, `-memory`,
  `-startup`), run by `conduit-bench` (`bench/runner.zig`), so one benchmark's allocations and
  resident pages never appear in another's numbers.
- Output: one JSON object per measured case on stdout (the runner echoes them after a `meta` line
  that records optimisation mode, OS, CPU, core count and memory), and a human summary on stderr.
- The frame, throughput (`grid` mode) and startup benchmarks need a display. Without `DISPLAY` or
  `WAYLAND_DISPLAY` the runner starts them under `xvfb-run -a -s "-screen 0 1920x1080x24"` when it
  is installed. A benchmark with no GL context reports `"skipped"`; `bench-check` then fails on the
  missing measurement rather than passing quietly.
- Inputs are generated from fixed patterns; no network, no user config, no user fonts beyond what
  the font manager's default (bundled JetBrains Mono plus system fallback) resolves. Startup runs
  in fresh private roots under `/tmp`, removed afterwards.

## What each benchmark measures

**Throughput** (`bench/throughput.zig`). A 160x50 `term.Terminal` with the default 10,000-line
scrollback is fed 16 and 64 MiB of four generated workloads in the 64 KiB slices the app's pump
reads: `plain` (79 printable columns and CRLF), `cr-flood` (records that overwrite one row),
`sgr` (every word in its own 256-colour SGR with bold/underline) and `cjk` (39 wide glyphs a
line). Three modes: `term` feeds only; `refresh` adds, whenever a frame is due, `refresh` and a
read of every visible cell; `grid` adds a real `render.Grid.draw` into the offscreen FBO plus
`glFinish`. A frame is due after `max(16 ms, last frame's cost)`, which is `FramePacer`'s rule.
Reported: MiB/s, lines/s, frames drawn.

**Frame** (`bench/frame.zig`). 1, 4 and 9 panes tiling a 1920x1080 logical surface (one-cell
dividers) at display scales 1 and 2, each pane a real terminal holding coloured SGR output and
drawn by its own `Grid` through `drawViewport`, the app's pane path. Two cases: `full` (every
pane invalidated, every row redrawn) and `one-row` (one row of one pane changes, the others have
no damage). A 1-pane `cjk` layout fills the screen with 1,800 distinct ideographs. 10 warm-up and
120 measured frames; reported as medians and p95 of `submit` (CPU: staging, shaping, uploads and
GL calls, before `glFinish`) and `finish` (after `glFinish`), plus glyphs rasterised per measured
frame and the first frame's cost. On a software renderer the record carries `"indicative": true`.

**Memory** (`bench/memory.zig`). A local `workspace.Workspace` spawns real PTY children that each
print 10,100 full-width (159-column) lines into a 160x50 terminal and then idle in `cat`. The
workspace is pumped as the event loop pumps it until every session shows its marker and has
nothing left to drain, then the process RSS and the allocator's live/peak bytes are read with one
such session and with eight. Ghostty maps its scrollback pages itself rather than through the
allocator it is given, so RSS is the number that bounds a session; the allocator counts are
Conduit's own heap beside it.

**Startup** (`bench/startup.zig`). Five runs of `conduit-test launch` (960x640, scale 1, a fresh
private root each time, child `/bin/sh -i` with a fixed prompt and no rc files) followed by
`wait-for terminal-text` on the prompt. `launch` returns once the test driver answers an
`inspect` (it polls every 20 ms, which is that number's resolution); `prompt` is the time to the
prompt being in the terminal. Median of five.

## Reference hardware

| | |
|---|---|
| CPU | AMD Ryzen 7 5700G with Radeon Graphics, 8 cores / 16 threads |
| Memory | 26 GiB |
| GPU | none used: Mesa llvmpipe (LLVM 21.1.8, 256 bits), OpenGL 4.5 core, under Xvfb |
| OS | Ubuntu, Linux 7.0, glibc 2.43 |
| Build | Zig 0.16.0, ReleaseSafe, Ghostty `5dc28bb8` |

The machine is a shared, headless development box with no GPU, and other builds ran during some
measurements. GPU-side numbers are llvmpipe's: they measure the CPU rasteriser and are indicative
only. `submit` on llvmpipe also includes the driver's vertex processing and binning, which runs on
the calling thread; on a hardware GPU it is far smaller. The budgets below therefore bound this
machine, and a different reference machine needs its own measurement pass.

## Measured numbers (reference hardware, after tuning)

From `.zig-cache/bench/check.jsonl` (`zig build bench-check`, 2026-10-07).

### Throughput (MiB/s; lines/s in brackets)

| Workload | `term` | `refresh` | `grid` (llvmpipe) |
|---|---|---|---|
| plain 16 MiB | 94.7 (1.22 M) | 93.1 | 68.6 |
| plain 64 MiB | 94.1 (1.22 M) | 93.9 | 72.1 |
| cr-flood 16 MiB | 1234 (21.2 M records) | 1222 | 823 |
| cr-flood 64 MiB | 1263 | 1218 | 1094 |
| sgr 16 MiB | 54.4 (241 k) | 53.9 | 41.0 |
| sgr 64 MiB | 53.9 | 53.4 | 41.0 |
| cjk 16 MiB | 129.6 (1.14 M) | 129.4 | 91.2 |
| cjk 64 MiB | 129.8 | 128.5 | 101.2 |

The `term` column is the Ghostty engine at ReleaseSafe with SIMD; Conduit adds nothing measurable
on top (`refresh` within 1 %). Scrolling (one page-list operation per line) bounds `plain`; style
interning bounds `sgr` (the engine also logs a page-capacity change for it, silenced in the
benchmark). A frame that redraws every row costs `grid` about 25 % at the 16 ms cadence on
llvmpipe.

### Frame time (ms, median; 1920x1080 logical)

| Layout | scale 1 submit | scale 1 + glFinish | scale 2 submit | scale 2 + glFinish |
|---|---|---|---|---|
| 1 pane, full (240x54) | 4.39 | 5.21 | 4.90 | 9.08 |
| 4 panes, full | 5.95 | 7.34 | 6.55 | 11.33 |
| 9 panes, full (79x17 each) | 7.48 | 9.04 | 7.16 | 12.01 |
| 1 pane, one row | 0.11 | 0.21 | 0.11 | 0.35 |
| 9 panes, one row | 0.07 | 0.17 | 0.08 | 0.29 |
| 1 pane CJK, full | 5.04 | 6.71 | 118.3 (see below) | 124.4 |
| 1 pane CJK, one row | 0.12 | 0.24 | 2.80 | 3.12 |

First frame of a fresh layout (every glyph rasterised and uploaded): 19 ms (1 pane) to 26 ms
(9 panes) at scale 1; 43 ms for the CJK screen.

A probe split the 1-pane full frame (4.4 ms submit) into Conduit's own staging, 1.3 ms (reading
cells 0.12 ms, glyph resolution and atlas lookup about 0.6 ms, the rest instance building and
ligature shaping), and llvmpipe's share of the GL calls, 3.2 ms. With nine panes staging is
2.6 ms and GL 5.0 ms: per-pane cost is mostly the driver's per-draw overhead.

### Memory (160x50 sessions, 10,100 full-width lines each)

| Case | Scrollback rows kept | Process RSS | RSS per session | Heap live per session |
|---|---|---|---|---|
| 1 session | 9,761 | 19.3 MiB | 14.7 MiB | 0.72 MiB |
| 8 sessions | 9,761 each | 118.5 MiB | 14.2 MiB | 0.72 MiB |

The engine prunes whole pages, so a 10,000-line limit keeps 9,761 rows at this width. Memory per
session scales with the terminal's width; an 80-column session is about half.

### Startup

| | median | runs |
|---|---|---|
| `launch` (driver answering) | 235 ms | |
| first prompt | 241 ms | 218, 229, 241, 253, 255 |

The app's own log for one run: process start to window and GL context 72 ms (SDL, X11 and
llvmpipe initialisation), settings and fonts 18 ms, theme 15 ms, driver listening at 105 ms,
child attached at 198 ms; `launch` saw the driver at 215 ms. The 93 ms between the driver
listening and the child attaching is the first event-loop iterations: most likely the first
frame's shader compilation on llvmpipe, plus the child-spawn worker, whose completion the loop
only notices on its 16 ms poll (see recommendations). It was not instrumented further because
`src/main.zig` was outside this task's file ownership.

## Tuning (before → after)

Profiling: `perf` is installed but `kernel.perf_event_paranoid` is 4 and there is no root, so the
hot paths were found with temporary monotonic-clock probes around `Grid.drawFrame`'s staging and
GL halves and around the cell, resolve and atlas lookups (removed again).

1. **Glyph atlas lookup by hash index** (`src/font.zig`, `Atlas.index`). `Atlas.find`, called for
   every glyph of every redrawn cell, scanned every slot; `slotFor` did the same on insertion. A
   key-to-slot map (a key only ever gets one slot, so the map never needs an entry removed) makes
   both a hash lookup. Hits, misses, LRU ticks and slot reuse are unchanged (new unit test
   compares them across eviction and re-insertion; a failing allocation leaves the atlas
   unchanged).
2. **Guillotine split along the shorter leftover** (`src/font.zig`, `Atlas.allocate`). The
   allocator always cut a full-height strip to the right and a strip below only as wide as the
   glyph, so a column narrowed to the narrowest glyph ever placed in it. With varying glyph sizes
   (CJK from a fallback face, especially at scale 2) it found no free rectangle wide enough while
   most of the atlas was empty, evicted glyphs it was about to draw, and failed some insertions
   outright, which draws a blank cell. Cutting along the shorter leftover keeps columns at their
   width. Glyph pixels and sampling are unchanged (only atlas positions move): `--grid-test`,
   `--font-test`, the e2e `font-coverage` scenario and a scale-2 CJK screenshot were checked. A
   regression test inserting 1,800 varying-size glyphs into a 1024x1024 atlas (43 % of its area)
   fails on the old cut and passes on the new one.

| Measurement | Before | After |
|---|---|---|
| 1-pane CJK full frame, scale 1, submit median | 7.57 ms | 4.91–5.04 ms |
| 1-pane CJK one-row frame, scale 1 | 0.25 ms | 0.12 ms |
| 1,800 CJK glyphs at scale 2 into a 2048² atlas, two passes | 2,210 evictions, 1,390 live | 0 evictions, 1,800 live |
| the same into the app's 1024² atlas | 738 failed insertions (blank cells), 44 live | 1 failed, 587 live |
| 1-pane CJK full frame, scale 2, 2048² atlas (before: index already in) | 128.7 ms (6,272 glyphs rasterised a frame) | 5.20 ms (0 rasterised) |
| every other frame and throughput case | — | unchanged within noise |

### Known limit: the app's atlas at display scale 2

The app sizes its coverage atlas at 1024x1024 whatever the display scale (`atlas_width_px` /
`atlas_height_px` in `src/main.zig`). At scale 2 a screen of about 1,800 distinct CJK glyphs needs
1.29 M atlas pixels, more than the atlas holds, so a full redraw re-rasterises every glyph through
LRU eviction (118 ms a frame in the `1-pane-scale2-cjk-full` case). With a 2048x2048 atlas and the
new allocator the same frame is 5.2 ms. Recommended (not made here, `src/main.zig` is outside this
task's ownership): size the atlas by display scale, for example 2048x2048 at scale 1.5 and above
(4 MiB on the CPU and 4 MiB on the GPU). A related cost: `Grid.uploadAtlas` re-uploads the whole
atlas whenever any glyph was added or evicted, which a dirty-rectangle upload would bound.

## Budgets

`zig build bench-check` fails when any of these is crossed. Each is the measurement above with
25 % headroom (time and size x 1.25, rate / 1.25), rounded; the one-row frame has a 0.25 ms floor
because sub-0.1 ms timings jitter by more than 25 %. They are in `bench/budgets.zig`; change both
together.

| Benchmark | Case | Metric | Budget | Measured |
|---|---|---|---|---|
| throughput | plain-16MiB-term | MiB/s | ≥ 75 | 94.7 |
| throughput | plain-64MiB-term | MiB/s | ≥ 75 | 94.1 |
| throughput | plain-16MiB-grid | MiB/s | ≥ 54 | 68.6 |
| throughput | cr-flood-16MiB-term | MiB/s | ≥ 990 | 1234 |
| throughput | sgr-16MiB-term | MiB/s | ≥ 43 | 54.4 |
| throughput | sgr-16MiB-grid | MiB/s | ≥ 33 | 41.0 |
| throughput | cjk-16MiB-term | MiB/s | ≥ 103 | 129.6 |
| frame | 1-pane-scale1-full | submit ms | ≤ 5.6 | 4.39 |
| frame | 9-pane-scale1-full | submit ms | ≤ 9.3 | 7.48 |
| frame | 9-pane-scale2-full | submit ms | ≤ 9.0 | 7.16 |
| frame | 9-pane-scale1-one-row | submit ms | ≤ 0.25 | 0.07 |
| frame | 1-pane-scale1-cjk-full | submit ms | ≤ 6.1 | 5.04 |
| startup | launch-to-prompt | median ms | ≤ 300 | 241 |
| memory | 1-session | RSS MiB per session | ≤ 18.4 | 14.7 |
| memory | 8-sessions | RSS MiB per session | ≤ 17.8 | 14.2 |

What the budgets mean for a user on this machine: a 9-pane full redraw fits in half a 60 Hz frame
even on a software rasteriser; an idle frame with one changed row costs about a tenth of a
millisecond; output is consumed at 50–130 MiB/s of real text while frames keep coming; the first
prompt appears in about a quarter of a second; and a session with a full default scrollback costs
about 15 MiB at 160 columns.

## Large-output flood: no dropped input, bounded memory

`src/workspace.zig`, test "a 64 MiB flood drops no typed input and keeps memory bounded": a real
PTY child floods 64 MiB of scrolling 64-column lines while the owner types a numbered sentinel
line every 100 ms (20 lines); the child answers each line it reads with an OSC 0 title, which can
only arrive by being parsed out of the same output stream as the flood. The workspace is pumped
with the event loop's `DrainBudget`. All 20 sentinels came back once each and in order, all typed
while the flood was still running (it lasts about 3 s in the Debug test build). The allocator's
high-water mark (a counting wrapper) peaked at 116 KiB against a 1 MiB cap, the scrollback
stayed at its limit, and the process RSS grew 8.4 MiB against a 32 MiB cap while 64 MiB went
through. The `output-flood` e2e scenario additionally types a second command through
`conduit-test type` while the 4 MB flood runs and waits for its expanded marker after the flood's
own, so typed-ahead keys survive a flood through the real app's input path too.

## Wiring `bench-check` into CI

Not added to any workflow by this task. To enforce the budgets on Linux, add a step after the
build in `.github/workflows/linux-e2e.yml` (which already installs Xvfb):

```yaml
      - name: Performance budgets
        run: xvfb-run -a zig build bench-check -- --json=bench-results.jsonl
      - uses: actions/upload-artifact@v4
        if: always()
        with: { name: bench-results, path: bench-results.jsonl }
```

Hosted runners are not the reference machine: their numbers differ from these, and their
variance is higher. Before making the step blocking, run it a few times on the runner, set
runner-specific budgets (a second table the runner selects with a new flag, or the same table
with wider headroom), and keep the reference-hardware budgets for local `bench-check`.
