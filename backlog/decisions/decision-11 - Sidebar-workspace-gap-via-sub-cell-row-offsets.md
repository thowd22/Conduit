---
id: decision-11
title: Sidebar workspace gap via sub-cell row offsets
date: '2026-10-07 20:56'
status: accepted
---
## Context

TASK-77 asks for "about 5 pixels" between the last tab of one workspace and the next workspace row
in the sidebar, with tab spacing inside a workspace unchanged. The sidebar is composed in whole
terminal cells (TASK-28): every element registers a cell `ui.Rect`, `ui.Geometry` maps it to
device-pixel bounds, and those bounds drive painting, hit testing, hover, focus, drag-reorder drops
and the test driver's `inspect` JSON. A full blank row would be a cell high (17 to 25 device pixels
on the development machine), several times the requested gap, and would cost a whole row of the
list above the TASK-74 footer for every extra workspace.

## Decision

- `ui.ElementRegistration` gains `offset_px: i32`, a downward shift in logical pixels, and
  `ui.Geometry` gains `pixel_scale` (device pixels per logical pixel, the window scale). At
  registration, `Geometry.offsetPx` rounds `offset_px × pixel_scale` to whole device pixels and
  `Geometry.boundsForShifted` moves the element's device-pixel bounds down by it before clipping.
  This is the only place the shift is applied to geometry.
- The element's reported `bounds` are the shifted device-pixel bounds. Hit testing, hover,
  press/release, focus visuals and the test driver read those bounds, so nothing else needed to
  learn about offsets, and the driver's JSON format is unchanged (it reports where the row really
  is; the offset is not a separate field).
- `Tree.render` stamps the same device-pixel shift on every canvas cell the element paints
  (`ui.Canvas.paint_offset_y_px` → `render.OverlayCell.offset_y_px`), and the overlay grid moves
  those cells' fills, decorations and glyphs down by it.
- The sidebar composer gives the n-th listed workspace (zero-based) and every row of its group
  (workspace row, tab rows, rename input, TASK-76 branch rows) an offset of `5 × n` logical pixels.
  The first workspace has none, and rows inside a group keep whole-cell spacing.
- The list limit above the footer is lowered by the group's device-pixel shift rounded up to whole
  rows (`sidebarRowLimit`), so a shifted row never reaches the blank row above the Palette hint and
  version line. A workspace whose shifted row would not fit is not listed, like any row past the
  limit.

## Consequences

- The gap is 5 logical pixels at every scale (6 device pixels at 1.25), between whole-cell rows.
- The pixels a shift uncovers belong to no element: a click in the gap does nothing.
- The last shifted row can overlap up to `5 × (n − 1)` pixels into the cell row below its own
  grid row; the limit calculation reserves that space, so nothing is drawn beneath it.
- With many workspaces the accumulated shift costs whole rows at the bottom of the list, one per
  cell height of accumulated gap, instead of one per workspace as blank rows would.
- Verified on Linux (Xvfb) at scale 1 and 1.25 through semantic bounds, real SDL clicks, drags and
  keyboard focus; macOS and Windows are unverified.

## Alternatives considered

- **A blank cell row before each workspace:** no renderer or tree change, but the gap is a whole
  row (three to five times what was asked) and each workspace costs a row of list space.
- **Reporting cell-aligned bounds plus a separate offset field in the driver JSON:** keeps the
  pixel bounds on the grid, but every consumer (hit testing, the driver's click targeting,
  accessibility) would have to apply the offset itself, which is a second representation of where
  an element is.
- **Variable row heights in `ui`:** the general solution, but it would change every cell-based
  layout and the one-cell-per-row canvas for a 5-pixel separator.
