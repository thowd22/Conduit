//! Built-in sprite glyphs: box drawing, block elements, braille and the Powerline separators,
//! drawn procedurally at the current cell size.
//!
//! **Owns** turning one of those codepoints and a cell size into a coverage mask exactly one cell
//! wide and one cell tall. **Never** opens a font, touches the atlas or knows what a terminal is:
//! `font.Manager` decides when a codepoint is drawn from here and caches the result like any other
//! glyph. **May depend on** `std` only.
//!
//! Why procedural: a font's box-drawing and Powerline glyphs are designed against that font's own
//! em square, so at a terminal's cell size they routinely stop a pixel short of the cell edge or
//! overhang it, and a column of `│` or a Powerline prompt shows seams. A mask drawn to the cell's
//! exact pixel size meets every edge, so neighbouring cells tile without gaps whatever the primary
//! font is, and the user needs no patched Nerd Font for the separators. Ghostty's
//! `src/font/sprite` is the reference design; this is Conduit's own, smaller implementation.
//!
//! Lines are placed on whole pixels (a light stroke is `lineThickness` pixels, heavy is twice
//! that, a double line is two light strokes one stroke apart) and every position is derived only
//! from the cell size, so the same stroke lands on the same pixel column in every cell. Diagonals,
//! arcs and Powerline shapes are sampled 4x4 per pixel, which anti-aliases their slopes while
//! still filling to the exact cell edge.
//!
//! Not drawn here, and resolved through the font fallback chain instead: the Powerline flame,
//! pixelated, ice and Lego shapes (U+E0C0..U+E0D1, U+E0D6..U+E0D7) and every other Nerd Font
//! private-use icon, which Conduit's bundled Symbols Nerd Font Mono face covers.

const std = @import("std");

/// Whether `codepoint` is drawn by this module rather than from a font.
pub fn covers(codepoint: u21) bool {
    return switch (codepoint) {
        0x2500...0x259F => true,
        0x2800...0x28FF => true,
        0xE0B0...0xE0BF, 0xE0D2, 0xE0D4 => true,
        else => false,
    };
}

/// The stroke width of a light line at a cell height: one pixel up to 23px cells, and growing with
/// the cell so a HiDPI rendering is the same weight as a 1x one rather than a hairline.
pub fn lineThickness(height_px: u32) u32 {
    return @max(1, (height_px + 8) / 16);
}

/// Draw `codepoint` into `out`, a `width_px * height_px` row-major coverage mask that is cleared
/// first. Returns false, leaving `out` cleared, for a codepoint `covers` rejects or a mask too
/// small to hold the cell.
pub fn render(codepoint: u21, width_px: u32, height_px: u32, out: []u8) bool {
    const len = @as(usize, width_px) * height_px;
    if (width_px == 0 or height_px == 0 or out.len < len) return false;
    var canvas: Canvas = .{ .width = width_px, .height = height_px, .pixels = out[0..len] };
    @memset(canvas.pixels, 0);
    switch (codepoint) {
        0x2500...0x257F => box(&canvas, codepoint),
        0x2580...0x259F => block(&canvas, codepoint),
        0x2800...0x28FF => braille(&canvas, codepoint),
        0xE0B0...0xE0BF, 0xE0D2, 0xE0D4 => powerline(&canvas, codepoint),
        else => return false,
    }
    return true;
}

const Canvas = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    fn w(self: Canvas) f32 {
        return @floatFromInt(self.width);
    }

    fn h(self: Canvas) f32 {
        return @floatFromInt(self.height);
    }

    /// Fill whole pixels `[x0, x1) x [y0, y1)`, clipped to the cell, at `alpha` coverage.
    fn rect(self: *Canvas, x0: i64, y0: i64, x1: i64, y1: i64, alpha: u8) void {
        const left: u32 = @intCast(std.math.clamp(x0, 0, @as(i64, self.width)));
        const right: u32 = @intCast(std.math.clamp(x1, 0, @as(i64, self.width)));
        const top: u32 = @intCast(std.math.clamp(y0, 0, @as(i64, self.height)));
        const bottom: u32 = @intCast(std.math.clamp(y1, 0, @as(i64, self.height)));
        var y = top;
        while (y < bottom) : (y += 1) {
            const row = self.pixels[@as(usize, y) * self.width ..][0..self.width];
            var x = left;
            while (x < right) : (x += 1) row[x] = @max(row[x], alpha);
        }
    }

    /// Fill every pixel by the fraction of its 4x4 sample grid that `inside` accepts. Coverage only
    /// ever grows, so shapes drawn one after another union rather than overwrite.
    fn sample(self: *Canvas, context: anytype, comptime inside: fn (@TypeOf(context), f32, f32) bool) void {
        const grid = 4;
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                var hits: u32 = 0;
                for (0..grid) |sy| for (0..grid) |sx| {
                    const px = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / grid;
                    const py = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / grid;
                    if (inside(context, px, py)) hits += 1;
                };
                if (hits == 0) continue;
                const value: u8 = @intCast(@min(255, (hits * 255 + (grid * grid) / 2) / (grid * grid)));
                const index = @as(usize, y) * self.width + x;
                self.pixels[index] = @max(self.pixels[index], value);
            }
        }
    }

    /// Fill a convex polygon given in pixel coordinates, either winding.
    fn convex(self: *Canvas, points: []const [2]f32) void {
        self.sample(points, insideConvex);
    }

    /// Stroke the segment `a`-`b` with a square-ended line `thickness` pixels wide.
    fn line(self: *Canvas, a: [2]f32, b: [2]f32, thickness: f32) void {
        self.sample(Segment{ .a = a, .b = b, .half = thickness / 2 }, insideSegment);
    }
};

fn insideConvex(points: []const [2]f32, x: f32, y: f32) bool {
    var sign: f32 = 0;
    for (points, 0..) |p, i| {
        const q = points[(i + 1) % points.len];
        const cross = (q[0] - p[0]) * (y - p[1]) - (q[1] - p[1]) * (x - p[0]);
        if (cross == 0) continue;
        if (sign == 0) {
            sign = cross;
        } else if ((cross > 0) != (sign > 0)) {
            return false;
        }
    }
    return true;
}

const Segment = struct { a: [2]f32, b: [2]f32, half: f32 };

fn insideSegment(segment: Segment, x: f32, y: f32) bool {
    const dx = segment.b[0] - segment.a[0];
    const dy = segment.b[1] - segment.a[1];
    const len_sq = dx * dx + dy * dy;
    if (len_sq == 0) return false;
    // Unclamped projection: the line is extended past its endpoints by half a stroke so a diagonal
    // drawn corner to corner still reaches the corner pixel with full weight.
    const t = ((x - segment.a[0]) * dx + (y - segment.a[1]) * dy) / len_sq;
    const len = @sqrt(len_sq);
    const overhang = segment.half / len;
    if (t < -overhang or t > 1 + overhang) return false;
    const distance = @abs((x - segment.a[0]) * dy - (y - segment.a[1]) * dx) / len;
    return distance <= segment.half;
}

const Ellipse = struct {
    cx: f32,
    cy: f32,
    rx: f32,
    ry: f32,
    /// Zero for a filled ellipse; otherwise the stroke width of an outline.
    stroke: f32 = 0,
};

fn insideEllipse(e: Ellipse, x: f32, y: f32) bool {
    const nx = (x - e.cx) / e.rx;
    const ny = (y - e.cy) / e.ry;
    const outer = nx * nx + ny * ny <= 1;
    if (e.stroke == 0) return outer;
    const irx = e.rx - e.stroke;
    const iry = e.ry - e.stroke;
    if (irx <= 0 or iry <= 0) return outer;
    const ix = (x - e.cx) / irx;
    const iy = (y - e.cy) / iry;
    return outer and ix * ix + iy * iy > 1;
}

// ---------------------------------------------------------------------------
// Box drawing, U+2500..U+257F
// ---------------------------------------------------------------------------

const Weight = enum(u2) { none, light, heavy, double };

/// The four arms of a box-drawing character, in the order of the Unicode names' clockwise
/// convention: up, right, down, left.
const Arms = struct {
    up: Weight = .none,
    right: Weight = .none,
    down: Weight = .none,
    left: Weight = .none,
};

fn arms(up: Weight, right: Weight, down: Weight, left: Weight) Arms {
    return .{ .up = up, .right = right, .down = down, .left = left };
}

const n: Weight = .none;
const l: Weight = .light;
const H: Weight = .heavy;
const d: Weight = .double;

/// The arms of every line-only character, indexed from U+2500. Dashes, arcs and diagonals are
/// drawn separately and hold `none` here.
const box_table = [_]Arms{
    // 2500
    arms(n, l, n, l), arms(n, H, n, H), arms(l, n, l, n), arms(H, n, H, n),
    arms(n, n, n, n), arms(n, n, n, n), arms(n, n, n, n), arms(n, n, n, n),
    arms(n, n, n, n), arms(n, n, n, n), arms(n, n, n, n), arms(n, n, n, n),
    arms(n, l, l, n), arms(n, H, l, n), arms(n, l, H, n), arms(n, H, H, n),
    // 2510
    arms(n, n, l, l), arms(n, n, l, H), arms(n, n, H, l), arms(n, n, H, H),
    arms(l, l, n, n), arms(l, H, n, n), arms(H, l, n, n), arms(H, H, n, n),
    arms(l, n, n, l), arms(l, n, n, H), arms(H, n, n, l), arms(H, n, n, H),
    arms(l, l, l, n), arms(l, H, l, n), arms(H, l, l, n), arms(l, l, H, n),
    // 2520
    arms(H, l, H, n), arms(H, H, l, n), arms(l, H, H, n), arms(H, H, H, n),
    arms(l, n, l, l), arms(l, n, l, H), arms(H, n, l, l), arms(l, n, H, l),
    arms(H, n, H, l), arms(H, n, l, H), arms(l, n, H, H), arms(H, n, H, H),
    arms(n, l, l, l), arms(n, l, l, H), arms(n, H, l, l), arms(n, H, l, H),
    // 2530
    arms(n, l, H, l), arms(n, l, H, H), arms(n, H, H, l), arms(n, H, H, H),
    arms(l, l, n, l), arms(l, l, n, H), arms(l, H, n, l), arms(l, H, n, H),
    arms(H, l, n, l), arms(H, l, n, H), arms(H, H, n, l), arms(H, H, n, H),
    arms(l, l, l, l), arms(l, l, l, H), arms(l, H, l, l), arms(l, H, l, H),
    // 2540
    arms(H, l, l, l), arms(l, l, H, l), arms(H, l, H, l), arms(H, l, l, H),
    arms(H, H, l, l), arms(l, l, H, H), arms(l, H, H, l), arms(H, H, l, H),
    arms(l, H, H, H), arms(H, l, H, H), arms(H, H, H, l), arms(H, H, H, H),
    arms(n, n, n, n), arms(n, n, n, n), arms(n, n, n, n), arms(n, n, n, n),
    // 2550
    arms(n, d, n, d), arms(d, n, d, n), arms(n, d, l, n), arms(n, l, d, n),
    arms(n, d, d, n), arms(n, n, l, d), arms(n, n, d, l), arms(n, n, d, d),
    arms(l, d, n, n), arms(d, l, n, n), arms(d, d, n, n), arms(l, n, n, d),
    arms(d, n, n, l), arms(d, n, n, d), arms(l, d, l, n), arms(d, l, d, n),
    // 2560
    arms(d, d, d, n), arms(l, n, l, d), arms(d, n, d, l), arms(d, n, d, d),
    arms(n, d, l, d), arms(n, l, d, l), arms(n, d, d, d), arms(l, d, n, d),
    arms(d, l, n, l), arms(d, d, n, d), arms(l, d, l, d), arms(d, l, d, l),
    arms(d, d, d, d), arms(n, n, n, n), arms(n, n, n, n), arms(n, n, n, n),
    // 2570
    arms(n, n, n, n), arms(n, n, n, n), arms(n, n, n, n), arms(n, n, n, n),
    arms(n, n, n, l), arms(l, n, n, n), arms(n, l, n, n), arms(n, n, l, n),
    arms(n, n, n, H), arms(H, n, n, n), arms(n, H, n, n), arms(n, n, H, n),
    arms(n, H, n, l), arms(l, n, H, n), arms(n, l, n, H), arms(H, n, l, n),
};

comptime {
    std.debug.assert(box_table.len == 0x80);
}

/// Where the strokes of one axis sit, across that axis, in whole pixels.
const Bands = struct {
    t: i64,
    /// Start of a light stroke, of a heavy stroke, and of the first of a double pair.
    light: i64,
    heavy: i64,
    double: i64,

    fn of(extent: u32, t: u32) Bands {
        const e: i64 = extent;
        const ti: i64 = t;
        return .{
            .t = ti,
            .light = @divFloor(e - ti, 2),
            .heavy = @divFloor(e - 2 * ti, 2),
            .double = @divFloor(e - 3 * ti, 2),
        };
    }

    fn start(self: Bands, weight: Weight) i64 {
        return switch (weight) {
            .heavy => self.heavy,
            .double => self.double,
            else => self.light,
        };
    }

    fn end(self: Bands, weight: Weight) i64 {
        return switch (weight) {
            .none => self.light + self.t,
            .light => self.light + self.t,
            .heavy => self.heavy + 2 * self.t,
            .double => self.double + 3 * self.t,
        };
    }

    /// The widest single stroke among two arms, or `none` when neither is a single stroke.
    fn widest(a: Weight, b: Weight) Weight {
        if (a == .heavy or b == .heavy) return .heavy;
        if (a == .light or b == .light) return .light;
        return .none;
    }
};

fn box(canvas: *Canvas, codepoint: u21) void {
    switch (codepoint) {
        0x2504, 0x2505 => dashes(canvas, .horizontal, 3, codepoint == 0x2505),
        0x2506, 0x2507 => dashes(canvas, .vertical, 3, codepoint == 0x2507),
        0x2508, 0x2509 => dashes(canvas, .horizontal, 4, codepoint == 0x2509),
        0x250A, 0x250B => dashes(canvas, .vertical, 4, codepoint == 0x250B),
        0x254C, 0x254D => dashes(canvas, .horizontal, 2, codepoint == 0x254D),
        0x254E, 0x254F => dashes(canvas, .vertical, 2, codepoint == 0x254F),
        0x256D...0x2570 => arc(canvas, codepoint),
        0x2571 => diagonal(canvas, .rising),
        0x2572 => diagonal(canvas, .falling),
        0x2573 => {
            diagonal(canvas, .rising);
            diagonal(canvas, .falling);
        },
        else => lines(canvas, box_table[codepoint - 0x2500]),
    }
}

/// Draw the arms of a line character. Each arm runs from its cell edge into the centre and stops on
/// the far side of the perpendicular strokes it meets, so a junction is closed and an arm on its own
/// (U+2574..U+257F) still reaches the middle of the cell.
fn lines(canvas: *Canvas, a: Arms) void {
    const t = lineThickness(canvas.height);
    const cols = Bands.of(canvas.width, t);
    const rows = Bands.of(canvas.height, t);
    const w: i64 = canvas.width;
    const hh: i64 = canvas.height;
    const ti: i64 = t;

    const horizontal_double = a.left == .double or a.right == .double;
    const vertical_double = a.up == .double or a.down == .double;
    const across = Bands.widest(a.left, a.right);
    const along = Bands.widest(a.up, a.down);
    // Double-line stroke positions on each axis.
    const xl = cols.double;
    const xr = cols.double + 2 * ti;
    const yt = rows.double;
    const yb = rows.double + 2 * ti;

    // Vertical arms.
    inline for (.{ .up, .down }) |direction| {
        const weight = @field(a, @tagName(direction));
        if (weight == .light or weight == .heavy) {
            const x0 = cols.start(weight);
            const x1 = cols.end(weight);
            var reach_start: i64 = undefined; // where the up arm ends / the down arm starts
            var reach_end: i64 = undefined;
            if (horizontal_double) {
                const both = a.left == .double and a.right == .double;
                reach_end = if (both) yt + ti else yb + ti;
                reach_start = if (both) yb else yt;
            } else if (across != .none) {
                reach_end = rows.end(across);
                reach_start = rows.start(across);
            } else {
                reach_end = rows.end(weight);
                reach_start = rows.start(weight);
            }
            if (direction == .up) canvas.rect(x0, 0, x1, reach_end, 255) else canvas.rect(x0, reach_start, x1, hh, 255);
        } else if (weight == .double) {
            for ([_]i64{ xl, xr }, 0..) |x0, side| {
                // The stroke on the side an arm leaves from turns into that arm; the other side
                // runs on to the far stroke, so corners and tees close the way the glyphs do.
                const toward: Weight = if (side == 0) a.left else a.right;
                var reach_start: i64 = undefined;
                var reach_end: i64 = undefined;
                if (horizontal_double) {
                    reach_end = if (toward != .none) yt + ti else yb + ti;
                    reach_start = if (toward != .none) yb else yt;
                } else if (across != .none) {
                    reach_end = rows.end(across);
                    reach_start = rows.start(across);
                } else {
                    reach_end = rows.double + 3 * ti;
                    reach_start = rows.double;
                }
                if (direction == .up) canvas.rect(x0, 0, x0 + ti, reach_end, 255) else canvas.rect(x0, reach_start, x0 + ti, hh, 255);
            }
        }
    }

    // Horizontal arms, the same rules turned through ninety degrees.
    inline for (.{ .left, .right }) |direction| {
        const weight = @field(a, @tagName(direction));
        if (weight == .light or weight == .heavy) {
            const y0 = rows.start(weight);
            const y1 = rows.end(weight);
            var reach_start: i64 = undefined;
            var reach_end: i64 = undefined;
            if (vertical_double) {
                const both = a.up == .double and a.down == .double;
                reach_end = if (both) xl + ti else xr + ti;
                reach_start = if (both) xr else xl;
            } else if (along != .none) {
                reach_end = cols.end(along);
                reach_start = cols.start(along);
            } else {
                reach_end = cols.end(weight);
                reach_start = cols.start(weight);
            }
            if (direction == .left) canvas.rect(0, y0, reach_end, y1, 255) else canvas.rect(reach_start, y0, w, y1, 255);
        } else if (weight == .double) {
            for ([_]i64{ yt, yb }, 0..) |y0, side| {
                const toward: Weight = if (side == 0) a.up else a.down;
                var reach_start: i64 = undefined;
                var reach_end: i64 = undefined;
                if (vertical_double) {
                    reach_end = if (toward != .none) xl + ti else xr + ti;
                    reach_start = if (toward != .none) xr else xl;
                } else if (along != .none) {
                    reach_end = cols.end(along);
                    reach_start = cols.start(along);
                } else {
                    reach_end = cols.double + 3 * ti;
                    reach_start = cols.double;
                }
                if (direction == .left) canvas.rect(0, y0, reach_end, y0 + ti, 255) else canvas.rect(reach_start, y0, w, y0 + ti, 255);
            }
        }
    }
}

const Axis = enum { horizontal, vertical };

/// `count` dashes per cell, each centred in an equal slot so a dashed rule keeps one rhythm across
/// cells.
fn dashes(canvas: *Canvas, axis: Axis, count: u32, heavy: bool) void {
    const t = lineThickness(canvas.height);
    const weight: Weight = if (heavy) .heavy else .light;
    const length: u32 = if (axis == .horizontal) canvas.width else canvas.height;
    const across = Bands.of(if (axis == .horizontal) canvas.height else canvas.width, t);
    const gap: i64 = @max(1, @divFloor(@as(i64, length), @as(i64, count) * 4));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const from: i64 = @divFloor(@as(i64, length) * i, count) + @divFloor(gap, 2);
        const to: i64 = @divFloor(@as(i64, length) * (i + 1), count) - (gap - @divFloor(gap, 2));
        if (axis == .horizontal) {
            canvas.rect(from, across.start(weight), to, across.end(weight), 255);
        } else {
            canvas.rect(across.start(weight), from, across.end(weight), to, 255);
        }
    }
}

const Arc = struct {
    cx: f32,
    cy: f32,
    radius: f32,
    half: f32,
    /// Which quadrant of the circle is drawn, as the sign of x and y from the centre.
    sx: f32,
    sy: f32,
};

fn insideArc(a: Arc, x: f32, y: f32) bool {
    const dx = x - a.cx;
    const dy = y - a.cy;
    if (dx * a.sx < 0 or dy * a.sy < 0) return false;
    const distance = @sqrt(dx * dx + dy * dy);
    return @abs(distance - a.radius) <= a.half;
}

/// The rounded corners U+256D..U+2570: a quarter circle joining the two light arms, each arm a
/// straight stroke from the cell edge to where the curve starts.
fn arc(canvas: *Canvas, codepoint: u21) void {
    const t = lineThickness(canvas.height);
    const cols = Bands.of(canvas.width, t);
    const rows = Bands.of(canvas.height, t);
    const tf: f32 = @floatFromInt(t);
    // The centre line of the light strokes, which is where the arc runs.
    const lx: f32 = @as(f32, @floatFromInt(cols.light)) + tf / 2;
    const ly: f32 = @as(f32, @floatFromInt(rows.light)) + tf / 2;
    const radius = @min(lx, ly, canvas.w() - lx, canvas.h() - ly);
    const r: i64 = @intFromFloat(@floor(radius));
    const w: i64 = canvas.width;
    const hh: i64 = canvas.height;
    // (right?, down?) for the two arms each corner joins.
    const right = codepoint == 0x256D or codepoint == 0x2570;
    const down = codepoint == 0x256D or codepoint == 0x256E;
    const sx: f32 = if (right) 1 else -1;
    const sy: f32 = if (down) 1 else -1;
    // The circle's centre is diagonally off the cell centre, towards the arms.
    const centre = Arc{
        .cx = lx + sx * radius,
        .cy = ly + sy * radius,
        .radius = radius,
        .half = tf / 2,
        .sx = -sx,
        .sy = -sy,
    };
    canvas.sample(centre, insideArc);
    const lx0 = cols.light;
    const ly0 = rows.light;
    if (down) canvas.rect(lx0, ly0 + r, lx0 + t, hh, 255) else canvas.rect(lx0, 0, lx0 + t, ly0 + t - r, 255);
    if (right) canvas.rect(lx0 + r, ly0, w, ly0 + t, 255) else canvas.rect(0, ly0, lx0 + t - r, ly0 + t, 255);
}

const Slope = enum { rising, falling };

fn diagonal(canvas: *Canvas, slope: Slope) void {
    const tf: f32 = @floatFromInt(lineThickness(canvas.height));
    switch (slope) {
        .rising => canvas.line(.{ canvas.w(), 0 }, .{ 0, canvas.h() }, tf),
        .falling => canvas.line(.{ 0, 0 }, .{ canvas.w(), canvas.h() }, tf),
    }
}

// ---------------------------------------------------------------------------
// Block elements, U+2580..U+259F
// ---------------------------------------------------------------------------

fn eighth(extent: u32, count: u32) i64 {
    return @intCast((@as(u64, extent) * count + 4) / 8);
}

fn block(canvas: *Canvas, codepoint: u21) void {
    const w: i64 = canvas.width;
    const hh: i64 = canvas.height;
    const mid_x = eighth(canvas.width, 4);
    const mid_y = eighth(canvas.height, 4);
    switch (codepoint) {
        0x2580 => canvas.rect(0, 0, w, mid_y, 255),
        0x2581...0x2588 => canvas.rect(0, eighth(canvas.height, 8 - (codepoint - 0x2580)), w, hh, 255),
        0x2589...0x258F => canvas.rect(0, 0, eighth(canvas.width, 8 - (codepoint - 0x2588)), hh, 255),
        0x2590 => canvas.rect(mid_x, 0, w, hh, 255),
        0x2591 => canvas.rect(0, 0, w, hh, 0x40),
        0x2592 => canvas.rect(0, 0, w, hh, 0x80),
        0x2593 => canvas.rect(0, 0, w, hh, 0xC0),
        0x2594 => canvas.rect(0, 0, w, eighth(canvas.height, 1), 255),
        0x2595 => canvas.rect(eighth(canvas.width, 7), 0, w, hh, 255),
        0x2596...0x259F => {
            // Quadrants as upper-left, upper-right, lower-left, lower-right bits.
            const masks = [_]u4{ 0b0100, 0b1000, 0b0001, 0b1101, 0b1001, 0b0111, 0b1011, 0b0010, 0b0110, 0b1110 };
            const mask = masks[codepoint - 0x2596];
            if (mask & 0b0001 != 0) canvas.rect(0, 0, mid_x, mid_y, 255);
            if (mask & 0b0010 != 0) canvas.rect(mid_x, 0, w, mid_y, 255);
            if (mask & 0b0100 != 0) canvas.rect(0, mid_y, mid_x, hh, 255);
            if (mask & 0b1000 != 0) canvas.rect(mid_x, mid_y, w, hh, 255);
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Braille, U+2800..U+28FF
// ---------------------------------------------------------------------------

/// The cell-relative origin of one braille dot. Bit `i` of the codepoint's low byte is dot `i + 1`
/// in Unicode's numbering: dots 1-3 and 7 run down the left column, 4-6 and 8 down the right.
pub fn brailleDot(width_px: u32, height_px: u32, bit: u3) struct { x: i64, y: i64, size: i64 } {
    const column: u32 = switch (bit) {
        0, 1, 2, 6 => 0,
        else => 1,
    };
    const row: u32 = switch (bit) {
        0, 3 => 0,
        1, 4 => 1,
        2, 5 => 2,
        6, 7 => 3,
    };
    const size: u32 = @max(1, @min(width_px / 4, height_px / 8));
    // Each dot is centred in its quarter column and eighth-height row slot, so the pattern
    // keeps the same spacing across neighbouring cells.
    const slot_x = (width_px * (2 * column + 1)) / 4;
    const slot_y = (height_px * (2 * row + 1)) / 8;
    return .{
        .x = @as(i64, slot_x) - @as(i64, size / 2),
        .y = @as(i64, slot_y) - @as(i64, size / 2),
        .size = size,
    };
}

fn braille(canvas: *Canvas, codepoint: u21) void {
    const pattern: u8 = @truncate(codepoint - 0x2800);
    var bit: u4 = 0;
    while (bit < 8) : (bit += 1) {
        if (pattern & (@as(u8, 1) << @intCast(bit)) == 0) continue;
        const dot = brailleDot(canvas.width, canvas.height, @intCast(bit));
        canvas.rect(dot.x, dot.y, dot.x + dot.size, dot.y + dot.size, 255);
    }
}

// ---------------------------------------------------------------------------
// Powerline, U+E0B0..U+E0BF, U+E0D2, U+E0D4
// ---------------------------------------------------------------------------

fn powerline(canvas: *Canvas, codepoint: u21) void {
    const w = canvas.w();
    const hh = canvas.h();
    const tf: f32 = @floatFromInt(lineThickness(canvas.height));
    switch (codepoint) {
        0xE0B0 => canvas.convex(&[_][2]f32{ .{ 0, 0 }, .{ w, hh / 2 }, .{ 0, hh } }),
        0xE0B2 => canvas.convex(&[_][2]f32{ .{ w, 0 }, .{ 0, hh / 2 }, .{ w, hh } }),
        0xE0B1 => {
            canvas.line(.{ 0, 0 }, .{ w, hh / 2 }, tf);
            canvas.line(.{ w, hh / 2 }, .{ 0, hh }, tf);
        },
        0xE0B3 => {
            canvas.line(.{ w, 0 }, .{ 0, hh / 2 }, tf);
            canvas.line(.{ 0, hh / 2 }, .{ w, hh }, tf);
        },
        0xE0B4 => canvas.sample(Ellipse{ .cx = 0, .cy = hh / 2, .rx = w, .ry = hh / 2 }, insideEllipse),
        0xE0B5 => canvas.sample(Ellipse{ .cx = 0, .cy = hh / 2, .rx = w, .ry = hh / 2, .stroke = tf }, insideEllipse),
        0xE0B6 => canvas.sample(Ellipse{ .cx = w, .cy = hh / 2, .rx = w, .ry = hh / 2 }, insideEllipse),
        0xE0B7 => canvas.sample(Ellipse{ .cx = w, .cy = hh / 2, .rx = w, .ry = hh / 2, .stroke = tf }, insideEllipse),
        0xE0B8 => canvas.convex(&[_][2]f32{ .{ 0, 0 }, .{ w, hh }, .{ 0, hh } }),
        0xE0BA => canvas.convex(&[_][2]f32{ .{ w, 0 }, .{ w, hh }, .{ 0, hh } }),
        0xE0BC => canvas.convex(&[_][2]f32{ .{ 0, 0 }, .{ w, 0 }, .{ 0, hh } }),
        0xE0BE => canvas.convex(&[_][2]f32{ .{ 0, 0 }, .{ w, 0 }, .{ w, hh } }),
        0xE0B9, 0xE0BF => canvas.line(.{ 0, 0 }, .{ w, hh }, tf),
        0xE0BB, 0xE0BD => canvas.line(.{ w, 0 }, .{ 0, hh }, tf),
        0xE0D2, 0xE0D4 => {
            // Two trapezoids meeting at a notch: the "trapezoid" separators.
            const flip = codepoint == 0xE0D4;
            const xs = [_]f32{ 0, w, w / 2, 0 };
            var top: [4][2]f32 = undefined;
            var bottom: [4][2]f32 = undefined;
            const ys_top = [_]f32{ 0, 0, hh / 2 - tf / 2, hh / 2 - tf / 2 };
            const ys_bottom = [_]f32{ hh, hh, hh / 2 + tf / 2, hh / 2 + tf / 2 };
            for (0..4) |i| {
                const x = if (flip) w - xs[i] else xs[i];
                top[i] = .{ x, ys_top[i] };
                bottom[i] = .{ x, ys_bottom[i] };
            }
            canvas.convex(&top);
            canvas.convex(&bottom);
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn renderAlloc(codepoint: u21, width: u32, height: u32) ![]u8 {
    const pixels = try testing.allocator.alloc(u8, @as(usize, width) * height);
    errdefer testing.allocator.free(pixels);
    try testing.expect(render(codepoint, width, height, pixels));
    return pixels;
}

fn at(pixels: []const u8, width: u32, x: u32, y: u32) u8 {
    return pixels[@as(usize, y) * width + x];
}

test "sprite coverage is exactly the ranges drawn here" {
    try testing.expect(covers(0x2500));
    try testing.expect(covers(0x257F));
    try testing.expect(covers(0x2588));
    try testing.expect(covers(0x28FF));
    try testing.expect(covers(0xE0B0));
    try testing.expect(covers(0xE0D4));
    try testing.expect(!covers(0xE0C0)); // flames come from the bundled symbols face
    try testing.expect(!covers('A'));
    try testing.expect(!covers(0x25A0));
    var tiny: [3]u8 = undefined;
    try testing.expect(!render(0x2500, 2, 2, &tiny));
    try testing.expect(!render('A', 1, 1, &tiny));
}

test "U+2500 and U+2502 meet the cell edges and cross at the same pixels" {
    for ([_][2]u32{ .{ 8, 20 }, .{ 9, 17 }, .{ 17, 38 } }) |size| {
        const w = size[0];
        const h = size[1];
        const horizontal = try renderAlloc(0x2500, w, h);
        defer testing.allocator.free(horizontal);
        const vertical = try renderAlloc(0x2502, w, h);
        defer testing.allocator.free(vertical);
        const cross = try renderAlloc(0x253C, w, h);
        defer testing.allocator.free(cross);

        const t = lineThickness(h);
        const y0: u32 = (h - t) / 2;
        const x0: u32 = (w - t) / 2;
        // Full ink from the first column to the last on every row of the stroke, and nothing
        // elsewhere: the line touches both edges so neighbours join without a seam.
        for (0..h) |y| for (0..w) |x| {
            const in_row = y >= y0 and y < y0 + t;
            try testing.expectEqual(@as(u8, if (in_row) 255 else 0), at(horizontal, w, @intCast(x), @intCast(y)));
            const in_col = x >= x0 and x < x0 + t;
            try testing.expectEqual(@as(u8, if (in_col) 255 else 0), at(vertical, w, @intCast(x), @intCast(y)));
            try testing.expectEqual(@as(u8, if (in_row or in_col) 255 else 0), at(cross, w, @intCast(x), @intCast(y)));
        };
    }
}

test "a heavy line is twice the light stroke and corners close" {
    const w = 10;
    const h = 22;
    const heavy = try renderAlloc(0x2501, w, h);
    defer testing.allocator.free(heavy);
    var inked_rows: u32 = 0;
    for (0..h) |y| {
        if (at(heavy, w, 0, @intCast(y)) == 255) inked_rows += 1;
    }
    try testing.expectEqual(2 * lineThickness(h), inked_rows);

    // ┌ reaches the right and bottom edges and is closed at the corner.
    const corner = try renderAlloc(0x250C, w, h);
    defer testing.allocator.free(corner);
    const t = lineThickness(h);
    const x0 = (w - t) / 2;
    const y0 = (h - t) / 2;
    try testing.expectEqual(@as(u8, 255), at(corner, w, w - 1, y0));
    try testing.expectEqual(@as(u8, 255), at(corner, w, x0, h - 1));
    try testing.expectEqual(@as(u8, 255), at(corner, w, x0, y0));
    try testing.expectEqual(@as(u8, 0), at(corner, w, 0, y0));
    try testing.expectEqual(@as(u8, 0), at(corner, w, x0, 0));
}

test "double lines are two strokes and a double corner joins outer to outer" {
    const w = 12;
    const h = 24;
    const t = lineThickness(h);
    const double = try renderAlloc(0x2550, w, h);
    defer testing.allocator.free(double);
    const yt = (h - 3 * t) / 2;
    try testing.expectEqual(@as(u8, 255), at(double, w, 0, yt));
    try testing.expectEqual(@as(u8, 0), at(double, w, 0, yt + t));
    try testing.expectEqual(@as(u8, 255), at(double, w, 0, yt + 2 * t));
    try testing.expectEqual(@as(u8, 255), at(double, w, w - 1, yt + 2 * t));

    // ╔: the outer strokes meet at the outer corner, the inner ones at the inner corner, and the
    // gap between the strokes stays empty.
    const corner = try renderAlloc(0x2554, w, h);
    defer testing.allocator.free(corner);
    const xl = (w - 3 * t) / 2;
    try testing.expectEqual(@as(u8, 255), at(corner, w, xl, yt));
    try testing.expectEqual(@as(u8, 255), at(corner, w, xl + 2 * t, yt + 2 * t));
    try testing.expectEqual(@as(u8, 0), at(corner, w, xl + t, yt + t));
    try testing.expectEqual(@as(u8, 0), at(corner, w, xl - 1, yt));
}

test "braille dots land in their two columns and four rows" {
    const w = 8;
    const h = 16;
    const all = try renderAlloc(0x28FF, w, h);
    defer testing.allocator.free(all);
    const none = try renderAlloc(0x2800, w, h);
    defer testing.allocator.free(none);
    for (none) |p| try testing.expectEqual(@as(u8, 0), p);

    var bit: u4 = 0;
    while (bit < 8) : (bit += 1) {
        const single = try renderAlloc(0x2800 + (@as(u21, 1) << @intCast(bit)), w, h);
        defer testing.allocator.free(single);
        const dot = brailleDot(w, h, @intCast(bit));
        var count: u32 = 0;
        for (single) |p| {
            if (p != 0) count += 1;
        }
        try testing.expectEqual(@as(u32, @intCast(dot.size * dot.size)), count);
        try testing.expectEqual(@as(u8, 255), at(single, w, @intCast(dot.x), @intCast(dot.y)));
        try testing.expectEqual(@as(u8, 255), at(all, w, @intCast(dot.x), @intCast(dot.y)));
    }
    // Dot 1 (bit 0) is top-left, dot 4 (bit 3) top-right, dot 7 (bit 6) bottom-left and dot 8
    // (bit 7) bottom-right.
    try testing.expect(brailleDot(w, h, 0).x < brailleDot(w, h, 3).x);
    try testing.expectEqual(brailleDot(w, h, 0).y, brailleDot(w, h, 3).y);
    try testing.expect(brailleDot(w, h, 6).y > brailleDot(w, h, 2).y);
    try testing.expectEqual(brailleDot(w, h, 6).x, brailleDot(w, h, 0).x);
    try testing.expectEqual(brailleDot(w, h, 7).x, brailleDot(w, h, 3).x);
}

test "Powerline U+E0B0 fills the full cell height on its left edge and tapers to a point" {
    for ([_][2]u32{ .{ 8, 20 }, .{ 17, 38 } }) |size| {
        const w = size[0];
        const h = size[1];
        const arrow = try renderAlloc(0xE0B0, w, h);
        defer testing.allocator.free(arrow);
        // The first column is solid on every row but the two whose pixel the slope crosses, so the
        // arrow meets the coloured segment before it without a seam.
        for (0..h) |y| {
            const ink = at(arrow, w, 0, @intCast(y));
            if (y == 0 or y == h - 1) try testing.expect(ink > 0) else try testing.expectEqual(@as(u8, 255), ink);
        }
        // The point reaches the right edge at mid-height and nowhere near the corners.
        try testing.expect(at(arrow, w, w - 1, h / 2) > 0);
        try testing.expectEqual(@as(u8, 0), at(arrow, w, w - 1, 0));
        try testing.expectEqual(@as(u8, 0), at(arrow, w, w - 1, h - 1));

        // The mirror image fills the right edge instead.
        const left = try renderAlloc(0xE0B2, w, h);
        defer testing.allocator.free(left);
        for (1..h - 1) |y| try testing.expectEqual(@as(u8, 255), at(left, w, w - 1, @intCast(y)));
    }
}

test "block elements split the cell on whole pixels" {
    const w = 9;
    const h = 19;
    const full = try renderAlloc(0x2588, w, h);
    defer testing.allocator.free(full);
    for (full) |p| try testing.expectEqual(@as(u8, 255), p);
    const upper = try renderAlloc(0x2580, w, h);
    defer testing.allocator.free(upper);
    const lower = try renderAlloc(0x2584, w, h);
    defer testing.allocator.free(lower);
    // The two halves tile the cell exactly with no overlap.
    for (upper, lower) |a, b| try testing.expectEqual(@as(u16, 255), @as(u16, a) + b);
    const shade = try renderAlloc(0x2592, w, h);
    defer testing.allocator.free(shade);
    try testing.expectEqual(@as(u8, 0x80), shade[0]);
}

test "a rounded corner reaches both of its edges on the light stroke" {
    const w = 10;
    const h = 22;
    const t = lineThickness(h);
    const corner = try renderAlloc(0x256D, w, h); // ╭: right and down
    defer testing.allocator.free(corner);
    const x0 = (w - t) / 2;
    const y0 = (h - t) / 2;
    try testing.expectEqual(@as(u8, 255), at(corner, w, x0, h - 1));
    try testing.expectEqual(@as(u8, 255), at(corner, w, w - 1, y0));
    try testing.expectEqual(@as(u8, 0), at(corner, w, 0, y0));
    try testing.expectEqual(@as(u8, 0), at(corner, w, x0, 0));
}
