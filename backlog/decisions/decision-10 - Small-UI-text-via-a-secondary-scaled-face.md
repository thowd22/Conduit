---
id: decision-10
title: Small UI text via a secondary scaled face
date: '2026-10-07 20:56'
status: accepted
---
## Context

TASK-76 shows each tab's git branch beneath its name "about half the size of the tab name text and
slightly subdued", like the herdr app the user referenced. Until now the UI renderer drew every
glyph at the terminal cell size: `ui` lays everything out in whole terminal cells (TASK-18/19),
`ui.Canvas` holds one grapheme per cell, and `render.Grid.drawCanvasOverlay` draws each overlay
cell with the one `font.Manager` the terminal uses. A `font.Manager` is built for one `font.Size`;
a different size is a different manager with its own atlases (TASK-10/39). The semantic tree, hit
testing and the test driver all work in cell rectangles mapped to device pixels, and AGENTS.md
invariants 2 and 3 forbid a new primitive or a second representation of the tree.

## Decision

- `ui.TextStyle` gains `small: bool`. It is a style, not a primitive: a `Text` run (or any
  primitive's style) may ask for it. Layout, clipping, bounds and hit testing stay in whole cells;
  the branch row is still exactly one terminal cell high.
- The app builds a second `font.Manager` on the same loader job as the main one, from the same
  request (family, style faces, fallbacks, ligature and symbol settings) at 0.6 of the configured
  point size and the same display scale, with a 512×512 coverage atlas and a 128×128 colour atlas.
  At 0.6 the x-height reads as about half the tab name's. It is replaced whenever the main face is
  (font change, size change, display-scale change); if it cannot be built, small text draws at the
  normal size.
- The overlay `render.Grid` attaches that manager's atlas as a second coverage texture
  (`attachSmallAtlas`). An `OverlayCell.small` keeps its full cell for fills and decorations; its
  glyph is shaped and rasterised by the small manager, centred vertically in the cell, and packed
  horizontally at the small face's advance with the small cells immediately before it on the same
  row (`render.SmallRun`), then drawn in its own instanced pass over the small texture. Colour
  glyphs are not drawn small. The colour comes from the theme role the run names (`muted` for
  branch rows).
- Because a canvas cell still holds one grapheme, a small run has at most as many graphemes as its
  cell width; the sidebar ellipsizes a branch name that does not fit and keeps the full name as the
  element's semantic label.

## Consequences

- Smaller text exists without a new primitive, a second tree or sub-cell layout: the semantic
  tree, hit testing and the driver are unchanged, and a branch row is addressed like any other
  element.
- Startup builds two managers; each scans the font catalog, measured at about 20 ms on the
  development machine. The small manager's atlases add roughly 0.3 MiB.
- A small run occupies about 60 % of its cells' width, so the rest of a branch row is empty space,
  and a name longer than the row's cells is ellipsized even when its small glyphs would have fit.
- Only the full-canvas overlay draws small glyphs; the legacy terminal-row overlay path ignores
  the flag.
- Verified on Linux (Xvfb, llvmpipe) at scale 1 and 1.25; macOS and Windows rendering are
  unverified.

## Alternatives considered

- **A reduced-height row** (half a cell): breaks the whole-cell grid every element, hit test and
  driver bound relies on, and needs sub-cell layout everywhere for one row.
- **Scaling the normal glyph quads at draw time:** cheap, but a 0.6× bilinear or nearest-neighbour
  scale of coverage rasterised for a larger size is blurry or jagged, unlike every other glyph.
- **Rasterising the small size into the main manager's atlas:** keeps one texture, but the manager,
  its glyph cache keys and its sprites are built around one size; mixing sizes would need changes
  throughout `font` for one sidebar row.
- **Packing several small graphemes into one canvas cell:** would let a long name use the whole
  row, but makes a canvas cell no longer one grapheme, which the canvas, its wide-cell repair and
  the renderer's validation all assume.
