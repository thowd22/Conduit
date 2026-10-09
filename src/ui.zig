//! Conduit's UI toolkit: the four primitives, and the single tree they
//! register into.
//!
//! `ui` owns `Text`, `InteractiveText`, `Surface` and `Input`, and the semantic
//! element tree they register into — stable id, role, label, state, bounds,
//! action — plus hit testing, hover, focus, and the terminal-styled UI
//! renderer.
//!
//! There is no fifth primitive, no widget kind, no icon and no native chrome
//! (P4, invariant 2): the sidebar, tabs, splits, command palette, scratchpad,
//! agent view, backlog view and settings screen are compositions of these four,
//! composed above `ui` by the module that owns the feature. The tree is the
//! only representation of what is on screen (P5), and the UI is never drawn as
//! ANSI through the terminal (P6). `ui` may depend on `term`, `render`, `font`
//! and `theme`, and on nothing above the primitive layer.
//!
//! `Canvas`, `Input` and `Tree` own their storage through an explicit allocator.
//! A canvas allocates only when it is initialized or resized; tree registration,
//! interaction, rendering and projection allocate nothing. Stable id and
//! parent bytes remain valid for the Tree lifetime (or until the referenced
//! element has disappeared after frame reconciliation); other text, roles,
//! labels, action names and Input pointers are borrowed through a frame. The
//! tree returns inert activation values; TASK-20 owns dispatch into the action
//! registry.

const std = @import("std");
const font = @import("font");
const render = @import("render");
const term = @import("term");
const theme = @import("theme");

const Allocator = std.mem.Allocator;

/// The log scope for UI diagnostics.
pub const log = std.log.scoped(.ui);

/// The four UI primitives. There are four, and adding a fifth is a product
/// change rather than a refactor.
///
/// A tag here is the primitive's identity in the tree's role, so it is the one
/// place a view says what kind of thing it is.
pub const Primitive = enum {
    /// Read-only content. It says something; it cannot be acted on.
    text,
    /// Content that carries an action, so it is clickable and focusable.
    interactive_text,
    /// A background other content is drawn over. Painted, never acted on.
    surface,
    /// A field that takes typed text.
    input,

    /// Whether the primitive can carry an action, and therefore needs bounds
    /// and an action in the tree. A surface is painted over and a plain text is
    /// read; the other two are the ones a click and a key can land on.
    pub fn isInteractive(self: Primitive) bool {
        return self == .interactive_text or self == .input;
    }
};

/// Why a string is not a usable element id.
pub const IdError = error{InvalidId};

/// A semantic element's stable id: what the test driver addresses an element
/// by, and what a keybinding and a palette entry are bound to.
///
/// An id is text rather than a counter because it outlives the frame it was
/// created in — the tree is rebuilt constantly, and ids are how anything
/// outside the tree refers to it (P5).
pub const Id = struct {
    /// The id itself, borrowed from whatever produced it. An `Id` never owns
    /// these bytes, so the owner keeps them alive; Tree registration requires
    /// the stronger stable-id lifetime documented by `ElementRegistration`.
    value: []const u8,

    /// An id from `raw`, or `error.InvalidId` if it is malformed UTF-8 or cannot
    /// address exactly one element: it is empty, or it holds ASCII whitespace,
    /// DEL or a C1 control character.
    pub fn parse(raw: []const u8) IdError!Id {
        if (raw.len == 0) return error.InvalidId;
        const view = std.unicode.Utf8View.init(raw) catch return error.InvalidId;
        var iterator = view.iterator();
        while (iterator.nextCodepoint()) |codepoint| {
            if (codepoint <= ' ' or
                (codepoint >= 0x7f and codepoint < 0xa0))
            {
                return error.InvalidId;
            }
        }
        return .{ .value = raw };
    }
};

/// A point in device pixels: the coordinates a pointer reports, and what hit
/// testing compares bounds against.
pub const Point = struct {
    /// Horizontal position, which may be negative for a point left of the
    /// surface.
    x: i32,
    /// Vertical position, on the same terms as `x`.
    y: i32,
};

/// A rectangle in device pixels: the geometry every element registers in the
/// tree, and the geometry hit testing and the renderers work in.
///
/// The origin may be negative, because an element scrolled out of view is still
/// registered; the extents are pixel counts, so they cannot be negative. A zero
/// extent is legal and means the element covers no pixels.
pub const Bounds = struct {
    /// The leftmost pixel column covered.
    x: i32,
    /// The topmost pixel row covered.
    y: i32,
    /// How many pixel columns are covered.
    width: u32,
    /// How many pixel rows are covered.
    height: u32,

    /// Bounds that cover no pixels: what an element registers with before it
    /// has been laid out.
    pub const empty: Bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

    /// Whether the bounds cover no pixels.
    pub fn isEmpty(self: Bounds) bool {
        return self.width == 0 or self.height == 0;
    }

    /// Whether `point` is inside the bounds. The trailing edges are outside:
    /// bounds cover pixels, not the boundaries between them, so two adjacent
    /// elements do not both claim the point on their shared edge.
    pub fn contains(self: Bounds, point: Point) bool {
        if (self.isEmpty()) return false;
        const dx = @as(i64, point.x) - @as(i64, self.x);
        const dy = @as(i64, point.y) - @as(i64, self.y);
        return dx >= 0 and dy >= 0 and
            dx < @as(i64, self.width) and dy < @as(i64, self.height);
    }

    /// The overlap of two bounds, or `null` when they do not overlap. Bounds
    /// that merely touch do not overlap: an intersection with no area is no
    /// intersection.
    pub fn intersect(a: Bounds, b: Bounds) ?Bounds {
        if (a.isEmpty() or b.isEmpty()) return null;

        const left = @max(@as(i64, a.x), @as(i64, b.x));
        const top = @max(@as(i64, a.y), @as(i64, b.y));
        const right_edge = @min(a.right(), b.right());
        const bottom_edge = @min(a.bottom(), b.bottom());
        if (right_edge <= left or bottom_edge <= top) return null;

        return .{
            .x = @intCast(left),
            .y = @intCast(top),
            .width = @intCast(right_edge - left),
            .height = @intCast(bottom_edge - top),
        };
    }

    /// The smallest bounds containing both. An empty operand contributes
    /// nothing: a laid-out element never swallows an unlaid-out one.
    pub fn enclosing(a: Bounds, b: Bounds) Bounds {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;

        const left = @min(@as(i64, a.x), @as(i64, b.x));
        const top = @min(@as(i64, a.y), @as(i64, b.y));
        return .{
            .x = @intCast(left),
            .y = @intCast(top),
            .width = @intCast(@max(a.right(), b.right()) - left),
            .height = @intCast(@max(a.bottom(), b.bottom()) - top),
        };
    }

    /// The first pixel column past the right edge, in the wide arithmetic the
    /// bounds algebra is done in so that no sum of two extents can overflow.
    pub fn right(self: Bounds) i64 {
        return @as(i64, self.x) + @as(i64, self.width);
    }

    /// The first pixel row past the bottom edge.
    pub fn bottom(self: Bounds) i64 {
        return @as(i64, self.y) + @as(i64, self.height);
    }
};

/// A rectangle in terminal cells.
///
/// Coordinates and extents saturate instead of overflowing. Painting clips a
/// rectangle to the canvas, so a layout may safely extend beyond a viewport.
pub const Rect = struct {
    /// Zero-based left column.
    x: u32,
    /// Zero-based top row.
    y: u32,
    /// Width in terminal cells.
    width: u32,
    /// Height in terminal cells.
    height: u32,

    /// A rectangle containing no cells.
    pub const empty: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

    /// Whether this rectangle contains no cells.
    pub fn isEmpty(self: Rect) bool {
        return self.width == 0 or self.height == 0;
    }

    /// First column after the rectangle, saturated to the coordinate range.
    pub fn right(self: Rect) u32 {
        return self.x +| self.width;
    }

    /// First row after the rectangle, saturated to the coordinate range.
    pub fn bottom(self: Rect) u32 {
        return self.y +| self.height;
    }

    /// The overlap of two cell rectangles.
    pub fn intersect(a: Rect, b: Rect) Rect {
        const left = @max(a.x, b.x);
        const top = @max(a.y, b.y);
        const right_edge = @min(a.right(), b.right());
        const bottom_edge = @min(a.bottom(), b.bottom());
        if (right_edge <= left or bottom_edge <= top) return empty;
        return .{
            .x = left,
            .y = top,
            .width = right_edge - left,
            .height = bottom_edge - top,
        };
    }

    /// Remove `insets`, clipping an over-large inset to what remains.
    pub fn inset(self: Rect, insets: Insets) Rect {
        const left = @min(self.width, insets.left);
        const after_left = self.width - left;
        const right_inset = @min(after_left, insets.right);
        const top = @min(self.height, insets.top);
        const after_top = self.height - top;
        const bottom_inset = @min(after_top, insets.bottom);
        return .{
            .x = self.x +| left,
            .y = self.y +| top,
            .width = after_left - right_inset,
            .height = after_top - bottom_inset,
        };
    }

    /// Centre a requested size inside this rectangle, clipping it to fit.
    pub fn centred(self: Rect, width: u32, height: u32) Rect {
        const fitted_width = @min(width, self.width);
        const fitted_height = @min(height, self.height);
        return .{
            .x = self.x +| (self.width - fitted_width) / 2,
            .y = self.y +| (self.height - fitted_height) / 2,
            .width = fitted_width,
            .height = fitted_height,
        };
    }
};

/// Insets in cells, applied independently on each edge.
pub const Insets = struct {
    /// Cells removed from the top.
    top: u32 = 0,
    /// Cells removed from the right.
    right: u32 = 0,
    /// Cells removed from the bottom.
    bottom: u32 = 0,
    /// Cells removed from the left.
    left: u32 = 0,
};

/// The direction a sequence of layout tracks advances.
pub const Axis = enum {
    /// Tracks run from left to right.
    horizontal,
    /// Tracks run from top to bottom.
    vertical,
};

/// One cell-layout track: an exact request or an equal share of the remainder.
pub const Track = union(enum) {
    /// Request this many cells, clipped when fixed tracks exceed the extent.
    fixed: u32,
    /// Share the cells left after fixed tracks equally with every fill track.
    fill,
};

/// A split cannot write partial output: the caller provides one slot per track.
pub const SplitError = error{OutputTooSmall};

/// Split `bounds` along `axis` without allocating.
///
/// Fixed tracks are clipped in declaration order when they do not fit. Fill
/// tracks divide the remainder equally; an indivisible remainder is assigned
/// one cell at a time to the earliest fill tracks.
pub fn split(bounds: Rect, axis: Axis, tracks: []const Track, output: []Rect) SplitError![]Rect {
    if (output.len < tracks.len) return error.OutputTooSmall;
    const extent = if (axis == .horizontal) bounds.width else bounds.height;

    var fixed_total: u64 = 0;
    var fill_count: u32 = 0;
    for (tracks) |track| switch (track) {
        .fixed => |size| fixed_total = @min(
            fixed_total +| @as(u64, size),
            @as(u64, std.math.maxInt(u32)),
        ),
        .fill => fill_count +|= 1,
    };
    const fixed_fitted: u32 = @intCast(@min(fixed_total, extent));
    const fill_total = extent - fixed_fitted;
    const fill_size = if (fill_count == 0) 0 else fill_total / fill_count;
    var fill_remainder = if (fill_count == 0) 0 else fill_total % fill_count;
    var consumed: u32 = 0;

    for (tracks, 0..) |track, index| {
        const left = extent - consumed;
        const wanted: u32 = switch (track) {
            .fixed => |size| size,
            .fill => blk: {
                const extra: u32 = if (fill_remainder > 0) 1 else 0;
                if (fill_remainder > 0) fill_remainder -= 1;
                break :blk fill_size + extra;
            },
        };
        const size = @min(wanted, left);
        output[index] = switch (axis) {
            .horizontal => .{
                .x = bounds.x +| consumed,
                .y = bounds.y,
                .width = size,
                .height = bounds.height,
            },
            .vertical => .{
                .x = bounds.x,
                .y = bounds.y +| consumed,
                .width = bounds.width,
                .height = size,
            },
        };
        consumed += size;
    }
    return output[0..tracks.len];
}

/// Terminal-cell styling shared by all four primitives.
///
/// Roles remain symbolic while primitives compose. `Canvas.view` resolves
/// them through the current palette into renderer-owned RGBA values.
pub const TextStyle = struct {
    /// Glyph colour.
    foreground: theme.Role = .foreground,
    /// Cell fill, or transparent when null.
    background: ?theme.Role = null,
    /// Exact configured face requested for the glyph.
    face_style: font.FaceStyle = .regular,
    /// Underline colour, or no underline.
    underline: ?theme.Role = null,
    /// Strikethrough colour, or no strikethrough.
    strikethrough: ?theme.Role = null,
    /// Overline colour, or no overline.
    overline: ?theme.Role = null,
    /// Draw glyphs with the secondary small face, vertically centred in the
    /// cell (TASK-76). Layout, clipping and hit testing stay in whole cells.
    small: bool = false,
};

const CellKind = enum {
    empty,
    head,
    tail,
};

/// One final composed canvas cell. Text is borrowed from a primitive or an
/// Input and stays live until the projected overlay has been drawn.
const CanvasCell = struct {
    kind: CellKind = .empty,
    text: []const u8 = "",
    span: render.OverlaySpan = .one,
    style: TextStyle = .{},
    /// Device-pixel downward shift of the element that painted this cell.
    offset_y_px: i32 = 0,

    fn hasPaint(self: CanvasCell) bool {
        return self.text.len != 0 or self.style.background != null or
            self.style.underline != null or self.style.strikethrough != null or
            self.style.overline != null;
    }
};

/// Why a canvas cannot own the requested cell grid.
pub const CanvasError = Allocator.Error || error{GridTooLarge};

/// A reusable, flattened cell canvas for the UI renderer.
///
/// `Canvas` owns `cells` and its projection buffer. `init` and `resize` may
/// allocate; `clear`, primitive drawing and `view` do not. Painter order is
/// call order, and `view` contains the final non-overlapping cells in row-major
/// order. Text slices in a returned view are borrowed from their primitives
/// and remain valid only while those sources do.
pub const Canvas = struct {
    /// Allocator that owns both fixed-capacity buffers.
    allocator: Allocator,
    /// Canvas width in cells.
    cols: u32,
    /// Canvas height in cells.
    rows: u32,
    /// Final painter-composed cells, one slot per grid position.
    cells: []CanvasCell,
    /// Reused row-major renderer projection.
    projected: []render.OverlayCell,
    /// Entries currently initialized in `projected`.
    projected_len: usize = 0,
    /// Device-pixel shift applied to cells painted from now on. `Tree.render`
    /// sets it per element from `ElementRegistration.offset_px` (TASK-77).
    paint_offset_y_px: i32 = 0,

    /// Allocate a canvas and projection slot for every cell in the grid.
    pub fn init(allocator: Allocator, cols: u32, rows: u32) CanvasError!Canvas {
        const count = cellCount(cols, rows) orelse return error.GridTooLarge;
        const cells = try allocator.alloc(CanvasCell, count);
        errdefer allocator.free(cells);
        const projected = try allocator.alloc(render.OverlayCell, count);
        @memset(cells, .{});
        return .{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .cells = cells,
            .projected = projected,
        };
    }

    /// Release both buffers owned by this canvas.
    pub fn deinit(self: *Canvas) void {
        self.allocator.free(self.projected);
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    /// Replace the cell grid atomically. A failed resize leaves the old grid
    /// and its contents intact.
    pub fn resize(self: *Canvas, cols: u32, rows: u32) CanvasError!void {
        if (cols == self.cols and rows == self.rows) {
            self.clear();
            return;
        }
        const count = cellCount(cols, rows) orelse return error.GridTooLarge;
        const cells = try self.allocator.alloc(CanvasCell, count);
        errdefer self.allocator.free(cells);
        const projected = try self.allocator.alloc(render.OverlayCell, count);
        @memset(cells, .{});

        self.allocator.free(self.projected);
        self.allocator.free(self.cells);
        self.cols = cols;
        self.rows = rows;
        self.cells = cells;
        self.projected = projected;
        self.projected_len = 0;
    }

    /// Remove every UI cell while retaining both allocations.
    pub fn clear(self: *Canvas) void {
        @memset(self.cells, .{});
        self.projected_len = 0;
    }

    /// Remove prior UI paint inside `rect` without adding new paint.
    ///
    /// This is the transparent counterpart to `paintFill`: a later Surface
    /// can mask an earlier UI layer while leaving a separately rendered
    /// terminal visible underneath it.
    fn eraseRect(self: *Canvas, rect: Rect) void {
        const clipped = Rect.intersect(rect, self.bounds());
        var row = clipped.y;
        while (row < clipped.bottom()) : (row += 1) {
            var col = clipped.x;
            while (col < clipped.right()) : (col += 1) {
                const index = self.indexOf(col, row) orelse continue;
                self.detach(col, row);
                self.cells[index] = .{};
            }
        }
    }

    /// The drawable extent of this canvas in cells.
    pub fn bounds(self: *const Canvas) Rect {
        return .{ .x = 0, .y = 0, .width = self.cols, .height = self.rows };
    }

    /// Project the flattened cells into renderer-owned values without
    /// allocating. The returned view is invalidated by the next mutation,
    /// projection, resize or deinitialization of this canvas.
    pub fn view(self: *Canvas, palette: *const theme.Palette) render.OverlayView {
        var count: usize = 0;
        for (self.cells, 0..) |cell, index| {
            if (cell.kind != .head or !cell.hasPaint()) continue;
            const col: u32 = @intCast(index % @as(usize, self.cols));
            const row: u32 = @intCast(index / @as(usize, self.cols));
            self.projected[count] = .{
                .position = .{ .col = col, .row = row },
                .foreground = resolveRole(palette, cell.style.foreground),
                .span = cell.span,
                .text = cell.text,
                .face_style = cell.style.face_style,
                .background = resolveOptionalRole(palette, cell.style.background),
                .underline = resolveOptionalRole(palette, cell.style.underline),
                .strikethrough = resolveOptionalRole(palette, cell.style.strikethrough),
                .overline = resolveOptionalRole(palette, cell.style.overline),
                .small = cell.style.small,
                .offset_y_px = cell.offset_y_px,
            };
            count += 1;
        }
        self.projected_len = count;
        return .{
            .cells = self.projected[0..count],
            .cols = self.cols,
            .rows = self.rows,
        };
    }

    fn indexOf(self: *const Canvas, col: u32, row: u32) ?usize {
        if (col >= self.cols or row >= self.rows) return null;
        return @as(usize, row) * @as(usize, self.cols) + @as(usize, col);
    }

    /// Break any old wide-cell relationship touching this coordinate and make
    /// it available to the later painter. A repaired head retains its fill and
    /// decorations but loses the glyph that no longer owns both cells.
    fn detach(self: *Canvas, col: u32, row: u32) void {
        const index = self.indexOf(col, row) orelse return;
        switch (self.cells[index].kind) {
            .empty => {},
            .head => {
                if (self.cells[index].span == .two and col + 1 < self.cols) {
                    const tail_index = index + 1;
                    if (self.cells[tail_index].kind == .tail) {
                        self.cells[tail_index].kind = .head;
                        self.cells[tail_index].span = .one;
                        self.cells[tail_index].text = "";
                        if (!self.cells[tail_index].hasPaint()) self.cells[tail_index] = .{};
                    }
                    self.cells[index].span = .one;
                    self.cells[index].text = "";
                    if (!self.cells[index].hasPaint()) self.cells[index] = .{};
                }
            },
            .tail => {
                if (col > 0) {
                    const head_index = index - 1;
                    if (self.cells[head_index].kind == .head and self.cells[head_index].span == .two) {
                        self.cells[head_index].span = .one;
                        self.cells[head_index].text = "";
                        if (!self.cells[head_index].hasPaint()) self.cells[head_index] = .{};
                    }
                }
                self.cells[index].kind = .head;
                self.cells[index].span = .one;
                self.cells[index].text = "";
                if (!self.cells[index].hasPaint()) self.cells[index] = .{};
            },
        }
    }

    /// Paint an opaque semantic cell such as a Surface fill. It replaces every
    /// foreground property at that position.
    fn paintFill(self: *Canvas, col: u32, row: u32, role: theme.Role) void {
        const index = self.indexOf(col, row) orelse return;
        self.detach(col, row);
        self.cells[index] = .{
            .kind = .head,
            .style = .{ .background = role },
            .offset_y_px = self.paint_offset_y_px,
        };
    }

    /// Paint one validated grapheme over the cell below it. A transparent text
    /// style preserves an earlier Surface fill.
    fn paintText(
        self: *Canvas,
        col: u32,
        row: u32,
        cluster: []const u8,
        span: render.OverlaySpan,
        style: TextStyle,
    ) void {
        const index = self.indexOf(col, row) orelse return;
        if (span == .two and (col + 1 >= self.cols or self.indexOf(col + 1, row) == null)) return;

        const kept_tail_background = if (span == .two)
            self.cells[index + 1].style.background
        else
            null;
        self.detach(col, row);
        if (span == .two) self.detach(col + 1, row);

        const kept_background = if (self.cells[index].kind == .head)
            self.cells[index].style.background
        else
            null;
        var resolved_style = style;
        if (resolved_style.background == null) resolved_style.background = kept_background;
        self.cells[index] = .{
            .kind = .head,
            .text = cluster,
            .span = span,
            .style = resolved_style,
            .offset_y_px = self.paint_offset_y_px,
        };
        if (span == .two) {
            var resolved_tail_style = style;
            if (resolved_tail_style.background == null) {
                resolved_tail_style.background = kept_tail_background;
            }
            self.cells[index + 1] = .{ .kind = .tail, .style = resolved_tail_style, .offset_y_px = self.paint_offset_y_px };
        }
    }
};

fn cellCount(cols: u32, rows: u32) ?usize {
    const count = @as(u64, cols) * @as(u64, rows);
    return std.math.cast(usize, count);
}

/// Resolve a theme role at the one boundary allowed to see both colour types.
pub fn resolveRole(palette: *const theme.Palette, role: theme.Role) render.Rgba {
    const color = palette.get(role);
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

fn resolveOptionalRole(palette: *const theme.Palette, role: ?theme.Role) ?render.Rgba {
    return if (role) |value| resolveRole(palette, value) else null;
}

/// One borrowed UTF-8 run and the style applied to all its graphemes.
pub const Run = struct {
    /// Borrowed UTF-8. Newline is the only byte with layout meaning.
    text: []const u8,
    /// Visual style for this run.
    style: TextStyle = .{},
};

/// Why a Text cannot be painted.
pub const TextError = error{InvalidUtf8};

/// Styled read-only text, composed from borrowed runs.
pub const Text = struct {
    /// Runs in painter and reading order.
    runs: []const Run,

    /// Paint this text into `bounds`.
    ///
    /// Every run is validated before the canvas changes. Newlines explicitly
    /// move to the next row; reaching the right edge clips until a newline and
    /// never wraps implicitly. A two-cell grapheme with only one cell left is
    /// omitted whole.
    pub fn draw(self: Text, canvas: *Canvas, bounds: Rect) TextError!void {
        for (self.runs) |run| {
            if (!std.unicode.utf8ValidateSlice(run.text)) return error.InvalidUtf8;
        }

        var col = bounds.x;
        var row = bounds.y;
        const right = bounds.right();
        const bottom = bounds.bottom();
        for (self.runs) |run| {
            var offset: usize = 0;
            while (offset < run.text.len) {
                if (run.text[offset] == '\n') {
                    col = bounds.x;
                    row +|= 1;
                    offset += 1;
                    continue;
                }
                // Keep a CR byte from absorbing a following LF into one
                // zero-width Unicode cluster; LF remains the explicit layout
                // command and CR itself has no cell ink.
                if (run.text[offset] == '\r') {
                    offset += 1;
                    continue;
                }

                const cluster = nextCluster(run.text, offset);
                offset = cluster.end;
                if (!cluster.drawable or cluster.width == 0) continue;
                const width: u32 = cluster.width;
                const fits_bounds = row < bottom and col < right and width <= right - col;
                if (fits_bounds) {
                    const span: render.OverlaySpan = if (width == 2) .two else .one;
                    canvas.paintText(col, row, cluster.bytes, span, run.style);
                }
                col +|= width;
            }
        }
    }
};

const Cluster = struct {
    bytes: []const u8,
    end: usize,
    width: u2,
    drawable: bool,
};

/// Find one cluster in already-valid UTF-8 with bounded stack scratch.
///
/// Controls are consumed without reaching Ghostty's control-free grapheme
/// segmenter. If one cluster exceeds the renderer's bound, the rest of that
/// line is suppressed so a suffix can never be reinterpreted as a new cluster.
fn nextCluster(text: []const u8, start: usize) Cluster {
    const view = std.unicode.Utf8View.init(text[start..]) catch {
        // Public drawing validates the complete source before it mutates the
        // canvas. Keep this private seam safe if a future caller violates that
        // invariant rather than letting untrusted text crash projection.
        return .{
            .bytes = "",
            .end = text.len,
            .width = 0,
            .drawable = false,
        };
    };
    var iterator = view.iterator();
    var codepoints: [render.max_overlay_grapheme_bytes]u21 = undefined;
    var ends: [render.max_overlay_grapheme_bytes]usize = undefined;
    var count: usize = 0;

    while (iterator.nextCodepoint()) |codepoint| {
        if (isTextControl(codepoint)) {
            if (count == 0) {
                const end = start + iterator.i;
                return .{ .bytes = "", .end = end, .width = 0, .drawable = false };
            }
            const measured = term.graphemeWidth(codepoints[0..count]);
            const end = ends[measured.len - 1];
            return .{
                .bytes = text[start..end],
                .end = end,
                .width = measured.width,
                .drawable = end - start <= render.max_overlay_grapheme_bytes,
            };
        }
        if (count == codepoints.len) {
            return suppressedLine(text, start);
        }
        codepoints[count] = codepoint;
        ends[count] = start + iterator.i;
        count += 1;

        const measured = term.graphemeWidth(codepoints[0..count]);
        if (measured.len < count) {
            const end = ends[measured.len - 1];
            const bytes = text[start..end];
            if (bytes.len > render.max_overlay_grapheme_bytes) {
                return suppressedLine(text, start);
            }
            return .{
                .bytes = bytes,
                .end = end,
                .width = measured.width,
                .drawable = true,
            };
        }
        if (ends[count - 1] - start > render.max_overlay_grapheme_bytes) {
            return suppressedLine(text, start);
        }
    }

    const measured = term.graphemeWidth(codepoints[0..count]);
    const end = if (count == 0) start else ends[count - 1];
    const bytes = text[start..end];
    return .{
        .bytes = bytes,
        .end = end,
        .width = measured.width,
        .drawable = bytes.len <= render.max_overlay_grapheme_bytes,
    };
}

fn suppressedLine(text: []const u8, start: usize) Cluster {
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return .{ .bytes = "", .end = end, .width = 0, .drawable = false };
}

fn isTextControl(codepoint: u21) bool {
    return codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0);
}

/// Which visual state an InteractiveText is being painted in.
pub const InteractiveState = enum {
    /// Neither hovered nor keyboard-focused.
    normal,
    /// Pointer hover state.
    hovered,
    /// Keyboard focus state.
    focused,
};

/// Whether InteractiveText paints its label or only cell decorations.
///
/// Decoration-only text is the semantic overlay used for terminal links: the
/// terminal renderer keeps ownership of its glyphs and ANSI styling while the
/// UI renderer can add an underline over the same cells.
pub const InteractivePaint = enum {
    label,
    decorations_only,
};

/// Clickable-looking text and its borrowed action metadata.
///
/// This primitive only selects a visual style. `Tree` owns semantic state and
/// hit testing; TASK-20 owns invocation of the inert action Tree returns.
pub const InteractiveText = struct {
    /// Stable borrowed identity.
    id: Id,
    /// Borrowed visible and accessible label.
    label: []const u8,
    /// Borrowed named action; never invoked by this value.
    action: []const u8,
    /// Whether the UI paints the label glyphs or only the selected style's
    /// background and line decorations across `bounds`.
    paint: InteractivePaint = .label,
    /// Style when idle.
    normal: TextStyle = .{},
    /// Style when hovered.
    hovered: TextStyle = .{ .underline = .accent },
    /// Style when focused.
    focused: TextStyle = .{ .background = .selection },
    /// The label's first `lead_bytes` bytes paint in `lead_foreground` over
    /// whichever style `state` selects, so a status icon keeps its own
    /// colour while the rest of the row keeps its role (TASK-85). Null, or
    /// a length that is not a whole leading part of the label, paints the
    /// label in one style.
    lead_foreground: ?theme.Role = null,
    lead_bytes: usize = 0,

    /// Paint the label in the style selected by `state`.
    pub fn draw(
        self: InteractiveText,
        canvas: *Canvas,
        bounds: Rect,
        state: InteractiveState,
    ) TextError!void {
        const style = switch (state) {
            .normal => self.normal,
            .hovered => self.hovered,
            .focused => self.focused,
        };
        switch (self.paint) {
            .label => {
                if (self.lead_foreground) |lead| {
                    if (self.lead_bytes != 0 and self.lead_bytes <= self.label.len and
                        std.unicode.utf8ValidateSlice(self.label[0..self.lead_bytes]))
                    {
                        var lead_style = style;
                        lead_style.foreground = lead;
                        const runs = [_]Run{
                            .{ .text = self.label[0..self.lead_bytes], .style = lead_style },
                            .{ .text = self.label[self.lead_bytes..], .style = style },
                        };
                        try (Text{ .runs = &runs }).draw(canvas, bounds);
                        return;
                    }
                }
                const runs = [_]Run{.{ .text = self.label, .style = style }};
                try (Text{ .runs = &runs }).draw(canvas, bounds);
            },
            .decorations_only => {
                var row = bounds.y;
                while (row < bounds.bottom()) : (row +|= 1) {
                    var col = bounds.x;
                    while (col < bounds.right()) : (col +|= 1) {
                        canvas.paintText(col, row, "", .one, style);
                    }
                }
            },
        }
    }
};

/// Conventional terminal box border styles.
pub const Border = enum {
    /// No border cells.
    none,
    /// Single-line box drawing.
    single,
    /// Double-line box drawing.
    double,
    /// Heavy-line box drawing.
    heavy,
};

const BorderGlyphs = struct {
    horizontal: []const u8,
    vertical: []const u8,
    top_left: []const u8,
    top_right: []const u8,
    bottom_left: []const u8,
    bottom_right: []const u8,
};

fn borderGlyphs(border: Border) ?BorderGlyphs {
    return switch (border) {
        .none => null,
        .single => .{
            .horizontal = "─",
            .vertical = "│",
            .top_left = "┌",
            .top_right = "┐",
            .bottom_left = "└",
            .bottom_right = "┘",
        },
        .double => .{
            .horizontal = "═",
            .vertical = "║",
            .top_left = "╔",
            .top_right = "╗",
            .bottom_left = "╚",
            .bottom_right = "╝",
        },
        .heavy => .{
            .horizontal = "━",
            .vertical = "┃",
            .top_left = "┏",
            .top_right = "┓",
            .bottom_left = "┗",
            .bottom_right = "┛",
        },
    };
}

/// A rectangular UI region, optionally filled, bordered and titled.
pub const Surface = struct {
    /// Region occupied by the surface.
    rect: Rect,
    /// Remove earlier UI paint in `rect` before drawing this surface. This
    /// remains transparent when `fill` is null, so non-UI content below the
    /// semantic layer is still visible.
    erase_underlay: bool = false,
    /// Fill role, or transparent when null.
    fill: ?theme.Role = .background,
    /// Box border style.
    border: Border = .none,
    /// Border glyph style.
    border_style: TextStyle = .{},
    /// Borrowed title shown in the top border, or no title.
    title: ?[]const u8 = null,
    /// Title glyph style.
    title_style: TextStyle = .{},

    /// Paint fill first, then border and title. Invalid title UTF-8 is rejected
    /// before any cell changes.
    pub fn draw(self: Surface, canvas: *Canvas) TextError!void {
        if (self.title) |title| {
            if (!std.unicode.utf8ValidateSlice(title)) return error.InvalidUtf8;
        }
        const clipped = Rect.intersect(self.rect, canvas.bounds());
        if (self.erase_underlay) canvas.eraseRect(clipped);
        if (self.fill) |fill| {
            var row = clipped.y;
            while (row < clipped.bottom()) : (row += 1) {
                var col = clipped.x;
                while (col < clipped.right()) : (col += 1) canvas.paintFill(col, row, fill);
            }
        }

        const glyphs = borderGlyphs(self.border) orelse return;
        if (self.rect.width < 2 or self.rect.height < 2) return;
        const left = self.rect.x;
        const right = self.rect.right() - 1;
        const top = self.rect.y;
        const bottom = self.rect.bottom() - 1;

        var col = @max(clipped.x, left +| 1);
        const horizontal_end = @min(clipped.right(), right);
        while (col < horizontal_end) : (col += 1) {
            canvas.paintText(col, top, glyphs.horizontal, .one, self.border_style);
            canvas.paintText(col, bottom, glyphs.horizontal, .one, self.border_style);
        }
        var row = @max(clipped.y, top +| 1);
        const vertical_end = @min(clipped.bottom(), bottom);
        while (row < vertical_end) : (row += 1) {
            canvas.paintText(left, row, glyphs.vertical, .one, self.border_style);
            canvas.paintText(right, row, glyphs.vertical, .one, self.border_style);
        }
        canvas.paintText(left, top, glyphs.top_left, .one, self.border_style);
        canvas.paintText(right, top, glyphs.top_right, .one, self.border_style);
        canvas.paintText(left, bottom, glyphs.bottom_left, .one, self.border_style);
        canvas.paintText(right, bottom, glyphs.bottom_right, .one, self.border_style);

        if (self.title) |title| {
            if (self.rect.width <= 4) return;
            const runs = [_]Run{.{ .text = title, .style = self.title_style }};
            try (Text{ .runs = &runs }).draw(canvas, .{
                .x = self.rect.x +| 2,
                .y = self.rect.y,
                .width = self.rect.width - 4,
                .height = 1,
            });
        }
    }
};

/// A normalized byte range selected in an Input.
pub const Selection = struct {
    /// First selected UTF-8 byte.
    start: usize,
    /// First byte after the selection.
    end: usize,

    /// Whether this selection contains no bytes.
    pub fn isEmpty(self: Selection) bool {
        return self.start == self.end;
    }
};

/// Why an Input edit or construction was refused.
pub const InputError = Allocator.Error || error{
    InvalidUtf8,
    InvalidText,
    CapacityExceeded,
    CapacityTooLarge,
};

/// Theme roles used when an Input is projected into cells.
pub const InputStyle = struct {
    /// Ordinary text and optional field background.
    text: TextStyle = .{},
    /// Background behind selected graphemes.
    selection_background: theme.Role = .selection,
    /// Background of the insertion cursor cell.
    cursor_background: theme.Role = .accent,
    /// Glyph colour when the cursor covers a grapheme.
    cursor_foreground: theme.Role = .background,
    /// Whether the insertion cursor is painted.
    cursor_visible: bool = true,
};

/// A bounded, allocator-owned single-line text input.
///
/// The storage, codepoint scratch and byte-boundary scratch are allocated by
/// `init` and released by `deinit`. Edits, movement, view tracking and drawing
/// allocate nothing. Cursor and anchor are always UTF-8 grapheme boundaries.
/// Clipboard line and paragraph separators and tabs are normalized by
/// `paste`; other controls are refused without changing the input.
pub const Input = struct {
    /// Allocator that owns every buffer below.
    allocator: Allocator,
    /// Fixed-capacity UTF-8 bytes.
    storage: []u8,
    /// Initialized byte count in `storage`.
    len: usize,
    /// Maximum initialized byte count.
    max_bytes: usize,
    /// Insertion cursor as a byte offset.
    cursor: usize,
    /// Selection anchor as a byte offset.
    anchor: usize,
    /// First visible grapheme as a byte offset.
    view_start: usize,
    /// Reused decoded-codepoint scratch.
    codepoints: []u21,
    /// Reused mapping from codepoint indexes to byte offsets.
    byte_offsets: []usize,

    /// Allocate a fixed-capacity input and copy valid single-line `initial`
    /// text into it.
    pub fn init(allocator: Allocator, max_bytes: usize, initial: []const u8) InputError!Input {
        if (max_bytes == std.math.maxInt(usize)) return error.CapacityTooLarge;
        try validateTypedText(initial);
        if (initial.len > max_bytes) return error.CapacityExceeded;

        const storage = try allocator.alloc(u8, max_bytes);
        errdefer allocator.free(storage);
        const codepoints = try allocator.alloc(u21, max_bytes);
        errdefer allocator.free(codepoints);
        const byte_offsets = try allocator.alloc(usize, max_bytes + 1);
        errdefer allocator.free(byte_offsets);
        std.mem.copyForwards(u8, storage[0..initial.len], initial);
        return .{
            .allocator = allocator,
            .storage = storage,
            .len = initial.len,
            .max_bytes = max_bytes,
            .cursor = initial.len,
            .anchor = initial.len,
            .view_start = 0,
            .codepoints = codepoints,
            .byte_offsets = byte_offsets,
        };
    }

    /// Release all buffers owned by this input.
    pub fn deinit(self: *Input) void {
        self.allocator.free(self.byte_offsets);
        self.allocator.free(self.codepoints);
        self.allocator.free(self.storage);
        self.* = undefined;
    }

    /// Current valid UTF-8 contents, borrowed until the next edit or deinit.
    pub fn text(self: *const Input) []const u8 {
        return self.storage[0..self.len];
    }

    /// Cursor byte offset.
    pub fn cursorByte(self: *const Input) usize {
        return self.cursor;
    }

    /// Anchor byte offset.
    pub fn anchorByte(self: *const Input) usize {
        return self.anchor;
    }

    /// Normalized selection range.
    pub fn selection(self: *const Input) Selection {
        return .{
            .start = @min(self.cursor, self.anchor),
            .end = @max(self.cursor, self.anchor),
        };
    }

    /// Replace the selection with ordinary typed text.
    ///
    /// The whole edit is validated and capacity-checked before any byte or
    /// cursor changes. Line breaks, tab, NUL, ESC, DEL and all C0/C1 controls
    /// are rejected rather than normalized. Accepted bytes are copied into
    /// this Input's storage before the call returns.
    pub fn insert(self: *Input, inserted: []const u8) InputError!void {
        try validateTypedText(inserted);
        const selected = self.selection();
        const removed = selected.end - selected.start;
        if (inserted.len > self.max_bytes - (self.len - removed)) {
            return error.CapacityExceeded;
        }
        const scratch = std.mem.sliceAsBytes(self.byte_offsets)[0..inserted.len];
        std.mem.copyForwards(u8, scratch, inserted);
        self.replace(selected.start, selected.end, scratch);
    }

    /// Replace the selection with clipboard text normalized to one line.
    ///
    /// Each contiguous run of CR, LF, horizontal tab, Unicode LINE SEPARATOR
    /// and Unicode PARAGRAPH SEPARATOR becomes one ASCII space, including CRLF
    /// as a single separator. Other valid non-control UTF-8 is preserved.
    /// Invalid UTF-8 and every other C0/C1 control are rejected.
    /// Validation and the normalized capacity check complete before any text,
    /// cursor, anchor or viewport state changes.
    pub fn paste(self: *Input, clipboard_text: []const u8) InputError!void {
        const normalized_len = try normalizedPasteLength(clipboard_text);
        const selected = self.selection();
        const removed = selected.end - selected.start;
        if (normalized_len > self.max_bytes - (self.len - removed)) {
            return error.CapacityExceeded;
        }

        const scratch = std.mem.sliceAsBytes(self.byte_offsets)[0..normalized_len];
        try normalizePaste(scratch, clipboard_text);
        self.replace(selected.start, selected.end, scratch);
    }

    /// Move to the previous grapheme. Without extension an existing selection
    /// collapses to its start.
    pub fn movePrevious(self: *Input, extend: bool) void {
        const selected = self.selection();
        if (!extend and !selected.isEmpty()) {
            self.setCursor(selected.start, false);
            return;
        }
        const count = self.decodeScratch();
        const cursor_index = self.codepointIndex(count, self.cursor);
        if (cursor_index == 0) {
            self.setCursor(0, extend);
            return;
        }
        var index: usize = 0;
        var previous: usize = 0;
        while (index < cursor_index) {
            previous = index;
            const measured = term.graphemeWidth(self.codepoints[index..cursor_index]);
            if (measured.len == 0) break;
            index += measured.len;
        }
        self.setCursor(self.byte_offsets[previous], extend);
    }

    /// Move to the next grapheme. Without extension an existing selection
    /// collapses to its end.
    pub fn moveNext(self: *Input, extend: bool) void {
        const selected = self.selection();
        if (!extend and !selected.isEmpty()) {
            self.setCursor(selected.end, false);
            return;
        }
        const count = self.decodeScratch();
        const cursor_index = self.codepointIndex(count, self.cursor);
        if (cursor_index >= count) {
            self.setCursor(self.len, extend);
            return;
        }
        const measured = term.graphemeWidth(self.codepoints[cursor_index..count]);
        const next = cursor_index + @max(measured.len, 1);
        self.setCursor(self.byte_offsets[@min(next, count)], extend);
    }

    /// Move to the start, optionally extending from the current anchor.
    pub fn moveHome(self: *Input, extend: bool) void {
        self.setCursor(0, extend);
    }

    /// Move to the end, optionally extending from the current anchor.
    pub fn moveEnd(self: *Input, extend: bool) void {
        self.setCursor(self.len, extend);
    }

    /// Select the whole value.
    pub fn selectAll(self: *Input) void {
        self.anchor = 0;
        self.cursor = self.len;
    }

    /// Delete the selection or the grapheme before the cursor.
    pub fn backspace(self: *Input) void {
        const selected = self.selection();
        if (!selected.isEmpty()) {
            self.replace(selected.start, selected.end, "");
            return;
        }
        if (self.cursor == 0) return;
        const old = self.cursor;
        self.movePrevious(false);
        self.replace(self.cursor, old, "");
    }

    /// Delete the selection or the grapheme after the cursor.
    pub fn delete(self: *Input) void {
        const selected = self.selection();
        if (!selected.isEmpty()) {
            self.replace(selected.start, selected.end, "");
            return;
        }
        if (self.cursor == self.len) return;
        const start = self.cursor;
        self.moveNext(false);
        const end = self.cursor;
        self.replace(start, end, "");
    }

    /// Keep the insertion cursor inside a viewport of `columns` cells.
    pub fn ensureCursorVisible(self: *Input, columns: u32) void {
        if (columns == 0) {
            self.view_start = self.cursor;
            return;
        }
        const count = self.decodeScratch();
        var start_index = self.codepointIndex(count, self.view_start);
        const cursor_index = self.codepointIndex(count, self.cursor);
        const cursor_width = self.cursorCellWidth(count, cursor_index);
        if (self.view_start > self.cursor) {
            self.view_start = self.cursor;
            start_index = cursor_index;
        }
        while (start_index < cursor_index and
            self.widthBetween(start_index, cursor_index) +| cursor_width > columns)
        {
            const measured = term.graphemeWidth(self.codepoints[start_index..cursor_index]);
            start_index += @max(measured.len, 1);
            self.view_start = self.byte_offsets[start_index];
        }
    }

    /// Paint one visible line, including selection and insertion cursor.
    pub fn draw(
        self: *Input,
        canvas: *Canvas,
        bounds: Rect,
        style: InputStyle,
    ) void {
        const clipped = Rect.intersect(bounds, canvas.bounds());
        if (clipped.isEmpty()) return;
        self.ensureCursorVisible(clipped.width);

        if (style.text.background) |background| {
            var col = clipped.x;
            while (col < clipped.right()) : (col += 1) {
                canvas.paintFill(col, clipped.y, background);
            }
        }

        const selected = self.selection();
        var offset = self.view_start;
        var col = clipped.x;
        var cursor_pending = false;
        const right = clipped.right();
        while (offset < self.len and col < right) {
            const cluster = nextCluster(self.text(), offset);
            const start = offset;
            offset = cluster.end;
            const cursor_here = self.cursor == start or cursor_pending;
            if (!cluster.drawable or cluster.width == 0) {
                if (cursor_here) cursor_pending = true;
                continue;
            }
            const width: u32 = cluster.width;
            if (width > right - col) {
                if (cursor_here and style.cursor_visible) {
                    var cursor_style = style.text;
                    cursor_style.background = style.cursor_background;
                    cursor_style.foreground = style.cursor_foreground;
                    canvas.paintText(col, clipped.y, "", .one, cursor_style);
                }
                cursor_pending = false;
                break;
            }

            var cell_style = style.text;
            if (start < selected.end and offset > selected.start) {
                cell_style.background = style.selection_background;
            }
            if (cursor_here) {
                if (style.cursor_visible) {
                    cell_style.background = style.cursor_background;
                    cell_style.foreground = style.cursor_foreground;
                }
                cursor_pending = false;
            }
            canvas.paintText(
                col,
                clipped.y,
                cluster.bytes,
                if (width == 2) .two else .one,
                cell_style,
            );
            col += width;
        }

        if (style.cursor_visible and
            (self.cursor == self.len or cursor_pending) and col < right)
        {
            var cursor_style = style.text;
            cursor_style.background = style.cursor_background;
            cursor_style.foreground = style.cursor_foreground;
            canvas.paintText(col, clipped.y, "", .one, cursor_style);
        }
    }

    fn setCursor(self: *Input, position: usize, extend: bool) void {
        self.cursor = position;
        if (!extend) self.anchor = position;
        if (self.view_start > self.cursor) self.view_start = self.cursor;
    }

    fn replace(self: *Input, start: usize, end: usize, inserted: []const u8) void {
        const tail = self.len - end;
        const new_end = start + inserted.len;
        const new_len = new_end + tail;
        if (new_end > end) {
            std.mem.copyBackwards(
                u8,
                self.storage[new_end..new_len],
                self.storage[end..self.len],
            );
        } else if (new_end < end) {
            std.mem.copyForwards(
                u8,
                self.storage[new_end..new_len],
                self.storage[end..self.len],
            );
        }
        std.mem.copyForwards(u8, self.storage[start..new_end], inserted);
        self.len = new_len;
        const count = self.decodeScratch();
        const normalized_cursor = self.boundaryAtOrAfter(count, new_end);
        const normalized_view = self.boundaryAtOrAfter(count, @min(self.view_start, self.len));
        self.cursor = normalized_cursor;
        self.anchor = normalized_cursor;
        self.view_start = @min(normalized_view, normalized_cursor);
    }

    fn decodeScratch(self: *Input) usize {
        self.byte_offsets[0] = 0;
        const view = std.unicode.Utf8View.init(self.text()) catch {
            // Construction and every edit validate atomically. Treat a future
            // internal invariant violation as an empty safe view, never as a
            // crash on bytes that originated outside the UI.
            return 0;
        };
        var iterator = view.iterator();
        var count: usize = 0;
        while (iterator.nextCodepoint()) |codepoint| {
            self.codepoints[count] = codepoint;
            count += 1;
            self.byte_offsets[count] = iterator.i;
        }
        return count;
    }

    fn codepointIndex(self: *const Input, count: usize, byte: usize) usize {
        for (self.byte_offsets[0 .. count + 1], 0..) |offset, index| {
            if (offset >= byte) return index;
        }
        return count;
    }

    fn boundaryAtOrAfter(self: *const Input, count: usize, byte: usize) usize {
        if (byte == 0 or byte >= self.len) return @min(byte, self.len);

        var index: usize = 0;
        while (index < count) {
            const start = self.byte_offsets[index];
            if (byte <= start) return start;
            const measured = term.graphemeWidth(self.codepoints[index..count]);
            const next = @min(index + @max(measured.len, 1), count);
            const end = self.byte_offsets[next];
            if (byte <= end) return end;
            index = next;
        }
        return self.len;
    }

    fn widthBetween(self: *const Input, start: usize, end: usize) u32 {
        var width: u32 = 0;
        var index = start;
        while (index < end) {
            const measured = term.graphemeWidth(self.codepoints[index..end]);
            if (measured.len == 0) break;
            width +|= measured.width;
            index += measured.len;
        }
        return width;
    }

    fn cursorCellWidth(self: *const Input, count: usize, cursor_index: usize) u32 {
        var index = cursor_index;
        while (index < count) {
            const measured = term.graphemeWidth(self.codepoints[index..count]);
            if (measured.len == 0) break;
            if (measured.width != 0) return measured.width;
            index += measured.len;
        }
        return 1;
    }
};

fn validateTypedText(text: []const u8) InputError!void {
    const view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (isTextControl(codepoint) or
            codepoint == 0x2028 or codepoint == 0x2029)
        {
            return error.InvalidText;
        }
    }
}

fn isPasteSeparator(codepoint: u21) bool {
    return codepoint == '\r' or codepoint == '\n' or codepoint == '\t' or
        codepoint == 0x2028 or codepoint == 0x2029;
}

fn normalizedPasteLength(text: []const u8) InputError!usize {
    const view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    var previous_end: usize = 0;
    var normalized_len: usize = 0;
    var in_separators = false;
    while (iterator.nextCodepoint()) |codepoint| {
        if (isPasteSeparator(codepoint)) {
            if (!in_separators) normalized_len += 1;
            in_separators = true;
        } else {
            if (isTextControl(codepoint)) return error.InvalidText;
            normalized_len += iterator.i - previous_end;
            in_separators = false;
        }
        previous_end = iterator.i;
    }
    return normalized_len;
}

fn normalizePaste(destination: []u8, text: []const u8) InputError!void {
    const view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    var previous_end: usize = 0;
    var target: usize = 0;
    var in_separators = false;
    while (iterator.nextCodepoint()) |codepoint| {
        if (isPasteSeparator(codepoint)) {
            if (!in_separators) {
                destination[target] = ' ';
                target += 1;
            }
            in_separators = true;
        } else {
            const bytes = text[previous_end..iterator.i];
            std.mem.copyForwards(u8, destination[target .. target + bytes.len], bytes);
            target += bytes.len;
            in_separators = false;
        }
        previous_end = iterator.i;
    }
}

/// Why cell geometry cannot be represented safely in device pixels.
pub const GeometryError = error{InvalidGeometry};

/// Mapping from terminal cells to clipped device-pixel bounds.
///
/// Cell `(0, 0)` begins at `surface_bounds`' origin. The surface is also the
/// clipping rectangle. Non-zero cell dimensions are required, and all
/// arithmetic is widened before clipping so hostile layout coordinates cannot
/// overflow a device coordinate.
pub const Geometry = struct {
    /// Width of one terminal cell in device pixels.
    cell_width: u32,
    /// Height of one terminal cell in device pixels.
    cell_height: u32,
    /// Drawable device-pixel surface and clipping bounds.
    surface_bounds: Bounds,
    /// Device pixels per logical pixel (the window scale). Only sub-cell
    /// element offsets (`ElementRegistration.offset_px`) are logical.
    pixel_scale: f32 = 1.0,

    /// Convert a logical-pixel offset to whole device pixels. Non-finite or
    /// non-positive scales count as 1 so hostile geometry cannot overflow.
    pub fn offsetPx(self: Geometry, logical: i32) i32 {
        const scale: f32 = if (std.math.isFinite(self.pixel_scale) and self.pixel_scale > 0) self.pixel_scale else 1.0;
        const scaled = @round(@as(f32, @floatFromInt(logical)) * scale);
        const limit: f32 = @floatFromInt(std.math.maxInt(i16));
        return @intFromFloat(std.math.clamp(scaled, -limit, limit));
    }

    /// Check that this mapping can produce `Point`-addressable bounds.
    pub fn validate(self: Geometry) GeometryError!void {
        if (self.cell_width == 0 or self.cell_height == 0) {
            return error.InvalidGeometry;
        }
        const coordinate_end = @as(i64, std.math.maxInt(i32)) + 1;
        if (self.surface_bounds.right() > coordinate_end or
            self.surface_bounds.bottom() > coordinate_end)
        {
            return error.InvalidGeometry;
        }
    }

    /// Convert one cell rectangle to its clipped device-pixel bounds.
    pub fn boundsFor(self: Geometry, rect: Rect) GeometryError!Bounds {
        return self.boundsForShifted(rect, 0);
    }

    /// `boundsFor`, moved down by `offset_y_px` device pixels before
    /// clipping. This is the one place a sub-cell shift reaches geometry, so
    /// painting, hit testing, hover, focus and the driver's bounds all agree.
    pub fn boundsForShifted(self: Geometry, rect: Rect, offset_y_px: i32) GeometryError!Bounds {
        try self.validate();
        if (rect.isEmpty() or self.surface_bounds.isEmpty()) return Bounds.empty;

        const origin_x: i128 = self.surface_bounds.x;
        const origin_y: i128 = @as(i128, self.surface_bounds.y) + offset_y_px;
        const left = origin_x + @as(i128, rect.x) * @as(i128, self.cell_width);
        const top = origin_y + @as(i128, rect.y) * @as(i128, self.cell_height);
        const right = left + @as(i128, rect.width) * @as(i128, self.cell_width);
        const bottom = top + @as(i128, rect.height) * @as(i128, self.cell_height);

        const surface_left: i128 = self.surface_bounds.x;
        const surface_top: i128 = self.surface_bounds.y;
        const surface_right: i128 = self.surface_bounds.right();
        const surface_bottom: i128 = self.surface_bounds.bottom();
        const clipped_left = @max(left, surface_left);
        const clipped_top = @max(top, surface_top);
        const clipped_right = @min(right, surface_right);
        const clipped_bottom = @min(bottom, surface_bottom);
        if (clipped_right <= clipped_left or clipped_bottom <= clipped_top) {
            return Bounds.empty;
        }

        return .{
            .x = @intCast(clipped_left),
            .y = @intCast(clipped_top),
            .width = @intCast(clipped_right - clipped_left),
            .height = @intCast(clipped_bottom - clipped_top),
        };
    }
};

/// Product and interaction state exposed through the semantic tree.
pub const ElementState = struct {
    /// The product model currently selects this element. Selection is
    /// independent of transient pointer hover, keyboard focus and presses.
    selected: bool = false,
    /// The saved pointer currently resolves to this element.
    hovered: bool = false,
    /// Keyboard focus currently resolves to this element.
    focused: bool = false,
    /// A pointer press began on this element and has not yet been released.
    pressed: bool = false,
};

/// Public, renderer-independent description of one registered UI element.
///
/// `id` and `parent` bytes obey Tree's stable-id lifetime contract. Other byte
/// slices are borrowed through the current frame. `bounds` is in clipped
/// device pixels and is the geometry used by pointer hit testing and later
/// test-driver and accessibility consumers.
pub const Element = struct {
    /// Stable semantic identity.
    id: Id,
    /// Stable parent identity, or null for a root.
    parent: ?Id,
    /// Borrowed product-defined semantic role.
    role: []const u8,
    /// Borrowed visible/accessibility label.
    label: []const u8,
    /// Current product selection and interaction flags.
    state: ElementState = .{},
    /// Clipped device-pixel geometry.
    bounds: Bounds,
    /// Borrowed named action, when activation has meaning.
    action: ?[]const u8,
    /// The one primitive retained and painted for this element.
    primitive: Primitive,
};

/// Semantic metadata and cell geometry supplied when registering a primitive.
///
/// `id` and `parent` bytes must remain valid for the Tree lifetime, or until
/// the referenced element has definitively disappeared after `endFrame`
/// reconciliation. All other bytes are borrowed through the current frame.
/// For `addInteractiveText`, these values are canonical: the retained
/// primitive's duplicate id, label and action fields are replaced with them.
pub const ElementRegistration = struct {
    /// Stable semantic id.
    id: Id,
    /// Parent already registered earlier in this frame.
    parent: ?Id = null,
    /// Product-defined role.
    role: []const u8,
    /// Visible/accessibility label.
    label: []const u8,
    /// Whether the product model currently selects this element.
    selected: bool = false,
    /// Named action returned by mouse or keyboard activation.
    action: ?[]const u8 = null,
    /// Cell bounds used for painting and pixel geometry.
    bounds: Rect,
    /// Sub-cell downward shift in logical pixels (TASK-77). It is scaled by
    /// `Geometry.pixel_scale` once, here at registration, and then applies to
    /// painting and to the element's reported device-pixel `bounds`, which
    /// hit testing, hover and the test driver read.
    offset_px: i32 = 0,
};

/// Inert result of mouse or keyboard activation.
///
/// TASK-20 resolves `action` through the action registry. `id` obeys Tree's
/// stable-id lifetime contract; `action` is borrowed from the current frame.
pub const Activation = struct {
    /// Element activated.
    id: Id,
    /// Named action to dispatch.
    action: []const u8,
};

/// Why semantic frame construction was refused.
pub const TreeError = Allocator.Error || IdError || TextError || GeometryError || error{
    DuplicateId,
    UnknownParent,
    ElementCapacityExceeded,
    RunCapacityExceeded,
    ActionRequired,
    InvalidRole,
    FrameAlreadyBegun,
    FrameNotBegun,
    FrameNotEnded,
};

const InputPaint = struct {
    input: *Input,
    style: InputStyle,
};

const Paint = union(Primitive) {
    text: Text,
    interactive_text: InteractiveText,
    surface: Surface,
    input: InputPaint,
};

const Node = struct {
    cell_bounds: Rect,
    offset_y_px: i32 = 0,
    paint: Paint,
};

const PreparedElement = struct {
    element: Element,
    cell_bounds: Rect,
    offset_y_px: i32 = 0,
};

/// Allocation-free iterator over elements with one borrowed role.
pub const RoleIterator = struct {
    tree: *const Tree,
    role: []const u8,
    index: usize = 0,

    /// Return the next element in registration order.
    pub fn next(self: *RoleIterator) ?*const Element {
        while (self.index < self.tree.element_len) {
            const index = self.index;
            self.index += 1;
            if (std.mem.eql(u8, self.tree.semantic[index].role, self.role)) {
                return &self.tree.semantic[index];
            }
        }
        return null;
    }
};

/// Fixed-capacity semantic UI tree rebuilt once per frame.
///
/// `init` owns element, paint-node and copied-Run descriptor buffers. All
/// later frame registration, interaction, rendering, queries and JSON export
/// allocate nothing. Registration order is painter order and focus order.
/// Primitive text, non-identity metadata and Input pointers are borrowed only
/// through the current frame. Registration id and parent bytes remain valid
/// for the Tree lifetime, or until the referenced element has definitively
/// disappeared after `endFrame` reconciliation.
pub const Tree = struct {
    allocator: Allocator,
    semantic: []Element,
    nodes: []Node,
    copied_runs: []Run,
    element_len: usize = 0,
    run_len: usize = 0,
    geometry: Geometry = .{
        .cell_width = 1,
        .cell_height = 1,
        .surface_bounds = Bounds.empty,
    },
    building: bool = false,
    ready: bool = false,
    pointer: ?Point = null,
    hovered_index: ?usize = null,
    focused_index: ?usize = null,
    pressed_index: ?usize = null,
    focused_id: ?[]const u8 = null,
    pressed_id: ?[]const u8 = null,

    /// Allocate fixed element and copied-run capacities.
    pub fn init(
        allocator: Allocator,
        element_capacity: usize,
        run_capacity: usize,
    ) Allocator.Error!Tree {
        const semantic = try allocator.alloc(Element, element_capacity);
        errdefer allocator.free(semantic);
        const nodes = try allocator.alloc(Node, element_capacity);
        errdefer allocator.free(nodes);
        const copied_runs = try allocator.alloc(Run, run_capacity);
        errdefer allocator.free(copied_runs);
        return .{
            .allocator = allocator,
            .semantic = semantic,
            .nodes = nodes,
            .copied_runs = copied_runs,
        };
    }

    /// Release all fixed buffers owned by this tree.
    pub fn deinit(self: *Tree) void {
        self.allocator.free(self.copied_runs);
        self.allocator.free(self.nodes);
        self.allocator.free(self.semantic);
        self.* = undefined;
    }

    /// Begin rebuilding a frame with new cell-to-pixel geometry.
    ///
    /// Focus and an in-flight press are retained by stable id and reconciled in
    /// `endFrame`. This is why registration id and parent bytes have a longer
    /// lifetime than the remaining frame-borrowed metadata.
    pub fn beginFrame(self: *Tree, geometry: Geometry) TreeError!void {
        if (self.building) return error.FrameAlreadyBegun;
        try geometry.validate();
        self.geometry = geometry;
        self.element_len = 0;
        self.run_len = 0;
        self.hovered_index = null;
        self.focused_index = null;
        self.pressed_index = null;
        self.building = true;
        self.ready = false;
    }

    /// Register styled text, copying only its Run descriptors.
    pub fn addText(
        self: *Tree,
        registration: ElementRegistration,
        text: Text,
    ) TreeError!void {
        if (!self.building) return error.FrameNotBegun;
        if (text.runs.len > self.copied_runs.len - self.run_len) {
            return error.RunCapacityExceeded;
        }
        for (text.runs) |run| {
            if (!std.unicode.utf8ValidateSlice(run.text)) return error.InvalidUtf8;
        }
        const prepared = try self.prepare(registration, .text);
        const start = self.run_len;
        const end = start + text.runs.len;
        std.mem.copyForwards(Run, self.copied_runs[start..end], text.runs);
        self.run_len = end;
        self.append(prepared, .{ .text = .{ .runs = self.copied_runs[start..end] } });
    }

    /// Register interactive text. Semantic registration metadata is
    /// canonical; the value contributes only its three visual styles.
    pub fn addInteractiveText(
        self: *Tree,
        registration: ElementRegistration,
        interactive: InteractiveText,
    ) TreeError!void {
        if (!self.building) return error.FrameNotBegun;
        const action = registration.action orelse return error.ActionRequired;
        if (action.len == 0) return error.ActionRequired;
        const prepared = try self.prepare(registration, .interactive_text);
        var retained = interactive;
        retained.id = prepared.element.id;
        retained.label = prepared.element.label;
        retained.action = action;
        self.append(prepared, .{ .interactive_text = retained });
    }

    /// Register a surface. Registration bounds are canonical for painting.
    pub fn addSurface(
        self: *Tree,
        registration: ElementRegistration,
        surface: Surface,
    ) TreeError!void {
        if (!self.building) return error.FrameNotBegun;
        if (surface.title) |title| {
            if (!std.unicode.utf8ValidateSlice(title)) return error.InvalidUtf8;
        }
        const prepared = try self.prepare(registration, .surface);
        var retained = surface;
        retained.rect = prepared.cell_bounds;
        self.append(prepared, .{ .surface = retained });
    }

    /// Register one borrowed Input and its paint style.
    pub fn addInput(
        self: *Tree,
        registration: ElementRegistration,
        input: *Input,
        style: InputStyle,
    ) TreeError!void {
        if (!self.building) return error.FrameNotBegun;
        const prepared = try self.prepare(registration, .input);
        self.append(prepared, .{ .input = .{ .input = input, .style = style } });
    }

    /// Finish a frame, preserving focus and presses by stable id and
    /// recomputing hover from the last saved pointer position.
    pub fn endFrame(self: *Tree) TreeError!void {
        if (!self.building) return error.FrameNotBegun;
        self.building = false;
        self.ready = true;

        self.focused_index = self.indexByOptionalId(self.focused_id);
        if (self.focused_index) |index| {
            if (self.semantic[index].primitive.isInteractive()) {
                self.focused_id = self.semantic[index].id.value;
            } else {
                self.focused_index = null;
                self.focused_id = null;
            }
        } else {
            self.focused_id = null;
        }

        self.pressed_index = self.indexByOptionalId(self.pressed_id);
        if (self.pressed_index) |index| {
            if (self.semantic[index].primitive.isInteractive()) {
                self.pressed_id = self.semantic[index].id.value;
            } else {
                self.pressed_index = null;
                self.pressed_id = null;
            }
        } else {
            self.pressed_id = null;
        }
        self.recomputeHover();
        self.syncStates();
    }

    /// Paint the complete semantic frame into `canvas` in registration order.
    /// The previous canvas contents are always cleared first.
    pub fn render(self: *Tree, canvas: *Canvas) TreeError!void {
        if (self.building or !self.ready) return error.FrameNotEnded;
        canvas.clear();
        defer canvas.paint_offset_y_px = 0;
        for (self.nodes[0..self.element_len], 0..) |*node, index| {
            canvas.paint_offset_y_px = node.offset_y_px;
            switch (node.paint) {
                .text => |text| try text.draw(canvas, node.cell_bounds),
                .interactive_text => |interactive| {
                    const state: InteractiveState = if (self.semantic[index].state.focused)
                        .focused
                    else if (self.semantic[index].state.hovered)
                        .hovered
                    else
                        .normal;
                    try interactive.draw(canvas, node.cell_bounds, state);
                },
                .surface => |surface| try surface.draw(canvas),
                .input => |input_paint| {
                    var style = input_paint.style;
                    style.cursor_visible = self.semantic[index].state.focused;
                    input_paint.input.draw(canvas, node.cell_bounds, style);
                },
            }
        }
    }

    /// All elements in painter and focus order. Invalidated by `beginFrame`.
    pub fn elements(self: *const Tree) []const Element {
        return self.semantic[0..self.element_len];
    }

    /// Find an element by stable id content.
    pub fn byId(self: *const Tree, id: Id) ?*const Element {
        const index = self.indexById(id.value) orelse return null;
        return &self.semantic[index];
    }

    /// Iterate elements with `role` in registration order.
    pub fn byRole(self: *const Tree, role: []const u8) RoleIterator {
        return .{ .tree = self, .role = role };
    }

    /// Return the last-painted element containing a device-pixel point.
    pub fn hitTest(self: *const Tree, point: Point) ?*const Element {
        const index = self.hitTestIndex(point) orelse return null;
        return &self.semantic[index];
    }

    /// Save pointer position and update hover on the topmost interactive hit.
    pub fn pointerMoved(self: *Tree, point: Point) void {
        self.pointer = point;
        if (!self.ready or self.building) return;
        self.recomputeHover();
        self.syncStates();
    }

    /// Begin a pointer activation and focus the hit interactive element.
    pub fn pointerPressed(self: *Tree, point: Point) void {
        self.pointerMoved(point);
        if (!self.ready or self.building) return;
        const index = self.interactiveHitIndex(point) orelse {
            self.pressed_index = null;
            self.pressed_id = null;
            self.syncStates();
            return;
        };
        self.pressed_index = index;
        self.pressed_id = self.semantic[index].id.value;
        self.setFocusIndex(index);
        self.syncStates();
    }

    /// End a pointer activation. Only releasing on the same pressed element
    /// returns an activation, and only when that element has an action.
    pub fn pointerReleased(self: *Tree, point: Point) ?Activation {
        self.pointerMoved(point);
        if (!self.ready or self.building) return null;
        const pressed = self.pressed_id;
        const released_index = self.interactiveHitIndex(point);
        self.pressed_index = null;
        self.pressed_id = null;
        self.syncStates();
        const pressed_id = pressed orelse return null;
        const index = released_index orelse return null;
        const element = &self.semantic[index];
        if (!std.mem.eql(u8, pressed_id, element.id.value)) return null;
        const action = element.action orelse return null;
        return .{ .id = element.id, .action = action };
    }

    /// Focus one interactive element by stable id.
    pub fn focus(self: *Tree, id: Id) bool {
        if (!self.ready or self.building) return false;
        const index = self.indexById(id.value) orelse return false;
        if (!self.semantic[index].primitive.isInteractive()) return false;
        self.setFocusIndex(index);
        self.syncStates();
        return true;
    }

    /// Clear keyboard focus without disturbing pointer hover or an in-flight press.
    ///
    /// Clearing the retained id also prevents a later frame rebuild from
    /// restoring focus to an element with the same stable id.
    pub fn clearFocus(self: *Tree) void {
        self.focused_index = null;
        self.focused_id = null;
        if (self.ready and !self.building) self.syncStates();
    }

    /// Move focus forward in registration order, wrapping at the end.
    pub fn focusNext(self: *Tree) ?*const Element {
        return self.moveFocus(false);
    }

    /// Move focus backward in registration order, wrapping at the start.
    pub fn focusPrevious(self: *Tree) ?*const Element {
        return self.moveFocus(true);
    }

    /// Return the focused element for the current ready frame.
    ///
    /// The returned pointer is borrowed from Tree's fixed storage and is
    /// invalidated by `beginFrame` or `deinit`. This returns null before the
    /// first completed frame, while rebuilding, or when no element is focused.
    pub fn focusedElement(self: *const Tree) ?*const Element {
        if (!self.ready or self.building) return null;
        const index = self.focused_index orelse return null;
        return &self.semantic[index];
    }

    /// Return the retained Input when it is the focused element of a ready frame.
    ///
    /// The Tree does not own the returned Input. The pointer is the one borrowed
    /// by `addInput`, and its association with this frame is invalidated by
    /// `beginFrame`; the caller remains responsible for the Input's lifetime.
    /// This returns null while rebuilding, before the first completed frame, or
    /// when focus is absent or belongs to another primitive.
    pub fn focusedInput(self: *const Tree) ?*Input {
        if (!self.ready or self.building) return null;
        const index = self.focused_index orelse return null;
        return switch (self.nodes[index].paint) {
            .input => |input_paint| input_paint.input,
            else => null,
        };
    }

    /// Return the same inert activation a successful mouse release returns.
    pub fn activateFocused(self: *const Tree) ?Activation {
        if (!self.ready or self.building) return null;
        const index = self.focused_index orelse return null;
        const element = &self.semantic[index];
        const action = element.action orelse return null;
        return .{ .id = element.id, .action = action };
    }

    /// Deterministically serialize the current semantic frame as JSON.
    ///
    /// Output goes directly to the caller's writer and allocates nothing.
    pub fn writeJson(
        self: *const Tree,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("{\"elements\":[");
        for (self.semantic[0..self.element_len], 0..) |element, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.writeAll("{\"id\":");
            try writeJsonString(writer, element.id.value);
            try writer.writeAll(",\"parent\":");
            if (element.parent) |parent| {
                try writeJsonString(writer, parent.value);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"primitive\":");
            try writeJsonString(writer, @tagName(element.primitive));
            try writer.writeAll(",\"role\":");
            try writeJsonString(writer, element.role);
            try writer.writeAll(",\"label\":");
            try writeJsonString(writer, element.label);
            try writer.print(
                ",\"selected\":{},\"hovered\":{},\"focused\":{},\"pressed\":{},\"bounds\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}},\"action\":",
                .{
                    element.state.selected,
                    element.state.hovered,
                    element.state.focused,
                    element.state.pressed,
                    element.bounds.x,
                    element.bounds.y,
                    element.bounds.width,
                    element.bounds.height,
                },
            );
            if (element.action) |action| {
                try writeJsonString(writer, action);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeByte('}');
        }
        try writer.writeAll("]}");
    }

    fn prepare(
        self: *Tree,
        registration: ElementRegistration,
        primitive: Primitive,
    ) TreeError!PreparedElement {
        if (!std.unicode.utf8ValidateSlice(registration.id.value) or
            !std.unicode.utf8ValidateSlice(registration.role) or
            !std.unicode.utf8ValidateSlice(registration.label))
        {
            return error.InvalidUtf8;
        }
        _ = try Id.parse(registration.id.value);
        if (registration.role.len == 0) return error.InvalidRole;
        if (registration.action) |action| {
            if (!std.unicode.utf8ValidateSlice(action)) return error.InvalidUtf8;
        }
        if (self.indexById(registration.id.value) != null) return error.DuplicateId;

        var parent: ?Id = null;
        if (registration.parent) |parent_id| {
            if (!std.unicode.utf8ValidateSlice(parent_id.value)) return error.InvalidUtf8;
            _ = try Id.parse(parent_id.value);
            const parent_index = self.indexById(parent_id.value) orelse {
                return error.UnknownParent;
            };
            parent = self.semantic[parent_index].id;
        }
        if (self.element_len >= self.semantic.len) return error.ElementCapacityExceeded;
        const offset_y_px = self.geometry.offsetPx(registration.offset_px);
        const pixel_bounds = try self.geometry.boundsForShifted(registration.bounds, offset_y_px);
        return .{
            .element = .{
                .id = registration.id,
                .parent = parent,
                .role = registration.role,
                .label = registration.label,
                .state = .{ .selected = registration.selected },
                .bounds = pixel_bounds,
                .action = registration.action,
                .primitive = primitive,
            },
            .cell_bounds = registration.bounds,
            .offset_y_px = offset_y_px,
        };
    }

    fn append(self: *Tree, prepared: PreparedElement, paint: Paint) void {
        self.semantic[self.element_len] = prepared.element;
        self.nodes[self.element_len] = .{
            .cell_bounds = prepared.cell_bounds,
            .offset_y_px = prepared.offset_y_px,
            .paint = paint,
        };
        self.element_len += 1;
    }

    fn indexById(self: *const Tree, id: []const u8) ?usize {
        for (self.semantic[0..self.element_len], 0..) |element, index| {
            if (std.mem.eql(u8, element.id.value, id)) return index;
        }
        return null;
    }

    fn indexByOptionalId(self: *const Tree, id: ?[]const u8) ?usize {
        return self.indexById(id orelse return null);
    }

    fn hitTestIndex(self: *const Tree, point: Point) ?usize {
        if (!self.ready or self.building) return null;
        var index = self.element_len;
        while (index > 0) {
            index -= 1;
            if (self.semantic[index].bounds.contains(point)) return index;
        }
        return null;
    }

    fn interactiveHitIndex(self: *const Tree, point: Point) ?usize {
        const index = self.hitTestIndex(point) orelse return null;
        return if (self.semantic[index].primitive.isInteractive()) index else null;
    }

    fn recomputeHover(self: *Tree) void {
        self.hovered_index = if (self.pointer) |point|
            self.interactiveHitIndex(point)
        else
            null;
    }

    fn syncStates(self: *Tree) void {
        for (self.semantic[0..self.element_len]) |*element| {
            const selected = element.state.selected;
            element.state = .{ .selected = selected };
        }
        if (self.hovered_index) |index| self.semantic[index].state.hovered = true;
        if (self.focused_index) |index| self.semantic[index].state.focused = true;
        if (self.pressed_index) |index| self.semantic[index].state.pressed = true;
    }

    fn setFocusIndex(self: *Tree, index: usize) void {
        self.focused_index = index;
        self.focused_id = self.semantic[index].id.value;
    }

    fn moveFocus(self: *Tree, backwards: bool) ?*const Element {
        if (!self.ready or self.building or self.element_len == 0) return null;
        var index = self.focused_index orelse if (backwards) self.element_len - 1 else 0;
        var step: usize = 0;
        while (step < self.element_len) : (step += 1) {
            if (self.focused_index != null or step != 0) {
                index = if (backwards)
                    if (index == 0) self.element_len - 1 else index - 1
                else if (index + 1 == self.element_len)
                    0
                else
                    index + 1;
            }
            if (!self.semantic[index].primitive.isInteractive()) continue;
            self.setFocusIndex(index);
            self.syncStates();
            return &self.semantic[index];
        }
        return null;
    }
};

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    const hex = "0123456789abcdef";
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        0x08 => try writer.writeAll("\\b"),
        0x0c => try writer.writeAll("\\f"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => {
            const escape = [_]u8{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0x0f] };
            try writer.writeAll(&escape);
        },
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn testGeometryFor(cols: u32, rows: u32) Geometry {
    return .{
        .cell_width = 10,
        .cell_height = 20,
        .surface_bounds = .{
            .x = 0,
            .y = 0,
            .width = cols * 10,
            .height = rows * 20,
        },
    };
}

fn addLocalRunText(tree: *Tree) TreeError!void {
    const local_runs = [_]Run{
        .{ .text = "local", .style = .{ .foreground = .cyan } },
        .{ .text = " run", .style = .{ .face_style = .bold } },
    };
    try tree.addText(.{
        .id = .{ .value = "copy.runs" },
        .parent = .{ .value = "root" },
        .role = "status",
        .label = "Local run text",
        .bounds = .{ .x = 1, .y = 1, .width = 7, .height = 1 },
    }, .{ .runs = &local_runs });
}

test "geometry maps cells to safely clipped device pixels" {
    const testing = std.testing;
    const geometry = Geometry{
        .cell_width = 8,
        .cell_height = 16,
        .surface_bounds = .{ .x = -4, .y = -8, .width = 28, .height = 40 },
    };

    try testing.expectEqual(
        Bounds{ .x = 4, .y = 8, .width = 16, .height = 24 },
        try geometry.boundsFor(.{ .x = 1, .y = 1, .width = 2, .height = 2 }),
    );
    try testing.expectEqual(
        Bounds{ .x = 20, .y = 24, .width = 4, .height = 8 },
        try geometry.boundsFor(.{ .x = 3, .y = 2, .width = 4, .height = 4 }),
    );
    try testing.expect((try geometry.boundsFor(.{
        .x = std.math.maxInt(u32),
        .y = std.math.maxInt(u32),
        .width = std.math.maxInt(u32),
        .height = std.math.maxInt(u32),
    })).isEmpty());
    try testing.expectError(
        error.InvalidGeometry,
        (Geometry{
            .cell_width = 0,
            .cell_height = 1,
            .surface_bounds = Bounds.empty,
        }).validate(),
    );
    try testing.expectError(
        error.InvalidGeometry,
        (Geometry{
            .cell_width = 1,
            .cell_height = 1,
            .surface_bounds = .{
                .x = std.math.maxInt(i32),
                .y = 0,
                .width = 2,
                .height = 1,
            },
        }).validate(),
    );
}

test "tree retains all four primitives and copied local Run descriptors" {
    const testing = std.testing;
    var tree = try Tree.init(testing.allocator, 4, 2);
    defer tree.deinit();
    var input = try Input.init(testing.allocator, 16, "value");
    defer input.deinit();
    var canvas = try Canvas.init(testing.allocator, 8, 4);
    defer canvas.deinit();

    try tree.beginFrame(testGeometryFor(8, 4));
    try tree.addSurface(.{
        .id = .{ .value = "root" },
        .role = "dialog",
        .label = "Root",
        .bounds = canvas.bounds(),
    }, .{
        .rect = Rect.empty,
        .fill = .background,
        .border = .single,
    });
    try addLocalRunText(&tree);
    try tree.addInteractiveText(.{
        .id = .{ .value = "open" },
        .parent = .{ .value = "root" },
        .role = "link",
        .label = "Open",
        .action = "workspace.open",
        .bounds = .{ .x = 1, .y = 2, .width = 4, .height = 1 },
    }, .{
        .id = .{ .value = "ignored" },
        .label = "ignored",
        .action = "ignored",
        .normal = .{ .foreground = .yellow },
    });
    try tree.addInput(.{
        .id = .{ .value = "name" },
        .parent = .{ .value = "root" },
        .role = "textbox",
        .label = "Name",
        .bounds = .{ .x = 1, .y = 3, .width = 6, .height = 1 },
    }, &input, .{});
    try tree.endFrame();

    try testing.expectEqual(@as(usize, 4), tree.elements().len);
    try testing.expectEqual(Primitive.surface, tree.byId(.{ .value = "root" }).?.primitive);
    const copied = tree.byId(.{ .value = "copy.runs" }).?;
    try testing.expectEqualStrings("root", copied.parent.?.value);
    try testing.expectEqual(Bounds{ .x = 10, .y = 20, .width = 70, .height = 20 }, copied.bounds);
    var statuses = tree.byRole("status");
    try testing.expectEqualStrings("copy.runs", statuses.next().?.id.value);
    try testing.expect(statuses.next() == null);

    canvas.paintFill(7, 3, .red);
    try tree.render(&canvas);
    try testing.expectEqualStrings("l", canvas.cells[9].text);
    try testing.expectEqualStrings("O", canvas.cells[17].text);
    try testing.expectEqualStrings("v", canvas.cells[25].text);
    try testing.expectEqual(theme.Role.background, canvas.cells[31].style.background.?);
}

test "tree registration failures are atomic and capacity bounded" {
    const testing = std.testing;
    const geometry = testGeometryFor(4, 2);
    const one_run = [_]Run{.{ .text = "ok" }};
    var tree = try Tree.init(testing.allocator, 1, 1);
    defer tree.deinit();

    try testing.expectError(error.FrameNotBegun, tree.addText(.{
        .id = .{ .value = "early" },
        .role = "text",
        .label = "Early",
        .bounds = Rect.empty,
    }, .{ .runs = &one_run }));
    try testing.expectError(error.InvalidGeometry, tree.beginFrame(.{
        .cell_width = 0,
        .cell_height = 1,
        .surface_bounds = Bounds.empty,
    }));
    try tree.beginFrame(geometry);
    try testing.expectError(error.FrameAlreadyBegun, tree.beginFrame(geometry));
    try testing.expectError(error.UnknownParent, tree.addText(.{
        .id = .{ .value = "child" },
        .parent = .{ .value = "missing" },
        .role = "text",
        .label = "Child",
        .bounds = Rect.empty,
    }, .{ .runs = &one_run }));
    try testing.expectError(error.InvalidId, tree.addText(.{
        .id = .{ .value = "bad id" },
        .role = "text",
        .label = "Bad",
        .bounds = Rect.empty,
    }, .{ .runs = &one_run }));
    try testing.expectError(error.InvalidUtf8, tree.addText(.{
        .id = .{ .value = "bad.role" },
        .role = "\xff",
        .label = "Bad",
        .bounds = Rect.empty,
    }, .{ .runs = &one_run }));
    try testing.expectError(error.InvalidRole, tree.addText(.{
        .id = .{ .value = "empty.role" },
        .role = "",
        .label = "Bad",
        .bounds = Rect.empty,
    }, .{ .runs = &one_run }));
    try testing.expectError(error.InvalidUtf8, tree.addText(.{
        .id = .{ .value = "bad.action" },
        .role = "text",
        .label = "Bad",
        .action = "\xff",
        .bounds = Rect.empty,
    }, .{ .runs = &one_run }));
    const visual = InteractiveText{
        .id = .{ .value = "visual" },
        .label = "Visual",
        .action = "visual.action",
    };
    try testing.expectError(error.ActionRequired, tree.addInteractiveText(.{
        .id = .{ .value = "missing.action" },
        .role = "link",
        .label = "Missing",
        .bounds = Rect.empty,
    }, visual));
    try testing.expectError(error.ActionRequired, tree.addInteractiveText(.{
        .id = .{ .value = "empty.action" },
        .role = "link",
        .label = "Empty",
        .action = "",
        .bounds = Rect.empty,
    }, visual));
    try testing.expectError(error.InvalidUtf8, tree.addInteractiveText(.{
        .id = .{ .value = "invalid.action" },
        .role = "link",
        .label = "Invalid",
        .action = "\xff",
        .bounds = Rect.empty,
    }, visual));
    const invalid_run = [_]Run{.{ .text = "\xff" }};
    try testing.expectError(error.InvalidUtf8, tree.addText(.{
        .id = .{ .value = "bad.run" },
        .role = "text",
        .label = "Bad",
        .bounds = Rect.empty,
    }, .{ .runs = &invalid_run }));
    const too_many_runs = [_]Run{ .{ .text = "a" }, .{ .text = "b" } };
    try testing.expectError(error.RunCapacityExceeded, tree.addText(.{
        .id = .{ .value = "too.many.runs" },
        .role = "text",
        .label = "Too many",
        .bounds = Rect.empty,
    }, .{ .runs = &too_many_runs }));
    try testing.expectError(error.InvalidUtf8, tree.addSurface(.{
        .id = .{ .value = "bad.title" },
        .role = "region",
        .label = "Bad",
        .bounds = Rect.empty,
    }, .{ .rect = Rect.empty, .title = "\xff" }));
    try tree.addText(.{
        .id = .{ .value = "only" },
        .role = "text",
        .label = "Only",
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    }, .{ .runs = &one_run });
    try testing.expectError(error.ElementCapacityExceeded, tree.addText(.{
        .id = .{ .value = "overflow" },
        .role = "text",
        .label = "Overflow",
        .bounds = Rect.empty,
    }, .{ .runs = &[_]Run{} }));
    try testing.expectError(error.DuplicateId, tree.addText(.{
        .id = .{ .value = "only" },
        .role = "text",
        .label = "Duplicate after full",
        .bounds = Rect.empty,
    }, .{ .runs = &[_]Run{} }));
    try tree.endFrame();
    try testing.expectEqual(@as(usize, 1), tree.elements().len);
    try testing.expectError(error.FrameNotBegun, tree.endFrame());
    try testing.expectError(error.FrameNotBegun, tree.addText(.{
        .id = .{ .value = "late" },
        .role = "text",
        .label = "Late",
        .bounds = Rect.empty,
    }, .{ .runs = &[_]Run{} }));

    var unfinished = try Tree.init(testing.allocator, 1, 0);
    defer unfinished.deinit();
    var canvas = try Canvas.init(testing.allocator, 1, 1);
    defer canvas.deinit();
    try testing.expectError(error.FrameNotEnded, unfinished.render(&canvas));
}

test "tree uses reverse paint order for hit testing and focused visuals win" {
    const testing = std.testing;
    var tree = try Tree.init(testing.allocator, 2, 0);
    defer tree.deinit();
    var canvas = try Canvas.init(testing.allocator, 4, 1);
    defer canvas.deinit();
    const palette = testPalette();

    try tree.beginFrame(testGeometryFor(4, 1));
    const first_registration = ElementRegistration{
        .id = .{ .value = "first" },
        .role = "link",
        .label = "A",
        .action = "choose.first",
        .bounds = .{ .x = 0, .y = 0, .width = 2, .height = 1 },
    };
    try tree.addInteractiveText(first_registration, .{
        .id = first_registration.id,
        .label = first_registration.label,
        .action = first_registration.action.?,
        .normal = .{ .foreground = .white },
        .hovered = .{ .foreground = .yellow, .underline = .yellow },
        .focused = .{ .foreground = .black, .background = .accent },
    });
    try tree.addInteractiveText(.{
        .id = .{ .value = "second" },
        .role = "link",
        .label = "B",
        .action = "choose.second",
        .bounds = .{ .x = 1, .y = 0, .width = 2, .height = 1 },
    }, .{
        .id = .{ .value = "second" },
        .label = "B",
        .action = "choose.second",
    });
    try tree.endFrame();

    try testing.expectEqualStrings("second", tree.hitTest(.{ .x = 15, .y = 5 }).?.id.value);
    tree.pointerMoved(.{ .x = 5, .y = 5 });
    try testing.expect(tree.byId(.{ .value = "first" }).?.state.hovered);
    try tree.render(&canvas);
    var view = canvas.view(&palette);
    try testing.expectEqual(resolveRole(&palette, .yellow), view.cells[0].foreground);
    try testing.expectEqual(resolveRole(&palette, .yellow), view.cells[0].underline.?);

    try testing.expect(tree.focus(.{ .value = "first" }));
    try tree.render(&canvas);
    view = canvas.view(&palette);
    try testing.expect(tree.byId(.{ .value = "first" }).?.state.hovered);
    try testing.expect(tree.byId(.{ .value = "first" }).?.state.focused);
    try testing.expectEqual(resolveRole(&palette, .black), view.cells[0].foreground);
    try testing.expectEqual(resolveRole(&palette, .accent), view.cells[0].background.?);
}

test "a sub-cell offset shifts bounds, hit testing and paint by the scaled amount" {
    const testing = std.testing;
    var tree = try Tree.init(testing.allocator, 3, 1);
    defer tree.deinit();
    var canvas = try Canvas.init(testing.allocator, 4, 3);
    defer canvas.deinit();
    const palette = testPalette();

    var geometry = testGeometryFor(4, 3);
    geometry.pixel_scale = 1.25;
    try testing.expectEqual(@as(i32, 6), geometry.offsetPx(5));
    try testing.expectEqual(@as(i32, 13), geometry.offsetPx(10));
    var hostile = geometry;
    hostile.pixel_scale = std.math.nan(f32);
    try testing.expectEqual(@as(i32, 5), hostile.offsetPx(5));

    try tree.beginFrame(geometry);
    try tree.addInteractiveText(.{
        .id = .{ .value = "upper" },
        .role = "tab",
        .label = "U",
        .action = "pick.upper",
        .bounds = .{ .x = 0, .y = 0, .width = 4, .height = 1 },
    }, .{ .id = .{ .value = "upper" }, .label = "U", .action = "pick.upper" });
    try tree.addInteractiveText(.{
        .id = .{ .value = "lower" },
        .role = "workspace",
        .label = "L",
        .action = "pick.lower",
        .bounds = .{ .x = 0, .y = 1, .width = 4, .height = 1 },
        .offset_px = 5,
    }, .{ .id = .{ .value = "lower" }, .label = "L", .action = "pick.lower" });
    const runs = [_]Run{.{ .text = "b", .style = .{ .foreground = .muted, .small = true } }};
    try tree.addText(.{
        .id = .{ .value = "lower.branch" },
        .parent = .{ .value = "lower" },
        .role = "branch",
        .label = "b",
        .bounds = .{ .x = 0, .y = 2, .width = 4, .height = 1 },
        .offset_px = 5,
    }, .{ .runs = &runs });
    try tree.endFrame();

    const lower = tree.byId(.{ .value = "lower" }).?;
    try testing.expectEqual(@as(i32, 26), lower.bounds.y);
    try testing.expectEqual(@as(u32, 20), lower.bounds.height);
    // The 6 px above the shifted row are the gap and hit nothing; the
    // shifted row extends 6 px further down instead.
    try testing.expectEqualStrings("upper", tree.hitTest(.{ .x = 5, .y = 19 }).?.id.value);
    try testing.expect(tree.hitTest(.{ .x = 5, .y = 20 }) == null);
    try testing.expect(tree.hitTest(.{ .x = 5, .y = 25 }) == null);
    try testing.expectEqualStrings("lower", tree.hitTest(.{ .x = 5, .y = 26 }).?.id.value);
    try testing.expectEqualStrings("lower", tree.hitTest(.{ .x = 5, .y = 45 }).?.id.value);
    try testing.expectEqualStrings("lower.branch", tree.hitTest(.{ .x = 5, .y = 46 }).?.id.value);
    tree.pointerPressed(.{ .x = 5, .y = 44 });
    const activation = tree.pointerReleased(.{ .x = 5, .y = 44 }).?;
    try testing.expectEqualStrings("pick.lower", activation.action);

    try tree.render(&canvas);
    const view = canvas.view(&palette);
    var saw_lower = false;
    var saw_small = false;
    for (view.cells) |cell| {
        if (cell.position.row == 0) try testing.expectEqual(@as(i32, 0), cell.offset_y_px);
        if (cell.position.row == 1 and std.mem.eql(u8, cell.text, "L")) {
            saw_lower = true;
            try testing.expectEqual(@as(i32, 6), cell.offset_y_px);
            try testing.expect(!cell.small);
        }
        if (cell.position.row == 2 and std.mem.eql(u8, cell.text, "b")) {
            saw_small = true;
            try testing.expect(cell.small);
            try testing.expectEqual(@as(i32, 6), cell.offset_y_px);
        }
    }
    try testing.expect(saw_lower and saw_small);
    try testing.expectEqual(@as(i32, 0), canvas.paint_offset_y_px);

    var json: std.Io.Writer.Allocating = .init(testing.allocator);
    defer json.deinit();
    try tree.writeJson(&json.writer);
    const written = json.written();
    const lower_at = std.mem.indexOf(u8, written, "\"id\":\"lower\"").?;
    const lower_end = std.mem.indexOfScalarPos(u8, written, lower_at, '}').?;
    const bounds_at = std.mem.indexOfPos(u8, written, lower_at, "\"bounds\":{\"x\":0,\"y\":26,\"width\":40,\"height\":20}").?;
    try testing.expect(bounds_at < lower_end + 64);
}

test "mouse and keyboard activation match and release must match press" {
    const testing = std.testing;
    var tree = try Tree.init(testing.allocator, 3, 0);
    defer tree.deinit();
    var input = try Input.init(testing.allocator, 8, "");
    defer input.deinit();

    try tree.beginFrame(testGeometryFor(3, 1));
    for ([_]struct { id: []const u8, action: []const u8, x: u32 }{
        .{ .id = "one", .action = "choose.one", .x = 0 },
        .{ .id = "two", .action = "choose.two", .x = 1 },
    }) |item| {
        try tree.addInteractiveText(.{
            .id = .{ .value = item.id },
            .role = "link",
            .label = item.id,
            .action = item.action,
            .bounds = .{ .x = item.x, .y = 0, .width = 1, .height = 1 },
        }, .{
            .id = .{ .value = item.id },
            .label = item.id,
            .action = item.action,
        });
    }
    try tree.addInput(.{
        .id = .{ .value = "field" },
        .role = "textbox",
        .label = "Field",
        .bounds = .{ .x = 2, .y = 0, .width = 1, .height = 1 },
    }, &input, .{});
    try tree.endFrame();

    tree.pointerPressed(.{ .x = 5, .y = 5 });
    try testing.expect(tree.byId(.{ .value = "one" }).?.state.pressed);
    const mouse = tree.pointerReleased(.{ .x = 5, .y = 5 }).?;
    try testing.expectEqualStrings("one", mouse.id.value);
    try testing.expectEqualStrings("choose.one", mouse.action);
    const keyboard = tree.activateFocused().?;
    try testing.expectEqualStrings(mouse.id.value, keyboard.id.value);
    try testing.expectEqualStrings(mouse.action, keyboard.action);

    tree.pointerPressed(.{ .x = 5, .y = 5 });
    try testing.expect(tree.pointerReleased(.{ .x = 15, .y = 5 }) == null);
    try testing.expect(tree.focus(.{ .value = "field" }));
    try testing.expect(tree.activateFocused() == null);
}

test "focus traversal reaches every interactive element and wraps both ways" {
    const testing = std.testing;
    var tree = try Tree.init(testing.allocator, 5, 0);
    defer tree.deinit();
    var input = try Input.init(testing.allocator, 8, "");
    defer input.deinit();
    var canvas = try Canvas.init(testing.allocator, 5, 1);
    defer canvas.deinit();
    const empty_runs = [_]Run{};

    try tree.beginFrame(testGeometryFor(5, 1));
    try tree.addText(.{
        .id = .{ .value = "plain" },
        .role = "text",
        .label = "Plain",
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    }, .{ .runs = &empty_runs });
    try tree.addInteractiveText(.{
        .id = .{ .value = "a" },
        .role = "link",
        .label = "A",
        .action = "a",
        .bounds = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
    }, .{ .id = .{ .value = "a" }, .label = "A", .action = "a" });
    try tree.addSurface(.{
        .id = .{ .value = "decoration" },
        .role = "presentation",
        .label = "Decoration",
        .bounds = .{ .x = 2, .y = 0, .width = 1, .height = 1 },
    }, .{ .rect = Rect.empty });
    try tree.addInput(.{
        .id = .{ .value = "input" },
        .role = "textbox",
        .label = "Input",
        .bounds = .{ .x = 3, .y = 0, .width = 1, .height = 1 },
    }, &input, .{});
    try tree.addInteractiveText(.{
        .id = .{ .value = "b" },
        .role = "link",
        .label = "B",
        .action = "b",
        .bounds = .{ .x = 4, .y = 0, .width = 1, .height = 1 },
    }, .{ .id = .{ .value = "b" }, .label = "B", .action = "b" });
    try tree.endFrame();

    try tree.render(&canvas);
    try testing.expect(canvas.cells[3].style.background == null);
    try testing.expectEqualStrings("a", tree.focusNext().?.id.value);
    try testing.expectEqualStrings("input", tree.focusNext().?.id.value);
    try tree.render(&canvas);
    try testing.expectEqual(theme.Role.accent, canvas.cells[3].style.background.?);
    try testing.expectEqualStrings("b", tree.focusNext().?.id.value);
    try tree.render(&canvas);
    try testing.expect(canvas.cells[3].style.background == null);
    try testing.expectEqualStrings("a", tree.focusNext().?.id.value);
    try testing.expectEqualStrings("b", tree.focusPrevious().?.id.value);
    try testing.expect(tree.byId(.{ .value = "b" }).?.state.focused);
    try testing.expect(!tree.focus(.{ .value = "plain" }));
}

test "clearing focus preserves pointer state and survives a frame rebuild" {
    const testing = std.testing;
    var tree = try Tree.init(testing.allocator, 2, 0);
    defer tree.deinit();
    const geometry = testGeometryFor(2, 1);

    try tree.beginFrame(geometry);
    for ([_]struct { id: []const u8, x: u32 }{
        .{ .id = "a", .x = 0 },
        .{ .id = "b", .x = 1 },
    }) |item| {
        try tree.addInteractiveText(.{
            .id = .{ .value = item.id },
            .role = "link",
            .label = item.id,
            .action = item.id,
            .bounds = .{ .x = item.x, .y = 0, .width = 1, .height = 1 },
        }, .{
            .id = .{ .value = item.id },
            .label = item.id,
            .action = item.id,
        });
    }
    try tree.endFrame();

    tree.pointerPressed(.{ .x = 15, .y = 5 });
    tree.pointerMoved(.{ .x = 5, .y = 5 });
    try testing.expectEqualStrings("b", tree.focusedElement().?.id.value);
    try testing.expect(tree.byId(.{ .value = "a" }).?.state.hovered);
    try testing.expect(tree.byId(.{ .value = "b" }).?.state.pressed);

    tree.clearFocus();
    try testing.expect(tree.focusedElement() == null);
    try testing.expect(tree.byId(.{ .value = "a" }).?.state.hovered);
    try testing.expect(tree.byId(.{ .value = "b" }).?.state.pressed);

    try tree.beginFrame(geometry);
    for ([_]struct { id: []const u8, x: u32 }{
        .{ .id = "b", .x = 1 },
        .{ .id = "a", .x = 0 },
    }) |item| {
        try tree.addInteractiveText(.{
            .id = .{ .value = item.id },
            .role = "link",
            .label = item.id,
            .action = item.id,
            .bounds = .{ .x = item.x, .y = 0, .width = 1, .height = 1 },
        }, .{
            .id = .{ .value = item.id },
            .label = item.id,
            .action = item.id,
        });
    }
    try tree.endFrame();

    try testing.expect(tree.focusedElement() == null);
    try testing.expect(tree.byId(.{ .value = "a" }).?.state.hovered);
    try testing.expect(tree.byId(.{ .value = "b" }).?.state.pressed);
}

test "focused accessors require a ready frame and follow retained focus by stable id" {
    const testing = std.testing;
    var tree = try Tree.init(testing.allocator, 2, 0);
    defer tree.deinit();
    var first_input = try Input.init(testing.allocator, 8, "first");
    defer first_input.deinit();
    var rebuilt_input = try Input.init(testing.allocator, 8, "rebuilt");
    defer rebuilt_input.deinit();
    const first_id = [_]u8{ 'f', 'i', 'e', 'l', 'd' };
    const rebuilt_id = [_]u8{ 'f', 'i', 'e', 'l', 'd' };
    const geometry = testGeometryFor(2, 1);

    try testing.expect(tree.focusedElement() == null);
    try testing.expect(tree.focusedInput() == null);
    try tree.beginFrame(geometry);
    try testing.expect(tree.focusedElement() == null);
    try testing.expect(tree.focusedInput() == null);
    try tree.addInteractiveText(.{
        .id = .{ .value = "action" },
        .role = "link",
        .label = "Action",
        .action = "action.run",
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    }, .{
        .id = .{ .value = "action" },
        .label = "Action",
        .action = "action.run",
    });
    try tree.addInput(.{
        .id = .{ .value = &first_id },
        .role = "textbox",
        .label = "Field",
        .bounds = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
    }, &first_input, .{});
    try testing.expect(tree.focusedElement() == null);
    try testing.expect(tree.focusedInput() == null);
    try tree.endFrame();

    try testing.expect(tree.focusedElement() == null);
    try testing.expect(tree.focusedInput() == null);
    try testing.expect(tree.focus(.{ .value = "action" }));
    try testing.expectEqualStrings("action", tree.focusedElement().?.id.value);
    try testing.expect(tree.focusedInput() == null);
    try testing.expect(tree.focus(.{ .value = &first_id }));
    try testing.expectEqualStrings(&first_id, tree.focusedElement().?.id.value);
    try testing.expect(tree.focusedInput().? == &first_input);

    try tree.beginFrame(geometry);
    try testing.expect(tree.focusedElement() == null);
    try testing.expect(tree.focusedInput() == null);
    try tree.addInput(.{
        .id = .{ .value = &rebuilt_id },
        .role = "textbox",
        .label = "Rebuilt field",
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    }, &rebuilt_input, .{});
    try testing.expect(tree.focusedElement() == null);
    try testing.expect(tree.focusedInput() == null);
    try tree.endFrame();
    try testing.expectEqualStrings(&rebuilt_id, tree.focusedElement().?.id.value);
    try testing.expect(tree.focusedInput().? == &rebuilt_input);

    try tree.beginFrame(geometry);
    try tree.endFrame();
    try testing.expect(tree.focusedElement() == null);
    try testing.expect(tree.focusedInput() == null);
}

test "tree preserves selected and interaction state across reordered moved frames" {
    const testing = std.testing;
    var tree = try Tree.init(testing.allocator, 2, 0);
    defer tree.deinit();
    // Both generations deliberately use distinct durable backing arrays. They
    // outlive Tree and prove reconciliation compares id content, not pointers
    // or prior registration indexes.
    const stable_a_first = [_]u8{'a'};
    const stable_b_first = [_]u8{'b'};
    const stable_a_rebuild = [_]u8{'a'};
    const stable_b_rebuild = [_]u8{'b'};

    try tree.beginFrame(testGeometryFor(4, 1));
    try tree.addInteractiveText(.{
        .id = .{ .value = &stable_a_first },
        .role = "link",
        .label = "A",
        .selected = true,
        .action = "a",
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    }, .{ .id = .{ .value = &stable_a_first }, .label = "A", .action = "a" });
    try tree.addInteractiveText(.{
        .id = .{ .value = &stable_b_first },
        .role = "link",
        .label = "B",
        .action = "b",
        .bounds = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
    }, .{ .id = .{ .value = &stable_b_first }, .label = "B", .action = "b" });
    try tree.endFrame();
    try testing.expect(tree.focus(.{ .value = &stable_b_first }));
    tree.pointerPressed(.{ .x = 15, .y = 5 });
    try testing.expect(tree.byId(.{ .value = &stable_a_first }).?.state.selected);
    try testing.expect(!tree.byId(.{ .value = &stable_a_first }).?.state.focused);
    try testing.expect(!tree.byId(.{ .value = &stable_b_first }).?.state.selected);

    try tree.beginFrame(testGeometryFor(4, 1));
    try tree.addInteractiveText(.{
        .id = .{ .value = &stable_b_rebuild },
        .role = "link",
        .label = "B moved",
        .action = "b",
        .bounds = .{ .x = 3, .y = 0, .width = 1, .height = 1 },
    }, .{ .id = .{ .value = &stable_b_rebuild }, .label = "B moved", .action = "b" });
    try tree.addInteractiveText(.{
        .id = .{ .value = &stable_a_rebuild },
        .role = "link",
        .label = "A moved",
        .selected = true,
        .action = "a",
        .bounds = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
    }, .{ .id = .{ .value = &stable_a_rebuild }, .label = "A moved", .action = "a" });
    try tree.endFrame();

    const focused = tree.byId(.{ .value = &stable_b_rebuild }).?;
    try testing.expect(focused.state.focused);
    try testing.expect(focused.state.pressed);
    try testing.expect(!focused.state.selected);
    try testing.expectEqual(Bounds{ .x = 30, .y = 0, .width = 10, .height = 20 }, focused.bounds);
    const selected = tree.byId(.{ .value = &stable_a_rebuild }).?;
    try testing.expect(selected.state.selected);
    try testing.expect(selected.state.hovered);
    try testing.expect(!selected.state.focused);
    const activation = tree.pointerReleased(.{ .x = 35, .y = 5 }).?;
    try testing.expectEqualStrings("b", activation.id.value);
    try testing.expect(tree.byId(.{ .value = &stable_a_rebuild }).?.state.selected);

    try tree.beginFrame(testGeometryFor(4, 1));
    try tree.addInteractiveText(.{
        .id = .{ .value = &stable_a_rebuild },
        .role = "link",
        .label = "Only A",
        .selected = true,
        .action = "a",
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    }, .{ .id = .{ .value = &stable_a_rebuild }, .label = "Only A", .action = "a" });
    try tree.endFrame();
    try testing.expect(tree.byId(.{ .value = &stable_a_rebuild }).?.state.selected);
    try testing.expect(tree.activateFocused() == null);
}

test "tree JSON is deterministic complete and escaped without allocation" {
    const testing = std.testing;
    var tree = try Tree.init(testing.allocator, 2, 1);
    defer tree.deinit();
    const runs = [_]Run{.{ .text = "x" }};
    const geometry = Geometry{
        .cell_width = 2,
        .cell_height = 3,
        .surface_bounds = .{ .x = -5, .y = -7, .width = 20, .height = 20 },
    };

    try tree.beginFrame(geometry);
    try tree.addText(.{
        .id = .{ .value = "root\\\"" },
        .role = "ro\nle",
        .label = "a\"b\\c\t",
        .bounds = .{ .x = 1, .y = 1, .width = 2, .height = 1 },
    }, .{ .runs = &runs });
    try tree.addInteractiveText(.{
        .id = .{ .value = "child" },
        .parent = .{ .value = "root\\\"" },
        .role = "link",
        .label = "Child",
        .selected = true,
        .action = "do\r\x01",
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    }, .{ .id = .{ .value = "child" }, .label = "Child", .action = "ignored" });
    try tree.endFrame();
    tree.pointerPressed(.{ .x = -4, .y = -6 });

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try tree.writeJson(&writer);
    try testing.expectEqualStrings(
        "{\"elements\":[{\"id\":\"root\\\\\\\"\",\"parent\":null,\"primitive\":\"text\",\"role\":\"ro\\nle\",\"label\":\"a\\\"b\\\\c\\t\",\"selected\":false,\"hovered\":false,\"focused\":false,\"pressed\":false,\"bounds\":{\"x\":-3,\"y\":-4,\"width\":4,\"height\":3},\"action\":null},{\"id\":\"child\",\"parent\":\"root\\\\\\\"\",\"primitive\":\"interactive_text\",\"role\":\"link\",\"label\":\"Child\",\"selected\":true,\"hovered\":true,\"focused\":true,\"pressed\":true,\"bounds\":{\"x\":-5,\"y\":-7,\"width\":2,\"height\":3},\"action\":\"do\\r\\u0001\"}]}",
        writer.buffered(),
    );
}

test "the interactive primitives are exactly the two that can carry an action" {
    const testing = std.testing;

    try testing.expect(Primitive.interactive_text.isInteractive());
    try testing.expect(Primitive.input.isInteractive());
    try testing.expect(!Primitive.text.isInteractive());
    try testing.expect(!Primitive.surface.isInteractive());
}

test "an id that cannot address one element is refused" {
    const testing = std.testing;

    const id = try Id.parse("tab.workspace-1");
    try testing.expectEqualStrings("tab.workspace-1", id.value);

    try testing.expectError(error.InvalidId, Id.parse(""));
    try testing.expectError(error.InvalidId, Id.parse("tab 1"));
    try testing.expectError(error.InvalidId, Id.parse("tab\t1"));
    try testing.expectError(error.InvalidId, Id.parse("tab\n1"));
    try testing.expectError(error.InvalidId, Id.parse("tab\x1b"));
    try testing.expectError(error.InvalidId, Id.parse("\xff"));
    try testing.expectError(error.InvalidId, Id.parse("tab\x7f"));
    try testing.expectError(error.InvalidId, Id.parse("tab\xc2\x80"));
    try testing.expectError(error.InvalidId, Id.parse("tab\xc2\x9f"));
    try testing.expectEqualStrings("tab\u{a0}1", (try Id.parse("tab\u{a0}1")).value);
}

test "bounds hold every pixel inside them and exclude the trailing edges" {
    const testing = std.testing;

    const bounds = Bounds{ .x = 10, .y = 20, .width = 30, .height = 40 };

    try testing.expect(!bounds.isEmpty());
    try testing.expect(bounds.contains(.{ .x = 10, .y = 20 }));
    try testing.expect(bounds.contains(.{ .x = 39, .y = 59 }));
    try testing.expect(bounds.contains(.{ .x = 10, .y = 59 }));

    try testing.expect(!bounds.contains(.{ .x = 40, .y = 20 }));
    try testing.expect(!bounds.contains(.{ .x = 10, .y = 60 }));
    try testing.expect(!bounds.contains(.{ .x = 9, .y = 20 }));

    try testing.expect(Bounds.empty.isEmpty());
    try testing.expect(!Bounds.empty.contains(.{ .x = 0, .y = 0 }));
}

test "two bounds intersect only where they overlap" {
    const testing = std.testing;

    const a = Bounds{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const b = Bounds{ .x = 5, .y = 5, .width = 10, .height = 10 };
    const overlap = Bounds{ .x = 5, .y = 5, .width = 5, .height = 5 };

    try testing.expectEqual(overlap, a.intersect(b).?);
    try testing.expectEqual(overlap, b.intersect(a).?);

    // Touching bounds share a boundary, not a pixel.
    const touching = Bounds{ .x = 10, .y = 0, .width = 10, .height = 10 };
    try testing.expectEqual(null, a.intersect(touching));
    try testing.expectEqual(null, a.intersect(Bounds{ .x = 20, .y = 20, .width = 10, .height = 10 }));
    try testing.expectEqual(null, a.intersect(Bounds.empty));

    // The enclosing bounds of overlapping or touching rectangles, and the rule
    // that an unlaid-out element contributes nothing.
    try testing.expectEqual(Bounds{ .x = 0, .y = 0, .width = 15, .height = 15 }, a.enclosing(b));
    try testing.expectEqual(a, a.enclosing(Bounds.empty));
    try testing.expectEqual(Bounds{ .x = 0, .y = 0, .width = 20, .height = 10 }, a.enclosing(touching));
}

test "cell rectangles inset centre intersect and split without overflow" {
    const testing = std.testing;

    const whole = Rect{ .x = 10, .y = 20, .width = 10, .height = 8 };
    try testing.expectEqual(
        Rect{ .x = 11, .y = 22, .width = 6, .height = 2 },
        whole.inset(.{ .top = 2, .right = 3, .bottom = 4, .left = 1 }),
    );
    try testing.expectEqual(
        Rect{ .x = 12, .y = 22, .width = 6, .height = 4 },
        whole.centred(6, 4),
    );
    try testing.expectEqual(
        Rect{ .x = 15, .y = 24, .width = 5, .height = 4 },
        Rect.intersect(whole, .{ .x = 15, .y = 24, .width = 20, .height = 20 }),
    );
    try testing.expect(Rect.intersect(whole, Rect.empty).isEmpty());
    try testing.expectEqual(
        Rect{ .x = std.math.maxInt(u32), .y = 0, .width = 0, .height = 1 },
        (Rect{ .x = std.math.maxInt(u32), .y = 0, .width = 5, .height = 1 })
            .inset(.{ .left = 5 }),
    );

    const tracks = [_]Track{ .{ .fixed = 3 }, .fill, .fill, .{ .fixed = 2 } };
    var parts: [tracks.len]Rect = undefined;
    const laid_out = try split(.{ .x = 4, .y = 7, .width = 10, .height = 2 }, .horizontal, &tracks, &parts);
    try testing.expectEqual(@as(usize, 4), laid_out.len);
    try testing.expectEqualSlices(u32, &.{ 3, 3, 2, 2 }, &.{
        parts[0].width, parts[1].width, parts[2].width, parts[3].width,
    });
    try testing.expectEqualSlices(u32, &.{ 4, 7, 10, 12 }, &.{
        parts[0].x, parts[1].x, parts[2].x, parts[3].x,
    });

    const clipped_tracks = [_]Track{ .{ .fixed = 3 }, .fill, .{ .fixed = 3 } };
    var clipped_parts: [clipped_tracks.len]Rect = undefined;
    _ = try split(.{ .x = 0, .y = 0, .width = 4, .height = 1 }, .horizontal, &clipped_tracks, &clipped_parts);
    try testing.expectEqualSlices(u32, &.{ 3, 0, 1 }, &.{
        clipped_parts[0].width, clipped_parts[1].width, clipped_parts[2].width,
    });

    const vertical_tracks = [_]Track{ .{ .fixed = 2 }, .fill };
    var vertical_parts: [vertical_tracks.len]Rect = undefined;
    _ = try split(.{ .x = 3, .y = 5, .width = 4, .height = 7 }, .vertical, &vertical_tracks, &vertical_parts);
    try testing.expectEqualSlices(u32, &.{ 2, 5 }, &.{
        vertical_parts[0].height, vertical_parts[1].height,
    });
    try testing.expectEqualSlices(u32, &.{ 5, 7 }, &.{
        vertical_parts[0].y, vertical_parts[1].y,
    });
    try testing.expectError(error.OutputTooSmall, split(whole, .vertical, &tracks, parts[0..2]));
}

test "canvas projects transparent cells in row order and repairs wide ownership" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 5, 2);
    defer canvas.deinit();
    const palette = testPalette();

    canvas.paintFill(1, 0, .blue);
    canvas.paintFill(2, 0, .green);
    canvas.paintText(1, 0, "Ａ", .two, .{ .foreground = .bright_white });
    canvas.paintText(1, 0, "界", .two, .{ .foreground = .bright_white });
    var view = canvas.view(&palette);
    try testing.expectEqual(@as(usize, 1), view.cells.len);
    try testing.expectEqual(render.OverlayPosition{ .col = 1, .row = 0 }, view.cells[0].position);
    try testing.expectEqual(render.OverlaySpan.two, view.cells[0].span);
    try testing.expectEqualStrings("界", view.cells[0].text);
    try testing.expectEqual(resolveRole(&palette, .blue), view.cells[0].background.?);

    // A later painter touching the tail removes the old wide glyph, restores
    // the head as its fill, and owns the tail with the new narrow glyph.
    canvas.paintText(2, 0, "x", .one, .{ .foreground = .red });
    view = canvas.view(&palette);
    try testing.expectEqual(@as(usize, 2), view.cells.len);
    try testing.expectEqual(render.OverlayPosition{ .col = 1, .row = 0 }, view.cells[0].position);
    try testing.expectEqualStrings("", view.cells[0].text);
    try testing.expectEqual(render.OverlaySpan.one, view.cells[0].span);
    try testing.expectEqual(render.OverlayPosition{ .col = 2, .row = 0 }, view.cells[1].position);
    try testing.expectEqualStrings("x", view.cells[1].text);
    try testing.expectEqual(resolveRole(&palette, .green), view.cells[1].background.?);

    // Empty cells remain absent, and the last row follows the first.
    canvas.paintText(0, 1, "z", .one, .{});
    view = canvas.view(&palette);
    try testing.expectEqual(@as(usize, 3), view.cells.len);
    try testing.expectEqual(render.OverlayPosition{ .col = 0, .row = 1 }, view.cells[2].position);

    // The repair cells reflect the visible wide paint, not only what was
    // underneath it. Overwriting the tail keeps the wide background there,
    // while the untouched head retains its decorations.
    canvas.clear();
    canvas.paintFill(1, 0, .blue);
    canvas.paintFill(2, 0, .green);
    canvas.paintText(1, 0, "界", .two, .{
        .foreground = .bright_white,
        .background = .red,
        .underline = .accent,
        .strikethrough = .yellow,
    });
    canvas.paintText(2, 0, "x", .one, .{ .foreground = .white });
    view = canvas.view(&palette);
    try testing.expectEqual(@as(usize, 2), view.cells.len);
    try testing.expectEqualStrings("", view.cells[0].text);
    try testing.expectEqual(resolveRole(&palette, .red), view.cells[0].background.?);
    try testing.expectEqual(resolveRole(&palette, .accent), view.cells[0].underline.?);
    try testing.expectEqual(resolveRole(&palette, .yellow), view.cells[0].strikethrough.?);
    try testing.expectEqualStrings("x", view.cells[1].text);
    try testing.expectEqual(resolveRole(&palette, .red), view.cells[1].background.?);
    try testing.expect(view.cells[1].underline == null);
    try testing.expect(view.cells[1].strikethrough == null);

    canvas.clear();
    try testing.expectEqual(@as(usize, 0), canvas.view(&palette).cells.len);
}

test "canvas resize replaces both retained buffers with an empty grid" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 1, 1);
    defer canvas.deinit();
    const palette = testPalette();

    canvas.paintFill(0, 0, .accent);
    try canvas.resize(3, 2);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 3, .height = 2 }, canvas.bounds());
    try testing.expectEqual(@as(usize, 0), canvas.view(&palette).cells.len);

    canvas.paintFill(2, 1, .accent);
    try canvas.resize(3, 2);
    try testing.expectEqual(@as(usize, 0), canvas.view(&palette).cells.len);
}

test "text validates atomically clips without wrapping and omits half-wide graphemes" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 5, 3);
    defer canvas.deinit();
    const palette = testPalette();

    const invalid_runs = [_]Run{
        .{ .text = "good" },
        .{ .text = "\xff" },
    };
    try testing.expectError(
        error.InvalidUtf8,
        (Text{ .runs = &invalid_runs }).draw(&canvas, canvas.bounds()),
    );
    try testing.expectEqual(@as(usize, 0), canvas.view(&palette).cells.len);

    const clipped_runs = [_]Run{.{ .text = "AＡB\r\nC", .style = .{ .foreground = .cyan } }};
    try (Text{ .runs = &clipped_runs }).draw(&canvas, .{ .x = 0, .y = 0, .width = 2, .height = 2 });
    var view = canvas.view(&palette);
    // A fits, the two-cell fullwidth A has only one cell left and is omitted,
    // B does not wrap, while the explicit newline makes C visible on row 1.
    try testing.expectEqual(@as(usize, 2), view.cells.len);
    try testing.expectEqualStrings("A", view.cells[0].text);
    try testing.expectEqual(render.OverlayPosition{ .col = 0, .row = 1 }, view.cells[1].position);
    try testing.expectEqualStrings("C", view.cells[1].text);

    canvas.clear();
    const combining_runs = [_]Run{.{
        .text = "é",
        .style = .{ .face_style = .bold_italic, .underline = .accent },
    }};
    try (Text{ .runs = &combining_runs }).draw(&canvas, canvas.bounds());
    view = canvas.view(&palette);
    try testing.expectEqual(@as(usize, 1), view.cells.len);
    try testing.expectEqualStrings("é", view.cells[0].text);
    try testing.expectEqual(render.OverlaySpan.one, view.cells[0].span);
    try testing.expectEqual(font.FaceStyle.bold_italic, view.cells[0].face_style);
    try testing.expectEqual(resolveRole(&palette, .accent), view.cells[0].underline.?);

    canvas.clear();
    const control_runs = [_]Run{.{ .text = "A\x00B\tC\x7fD\xc2\x80E\nF" }};
    try (Text{ .runs = &control_runs }).draw(&canvas, canvas.bounds());
    view = canvas.view(&palette);
    try testing.expectEqual(@as(usize, 6), view.cells.len);
    try testing.expectEqualStrings("A", view.cells[0].text);
    try testing.expectEqualStrings("E", view.cells[4].text);
    try testing.expectEqual(render.OverlayPosition{ .col = 0, .row = 1 }, view.cells[5].position);
    try testing.expectEqualStrings("F", view.cells[5].text);

    canvas.clear();
    var long_text: [144]u8 = undefined;
    var long_len: usize = 0;
    long_text[long_len] = 'e';
    long_len += 1;
    for (0..70) |_| {
        long_text[long_len] = 0xcc;
        long_text[long_len + 1] = 0x81;
        long_len += 2;
    }
    long_text[long_len] = 'X';
    long_len += 1;
    long_text[long_len] = '\n';
    long_len += 1;
    long_text[long_len] = 'Y';
    long_len += 1;
    const overflow_runs = [_]Run{.{ .text = long_text[0..long_len] }};
    try (Text{ .runs = &overflow_runs }).draw(&canvas, canvas.bounds());
    view = canvas.view(&palette);
    try testing.expectEqual(@as(usize, 1), view.cells.len);
    try testing.expectEqual(render.OverlayPosition{ .col = 0, .row = 1 }, view.cells[0].position);
    try testing.expectEqualStrings("Y", view.cells[0].text);
}

test "interactive text selects visuals without invoking its action" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 8, 1);
    defer canvas.deinit();
    const palette = testPalette();
    const item = InteractiveText{
        .id = try Id.parse("item.open"),
        .label = "Open",
        .action = "workspace.open",
        .normal = .{ .foreground = .white },
        .hovered = .{ .foreground = .yellow, .underline = .yellow },
        .focused = .{ .foreground = .black, .background = .accent },
    };

    try item.draw(&canvas, canvas.bounds(), .hovered);
    var view = canvas.view(&palette);
    try testing.expectEqual(@as(usize, 4), view.cells.len);
    try testing.expectEqual(resolveRole(&palette, .yellow), view.cells[0].foreground);
    try testing.expectEqual(resolveRole(&palette, .yellow), view.cells[0].underline.?);
    try testing.expectEqualStrings("workspace.open", item.action);

    canvas.clear();
    try item.draw(&canvas, canvas.bounds(), .focused);
    view = canvas.view(&palette);
    try testing.expectEqual(resolveRole(&palette, .black), view.cells[0].foreground);
    try testing.expectEqual(resolveRole(&palette, .accent), view.cells[0].background.?);

    canvas.clear();
    try item.draw(&canvas, canvas.bounds(), .normal);
    view = canvas.view(&palette);
    try testing.expectEqual(resolveRole(&palette, .white), view.cells[0].foreground);
    try testing.expect(view.cells[0].background == null);
}

test "interactive text paints a coloured lead over every state's style" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 8, 1);
    defer canvas.deinit();
    const palette = testPalette();
    const item = InteractiveText{
        .id = try Id.parse("item.agent"),
        .label = "● fake",
        .action = "agent.row",
        .normal = .{ .foreground = .foreground },
        .hovered = .{ .foreground = .strong, .underline = .accent },
        .focused = .{ .foreground = .strong, .background = .selection },
        .lead_foreground = .yellow,
        .lead_bytes = "●".len,
    };

    try item.draw(&canvas, canvas.bounds(), .normal);
    var view = canvas.view(&palette);
    try testing.expectEqual(resolveRole(&palette, .yellow), view.cells[0].foreground);
    try testing.expectEqual(resolveRole(&palette, .foreground), view.cells[2].foreground);

    canvas.clear();
    try item.draw(&canvas, canvas.bounds(), .focused);
    view = canvas.view(&palette);
    try testing.expectEqual(resolveRole(&palette, .yellow), view.cells[0].foreground);
    try testing.expectEqual(resolveRole(&palette, .selection), view.cells[0].background.?);
    try testing.expectEqual(resolveRole(&palette, .strong), view.cells[2].foreground);

    // A lead that would split a character paints the label in one style.
    var unsplit = item;
    unsplit.lead_bytes = 1;
    canvas.clear();
    try unsplit.draw(&canvas, canvas.bounds(), .normal);
    view = canvas.view(&palette);
    try testing.expectEqual(resolveRole(&palette, .foreground), view.cells[0].foreground);
}

test "decoration-only interactive text preserves underlying glyph ownership" {
    const testing = std.testing;
    var tree = try Tree.init(testing.allocator, 1, 0);
    defer tree.deinit();
    var canvas = try Canvas.init(testing.allocator, 4, 1);
    defer canvas.deinit();
    const palette = testPalette();

    try tree.beginFrame(testGeometryFor(4, 1));
    try tree.addInteractiveText(.{
        .id = try Id.parse("terminal-link:1"),
        .role = "terminal_link",
        .label = "URL",
        .action = "terminal.open-link",
        .bounds = .{ .x = 0, .y = 0, .width = 3, .height = 1 },
    }, .{
        .id = try Id.parse("ignored"),
        .label = "ignored",
        .action = "ignored",
        .paint = .decorations_only,
        .normal = .{},
        .hovered = .{ .underline = .accent },
        .focused = .{ .underline = .accent },
    });
    try tree.endFrame();

    tree.pointerMoved(.{ .x = 5, .y = 5 });
    try tree.render(&canvas);
    const view = canvas.view(&palette);
    try testing.expectEqual(@as(usize, 3), view.cells.len);
    for (view.cells) |cell| {
        try testing.expectEqualStrings("", cell.text);
        try testing.expect(cell.background == null);
        try testing.expectEqual(resolveRole(&palette, .accent), cell.underline.?);
    }
    try testing.expectEqualStrings("URL", tree.hitTest(.{ .x = 5, .y = 5 }).?.label);
    try testing.expect(tree.focus(try Id.parse("terminal-link:1")));
    const activation = tree.activateFocused().?;
    try testing.expectEqualStrings("terminal.open-link", activation.action);
}

test "surfaces paint conventional borders fill and a clipped title" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 8, 4);
    defer canvas.deinit();
    const palette = testPalette();

    try testing.expectError(
        error.InvalidUtf8,
        (Surface{ .rect = canvas.bounds(), .title = "\xff" }).draw(&canvas),
    );
    try testing.expectEqual(@as(usize, 0), canvas.view(&palette).cells.len);

    try (Surface{
        .rect = canvas.bounds(),
        .fill = .background,
        .border = .double,
        .border_style = .{ .foreground = .accent },
        .title = "TITLE-LONG",
        .title_style = .{ .foreground = .bright_white },
    }).draw(&canvas);
    const view = canvas.view(&palette);
    try testing.expectEqual(@as(usize, 32), view.cells.len);
    try testing.expectEqualStrings("╔", view.cells[0].text);
    try testing.expectEqualStrings("T", view.cells[2].text);
    try testing.expectEqualStrings("L", view.cells[5].text);
    try testing.expectEqualStrings("╗", view.cells[7].text);
    try testing.expectEqualStrings("╚", view.cells[24].text);
    try testing.expectEqualStrings("╝", view.cells[31].text);
    for (view.cells) |cell| try testing.expect(cell.background != null);
}

test "transparent surface can erase earlier UI while preserving its border" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 6, 3);
    defer canvas.deinit();
    const palette = testPalette();

    try (Text{ .runs = &.{.{ .text = "under", .style = .{ .foreground = .white } }} }).draw(
        &canvas,
        canvas.bounds(),
    );
    try (Surface{
        .rect = .{ .x = 1, .y = 0, .width = 4, .height = 3 },
        .erase_underlay = true,
        .fill = null,
        .border = .single,
        .border_style = .{ .foreground = .accent },
    }).draw(&canvas);

    const view = canvas.view(&palette);
    try testing.expectEqual(@as(usize, 11), view.cells.len);
    try testing.expectEqual(@as(u32, 0), view.cells[0].position.col);
    try testing.expectEqualStrings("u", view.cells[0].text);
    try testing.expectEqualStrings("┌", view.cells[1].text);
    try testing.expectEqualStrings("┘", view.cells[10].text);
    for (view.cells[1..]) |cell| try testing.expect(cell.background == null);
}

test "every surface border uses its conventional box-drawing family" {
    const testing = std.testing;

    const single = borderGlyphs(.single).?;
    try testing.expectEqualStrings("─", single.horizontal);
    try testing.expectEqualStrings("│", single.vertical);
    try testing.expectEqualStrings("┌", single.top_left);
    try testing.expectEqualStrings("┘", single.bottom_right);

    const double = borderGlyphs(.double).?;
    try testing.expectEqualStrings("═", double.horizontal);
    try testing.expectEqualStrings("║", double.vertical);
    try testing.expectEqualStrings("╔", double.top_left);
    try testing.expectEqualStrings("╝", double.bottom_right);

    const heavy = borderGlyphs(.heavy).?;
    try testing.expectEqualStrings("━", heavy.horizontal);
    try testing.expectEqualStrings("┃", heavy.vertical);
    try testing.expectEqualStrings("┏", heavy.top_left);
    try testing.expectEqualStrings("┛", heavy.bottom_right);
    try testing.expect(borderGlyphs(.none) == null);
}

test "input edits whole graphemes and replaces selections without allocation" {
    const testing = std.testing;
    var input = try Input.init(testing.allocator, 32, "aéb");
    defer input.deinit();

    input.movePrevious(false);
    try testing.expectEqual(@as(usize, "aé".len), input.cursorByte());
    input.movePrevious(false);
    try testing.expectEqual(@as(usize, 1), input.cursorByte());
    input.moveNext(true);
    try testing.expectEqual(Selection{ .start = 1, .end = "aé".len }, input.selection());
    try input.insert("Z");
    try testing.expectEqualStrings("aZb", input.text());

    input.backspace();
    try testing.expectEqualStrings("ab", input.text());
    input.moveHome(false);
    input.delete();
    try testing.expectEqualStrings("b", input.text());
    input.moveEnd(false);
    try input.insert("cd");
    input.selectAll();
    try input.insert("done");
    try testing.expectEqualStrings("done", input.text());
    try testing.expect(input.selection().isEmpty());

    input.movePrevious(true);
    try testing.expectEqual(Selection{ .start = 3, .end = 4 }, input.selection());
    input.moveHome(true);
    try testing.expectEqual(Selection{ .start = 0, .end = 4 }, input.selection());
    input.moveHome(false);
    input.moveEnd(true);
    try testing.expectEqual(Selection{ .start = 0, .end = 4 }, input.selection());

    var flag = try Input.init(testing.allocator, 16, "🇸");
    defer flag.deinit();
    flag.moveHome(false);
    try flag.insert("🇺");
    try testing.expectEqualStrings("🇺🇸", flag.text());
    try testing.expectEqual(flag.text().len, flag.cursorByte());
    flag.movePrevious(false);
    try testing.expectEqual(@as(usize, 0), flag.cursorByte());

    var alias = try Input.init(testing.allocator, 16, "abcd");
    defer alias.deinit();
    const suffix = alias.text()[2..];
    alias.moveHome(false);
    try alias.insert(suffix);
    try testing.expectEqualStrings("cdabcd", alias.text());
}

test "input pastes plain text at the cursor" {
    const testing = std.testing;
    var input = try Input.init(testing.allocator, 16, "ac");
    defer input.deinit();

    input.movePrevious(false);
    try input.paste("b");

    try testing.expectEqualStrings("abc", input.text());
    try testing.expectEqual(@as(usize, 2), input.cursorByte());
    try testing.expectEqual(input.cursorByte(), input.anchorByte());
}

test "input paste collapses mixed line and tab separator runs" {
    const testing = std.testing;
    var input = try Input.init(testing.allocator, 64, "");
    defer input.deinit();

    try input.paste("\r\n\t\r\u{2028}\u{2029}alpha\rbravo\u{2028}\n\tcharlie\t\r\n");

    try testing.expectEqualStrings(" alpha bravo charlie ", input.text());
    try testing.expectEqual(input.text().len, input.cursorByte());
    try testing.expectEqual(input.cursorByte(), input.anchorByte());
}

test "input paste replaces selection and leaves cursor after normalized text" {
    const testing = std.testing;
    var input = try Input.init(testing.allocator, 64, "prefix OLD suffix");
    defer input.deinit();

    input.moveHome(false);
    for (0.."prefix ".len) |_| input.moveNext(false);
    for (0.."OLD".len) |_| input.moveNext(true);
    try testing.expectEqual(
        Selection{ .start = "prefix ".len, .end = "prefix OLD".len },
        input.selection(),
    );

    try input.paste("new\r\n\tvalue");

    try testing.expectEqualStrings("prefix new value suffix", input.text());
    try testing.expectEqual(@as(usize, "prefix new value".len), input.cursorByte());
    try testing.expectEqual(input.cursorByte(), input.anchorByte());
}

test "input paste preserves Unicode and places movement on grapheme boundaries" {
    const testing = std.testing;
    const pasted = "e\u{301}\t界🇺🇸";
    const normalized = "e\u{301} 界🇺🇸";
    var input = try Input.init(testing.allocator, 64, "!");
    defer input.deinit();

    input.moveHome(false);
    try input.paste(pasted);

    try testing.expectEqualStrings(normalized ++ "!", input.text());
    try testing.expectEqual(@as(usize, normalized.len), input.cursorByte());
    input.movePrevious(false);
    try testing.expectEqual(@as(usize, normalized.len - "🇺🇸".len), input.cursorByte());
    input.movePrevious(false);
    try testing.expectEqual(
        @as(usize, normalized.len - "🇺🇸".len - "界".len),
        input.cursorByte(),
    );
}

test "input paste rejects malformed and control text atomically" {
    const testing = std.testing;
    var input = try Input.init(testing.allocator, 16, "abcdef");
    defer input.deinit();
    input.movePrevious(true);
    input.ensureCursorVisible(2);
    const before_text = try testing.allocator.dupe(u8, input.text());
    defer testing.allocator.free(before_text);
    const before_cursor = input.cursorByte();
    const before_anchor = input.anchorByte();
    const before_view = input.view_start;

    const refused = [_]struct { text: []const u8, expected: anyerror }{
        .{ .text = "\xff", .expected = error.InvalidUtf8 },
        .{ .text = "ok\x00no", .expected = error.InvalidText },
        .{ .text = "\x01", .expected = error.InvalidText },
        .{ .text = "\x08", .expected = error.InvalidText },
        .{ .text = "\x0b", .expected = error.InvalidText },
        .{ .text = "\x0c", .expected = error.InvalidText },
        .{ .text = "\x1b", .expected = error.InvalidText },
        .{ .text = "\x1f", .expected = error.InvalidText },
        .{ .text = "\x7f", .expected = error.InvalidText },
        .{ .text = "\xc2\x80", .expected = error.InvalidText },
        .{ .text = "\xc2\x9f", .expected = error.InvalidText },
    };
    for (refused) |case| {
        try testing.expectError(case.expected, input.paste(case.text));
        try testing.expectEqualStrings(before_text, input.text());
        try testing.expectEqual(before_cursor, input.cursorByte());
        try testing.expectEqual(before_anchor, input.anchorByte());
        try testing.expectEqual(before_view, input.view_start);
    }
}

test "input paste capacity check is atomic after normalization" {
    const testing = std.testing;
    var input = try Input.init(testing.allocator, 6, "abcd");
    defer input.deinit();
    input.movePrevious(true);
    input.ensureCursorVisible(2);
    const before_cursor = input.cursorByte();
    const before_anchor = input.anchorByte();
    const before_view = input.view_start;

    try testing.expectError(error.CapacityExceeded, input.paste("xy\r\nz"));
    try testing.expectEqualStrings("abcd", input.text());
    try testing.expectEqual(before_cursor, input.cursorByte());
    try testing.expectEqual(before_anchor, input.anchorByte());
    try testing.expectEqual(before_view, input.view_start);

    var collapsed = try Input.init(testing.allocator, 3, "");
    defer collapsed.deinit();
    try collapsed.paste("\r\n\t\r\nA");
    try testing.expectEqualStrings(" A", collapsed.text());
}

test "input rejects invalid typed text atomically" {
    const testing = std.testing;
    var input = try Input.init(testing.allocator, 6, "abc");
    defer input.deinit();
    input.movePrevious(true);
    const before_text = try testing.allocator.dupe(u8, input.text());
    defer testing.allocator.free(before_text);
    const before_cursor = input.cursorByte();
    const before_anchor = input.anchorByte();

    const refused = [_]struct { text: []const u8, expected: anyerror }{
        .{ .text = "\xff", .expected = error.InvalidUtf8 },
        .{ .text = "\n", .expected = error.InvalidText },
        .{ .text = "\r", .expected = error.InvalidText },
        .{ .text = "\t", .expected = error.InvalidText },
        .{ .text = "\x00", .expected = error.InvalidText },
        .{ .text = "\x1b", .expected = error.InvalidText },
        .{ .text = "\x7f", .expected = error.InvalidText },
        .{ .text = "\xc2\x80", .expected = error.InvalidText },
        .{ .text = "\u{2028}", .expected = error.InvalidText },
        .{ .text = "\u{2029}", .expected = error.InvalidText },
    };
    for (refused) |case| {
        try testing.expectError(case.expected, input.insert(case.text));
        try testing.expectEqualStrings(before_text, input.text());
        try testing.expectEqual(before_cursor, input.cursorByte());
        try testing.expectEqual(before_anchor, input.anchorByte());
    }
    try testing.expectError(error.CapacityExceeded, input.insert("1234567"));
    try testing.expectEqualStrings(before_text, input.text());
    try testing.expectEqual(before_cursor, input.cursorByte());
    try testing.expectEqual(before_anchor, input.anchorByte());

    try testing.expectError(error.InvalidUtf8, Input.init(testing.allocator, 4, "\xff"));
    try testing.expectError(error.InvalidText, Input.init(testing.allocator, 4, "\n"));
}

test "input keeps cursor visible and paints selection and cursor roles" {
    const testing = std.testing;
    var input = try Input.init(testing.allocator, 16, "abcdef");
    defer input.deinit();
    input.ensureCursorVisible(3);
    try testing.expectEqual(@as(usize, 4), input.view_start);

    var canvas = try Canvas.init(testing.allocator, 3, 1);
    defer canvas.deinit();
    const palette = testPalette();
    input.draw(&canvas, canvas.bounds(), .{});
    var view = canvas.view(&palette);
    try testing.expectEqual(@as(usize, 3), view.cells.len);
    try testing.expectEqualStrings("e", view.cells[0].text);
    try testing.expectEqualStrings("f", view.cells[1].text);
    try testing.expectEqualStrings("", view.cells[2].text);
    try testing.expectEqual(resolveRole(&palette, .accent), view.cells[2].background.?);

    canvas.clear();
    input.draw(&canvas, canvas.bounds(), .{ .cursor_visible = false });
    view = canvas.view(&palette);
    try testing.expectEqual(@as(usize, 2), view.cells.len);
    try testing.expectEqualStrings("e", view.cells[0].text);
    try testing.expectEqualStrings("f", view.cells[1].text);

    canvas.clear();
    input.moveHome(false);
    input.moveNext(true);
    input.draw(&canvas, canvas.bounds(), .{});
    view = canvas.view(&palette);
    try testing.expectEqual(resolveRole(&palette, .selection), view.cells[0].background.?);
    try testing.expectEqual(resolveRole(&palette, .accent), view.cells[1].background.?);

    var wide = try Input.init(testing.allocator, 16, "aＡ");
    defer wide.deinit();
    wide.moveHome(false);
    wide.moveNext(false);

    canvas.clear();
    wide.draw(&canvas, .{ .x = 0, .y = 0, .width = 2, .height = 1 }, .{});
    view = canvas.view(&palette);
    try testing.expectEqual(@as(usize, 1), view.cells.len);
    try testing.expectEqualStrings("Ａ", view.cells[0].text);
    try testing.expectEqual(render.OverlaySpan.two, view.cells[0].span);
    try testing.expectEqual(resolveRole(&palette, .accent), view.cells[0].background.?);

    canvas.clear();
    wide.draw(&canvas, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{});
    view = canvas.view(&palette);
    try testing.expectEqual(@as(usize, 1), view.cells.len);
    try testing.expectEqualStrings("", view.cells[0].text);
    try testing.expectEqual(render.OverlaySpan.one, view.cells[0].span);
    try testing.expectEqual(resolveRole(&palette, .accent), view.cells[0].background.?);

    var zero_width = try Input.init(testing.allocator, 16, "́a");
    defer zero_width.deinit();
    zero_width.moveHome(false);
    canvas.clear();
    zero_width.draw(&canvas, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{});
    view = canvas.view(&palette);
    try testing.expectEqual(@as(usize, 1), view.cells.len);
    try testing.expectEqualStrings("a", view.cells[0].text);
    try testing.expectEqual(resolveRole(&palette, .accent), view.cells[0].background.?);
}

fn testPalette() theme.Palette {
    var palette: theme.Palette = undefined;
    for (&palette.colors, 0..) |*color, index| {
        color.* = .{
            .r = @intCast(index * 7),
            .g = @intCast(index * 9),
            .b = @truncate(index * 11),
        };
    }
    return palette;
}
