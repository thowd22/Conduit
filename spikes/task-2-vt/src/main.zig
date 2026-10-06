//! TASK-2 spike: prove libghostty-vt (Ghostty's VT parser + terminal state,
//! consumed as the `ghostty-vt` Zig module) builds and runs on Linux with
//! Zig 0.16.0, and that its grid really reflects parsed VT bytes.
//!
//! THROWAWAY spike code. The real project build (TASK-4) must not absorb this
//! file; see README.md next to it.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

const cols: u16 = 44;
const rows: u16 = 9;

/// Exactly the bytes a shell or CLI would write to a PTY. Colours, cursor
/// moves, plain text, escape sequences that change attributes, a wide cell, a
/// multi-codepoint grapheme and box-drawing glyphs.
const vt_input = "\x1b[2J\x1b[H" ++ // erase display, home cursor
    "\x1b[1;31m" ++ // SGR: bold, red foreground
    "Conduit VT spike" ++
    "\x1b[0m" ++ // SGR: reset
    "\x1b[2;1H" ++ // CUP: row 2, col 1
    "plain: " ++
    "\x1b[4m" ++ // SGR: underline
    "underlined tail" ++
    "\x1b[0m" ++
    "\x1b[3;1H" ++
    "\x1b[48;5;33m\x1b[97m" ++ // SGR: bg palette 33, fg bright white
    "bg-palette-33" ++
    "\x1b[0m" ++
    "\x1b[4;1H" ++
    "\x1b[7m" ++ // SGR: reverse video
    "reverse-video" ++
    "\x1b[0m" ++
    "\x1b[5;1H" ++
    "wide:\u{6f22} graph:e\u{0301} blocks:\u{2588}\u{2584}\u{2591}\u{2592}" ++
    "\x1b[0m" ++
    "\x1b[7;14H" ++ // CUP: park the cursor where the dump should find it
    "end";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var term: ghostty_vt.Terminal = try .init(init.io, gpa, .{
        .cols = cols,
        .rows = rows,
    });
    defer term.deinit(gpa);

    // Exercise resize explicitly: shrink, then grow back to the real grid, so
    // the dump below cannot come from a terminal that ignores resizes.
    try term.resize(gpa, .{ .cols = 10, .rows = 3 });
    try term.resize(gpa, .{ .cols = cols, .rows = rows });

    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice(vt_input);

    // RenderState is the same view a renderer uses, and the intended way to
    // read the grid out of libghostty-vt.
    var state: ghostty_vt.RenderState = .empty;
    defer state.deinit(gpa);
    try state.update(gpa, &term);

    std.debug.print("libghostty-vt grid: {d} cols x {d} rows\n", .{
        state.cols,
        state.rows,
    });
    std.debug.print("render state dirty: {t}\n", .{state.dirty});

    const range = state.rowDataRange();
    var seen: [16]ghostty_vt.Style = undefined;
    var seen_count: usize = 0;
    var styled_cells: usize = 0;

    for (range.start..range.end) |i| {
        const y = state.viewportY(i);
        const row = state.row_data.get(i);
        const raws = row.cells.items(.raw);
        const styles = row.cells.items(.style);
        const graphemes = row.cells.items(.grapheme);

        var text: std.Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        var marks: std.Io.Writer.Allocating = .init(gpa);
        defer marks.deinit();

        for (raws, 0..) |raw, x| {
            // The per-cell style is only defined when the cell carries a
            // non-default style id.
            const styled = raw.style_id != 0;
            if (styled) {
                styled_cells += 1;
                if (seen_count < seen.len and !containsStyle(seen[0..seen_count], styles[x])) {
                    seen[seen_count] = styles[x];
                    seen_count += 1;
                }
            }

            try marks.writer.writeByte(if (styled) '*' else '.');

            if (raw.wide == .spacer_tail) continue; // tail of a wide cell: no glyph

            switch (raw.content_tag) {
                .codepoint => {
                    const cp = raw.codepoint();
                    if (cp == 0) {
                        try text.writer.writeByte(' ');
                    } else {
                        try text.writer.print("{u}", .{cp});
                    }
                },
                .codepoint_grapheme => {
                    try text.writer.print("{u}", .{raw.codepoint()});
                    // The grapheme slice holds the codepoints *after* the base.
                    for (graphemes[x]) |cp| try text.writer.print("{u}", .{cp});
                },
                .bg_color_palette, .bg_color_rgb => {
                    try text.writer.writeByte(' ');
                },
            }
        }

        std.debug.print("{d} |{s}| {s}\n", .{ y, text.written(), marks.written() });
    }

    std.debug.print("\ndistinct non-default styles in the grid:\n", .{});
    for (seen[0..seen_count]) |style| {
        var desc: std.Io.Writer.Allocating = .init(gpa);
        defer desc.deinit();
        try writeStyle(&desc.writer, style);
        std.debug.print("  {s}\n", .{desc.written()});
    }
    std.debug.print("styled (non-default) cells: {d}\n", .{styled_cells});

    if (state.cursor.viewport) |cv| {
        std.debug.print("cursor in viewport: x={d} y={d}\n", .{ cv.x, cv.y });
    } else {
        std.debug.print("cursor in viewport: none\n", .{});
    }
    {
        var desc: std.Io.Writer.Allocating = .init(gpa);
        defer desc.deinit();
        try writeStyle(&desc.writer, state.cursor.style);
        std.debug.print("cursor cell style: {s}\n", .{desc.written()});
    }

    // Cross-check against the plain-text view straight from the terminal.
    const plain = try term.plainString(gpa);
    defer gpa.free(plain);
    std.debug.print("\nTerminal.plainString():\n{s}\n", .{plain});
}

fn containsStyle(list: []const ghostty_vt.Style, style: ghostty_vt.Style) bool {
    for (list) |s| if (s.eql(style)) return true;
    return false;
}

fn sep(w: *std.Io.Writer, first: *bool) !void {
    if (first.*) {
        first.* = false;
    } else {
        try w.writeAll(", ");
    }
}

fn writeColor(
    w: *std.Io.Writer,
    first: *bool,
    name: []const u8,
    c: ghostty_vt.Style.Color,
) !void {
    switch (c) {
        .none => {},
        .palette => |p| {
            try sep(w, first);
            try w.print("{s}palette({d})", .{ name, p });
        },
        .rgb => |rgb| {
            try sep(w, first);
            try w.print("{s}rgb({d},{d},{d})", .{ name, rgb.r, rgb.g, rgb.b });
        },
    }
}

// ghostty_vt.Style ships a debug `format` method with the pre-0.16 signature
// (`self, comptime fmt, options, writer`), which std 0.16's printValue never
// calls, so describe the style field by field instead.
fn writeStyle(w: *std.Io.Writer, s: ghostty_vt.Style) !void {
    try w.writeAll("Style{ ");
    var first = true;
    try writeColor(w, &first, "fg=", s.fg_color);
    try writeColor(w, &first, "bg=", s.bg_color);
    try writeColor(w, &first, "underline_color=", s.underline_color);

    const f = s.flags;
    if (f.bold or f.italic or f.faint or f.blink or f.inverse or
        f.invisible or f.strikethrough or f.overline or f.underline != .none)
    {
        try sep(w, &first);
        try w.writeAll("flags={");
        var ffirst = true;
        if (f.bold) try writeFlag(w, &ffirst, "bold");
        if (f.italic) try writeFlag(w, &ffirst, "italic");
        if (f.faint) try writeFlag(w, &ffirst, "faint");
        if (f.blink) try writeFlag(w, &ffirst, "blink");
        if (f.inverse) try writeFlag(w, &ffirst, "inverse");
        if (f.invisible) try writeFlag(w, &ffirst, "invisible");
        if (f.strikethrough) try writeFlag(w, &ffirst, "strikethrough");
        if (f.overline) try writeFlag(w, &ffirst, "overline");
        if (f.underline != .none) {
            try sep(w, &ffirst);
            try w.print("underline={t}", .{f.underline});
        }
        try w.writeAll("}");
    }

    try w.writeAll(" }");
}

fn writeFlag(w: *std.Io.Writer, first: *bool, name: []const u8) !void {
    try sep(w, first);
    try w.writeAll(name);
}
