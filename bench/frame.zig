//! Frame-time benchmark (TASK-67): how long the grid renderer takes to draw
//! 1, 4 and 9 terminal panes into a 1920x1080 logical surface at display
//! scales 1 and 2, with every row redrawn and with one dirty row.
//!
//! Each pane is a real `term.Terminal` filled with coloured output and drawn by
//! its own `render.Grid` through `drawViewport`, which is the app's pane path.
//! Two times are reported per frame: `submit` is the CPU side (staging cells,
//! shaping, uploads and GL calls), and `finish` adds `glFinish`, so it includes
//! the rasteriser. On a software renderer (llvmpipe) the second number is CPU
//! work too and the record says so with `"indicative": true`.

const std = @import("std");
const term = @import("term");
const render = @import("render");
const font = @import("font");
const common = @import("common.zig");
const gpu = @import("gpu.zig");

const Io = std.Io;

/// Warnings and errors only: the engine logs every page-capacity change at
/// info, which would bury the summary and cost time inside the measurement.
pub const std_options: std.Options = .{ .log_level = .warn };

const logical_width: u32 = 1920;
const logical_height: u32 = 1080;
const warmup_frames = 10;
const measured_frames = 120;

const Pane = struct {
    terminal: term.Terminal,
    grid: render.Grid,
    origin: render.CellPoint,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var out_buffer: [4096]u8 = undefined;
    var out_file = Io.File.stdout().writerStreaming(io, &out_buffer);
    const out = &out_file.interface;
    defer out.flush() catch {};

    var context = gpu.Context.open() catch |err| {
        try common.emit(out, .{ .bench = "frame", .skipped = @errorName(err) });
        common.note("frame: skipped, no GL context ({s}); run under xvfb-run -a", .{@errorName(err)});
        return;
    };
    defer context.close();
    common.note("frame: renderer {s}{s}", .{ context.renderer, if (context.software) " (software: indicative)" else "" });

    for ([_]f32{ 1.0, 2.0 }) |scale| {
        for ([_]u32{ 1, 2, 3 }) |side| {
            try runLayout(gpa, io, out, &context, scale, side, .sgr);
            try out.flush();
        }
        // A screen of distinct wide glyphs: the atlas holds well over a
        // thousand entries, which is where a per-glyph lookup that scales
        // with the atlas shows.
        try runLayout(gpa, io, out, &context, scale, 1, .cjk);
        try out.flush();
    }
}

fn runLayout(
    gpa: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    context: *const gpu.Context,
    scale: f32,
    side: u32,
    content: Content,
) !void {
    var fonts = try gpu.openFonts(gpa, io, scale);
    defer fonts.deinit();
    const cell = fonts.metrics().cell;
    const surface_size: render.Size = (render.Size{ .width = logical_width, .height = logical_height }).scaled(scale);
    var surface = try render.Surface.init(surface_size);
    defer surface.deinit();

    // Panes tile the surface with a one-cell divider between them, as the
    // app's pane layout does.
    const total_cols = surface_size.width / cell.width_px;
    const total_rows = surface_size.height / cell.height_px;
    const pane_cols: u16 = @intCast((total_cols - (side - 1)) / side);
    const pane_rows: u16 = @intCast((total_rows - (side - 1)) / side);
    const size = try term.GridSize.init(pane_cols, pane_rows);

    const count = side * side;
    const panes = try gpa.alloc(Pane, count);
    defer gpa.free(panes);
    var made: usize = 0;
    defer for (panes[0..made]) |*pane| {
        pane.grid.deinit();
        pane.terminal.deinit(gpa);
    };

    // Coloured output with glyphs, colours and decorations on every row and
    // history above the view, or a screen of distinct wide glyphs.
    const fill = switch (content) {
        .sgr => blk: {
            const bytes = try gpa.alloc(u8, 64 * 1024);
            _ = common.generate(.sgr, bytes);
            break :blk bytes;
        },
        .cjk => try distinctWide(gpa, pane_cols / 2, pane_rows),
    };
    defer gpa.free(fill);

    for (panes, 0..) |*pane, index| {
        const x: u32 = @intCast(index % side);
        const y: u32 = @intCast(index / side);
        pane.origin = .{ .col = x * (pane_cols + 1), .row = y * (pane_rows + 1) };
        try pane.terminal.init(io, gpa, size);
        pane.grid = render.Grid.init(gpa, gpu.colors()) catch |err| {
            pane.terminal.deinit(gpa);
            return err;
        };
        made += 1;
        try pane.grid.attachAtlas(fonts.atlasPixels(), .{ .width_px = gpu.atlas_px, .height_px = gpu.atlas_px });
        pane.terminal.feed(fill);
    }

    const cases = [_]struct { name: []const u8, full: bool }{
        .{ .name = "full", .full = true },
        .{ .name = "one-row", .full = false },
    };
    var line_buffer: [64]u8 = undefined;
    var frame_index: usize = 0;
    // The very first frame of a layout: every glyph on screen is rasterised
    // and uploaded, and the driver compiles its shader variants (on llvmpipe
    // an LLVM JIT), which is a cost a user pays once at startup.
    var first_frame_ms: f64 = 0;
    for (cases) |case| {
        var submit: [measured_frames]f64 = undefined;
        var finish: [measured_frames]f64 = undefined;
        var rows_before: u64 = 0;
        for (panes) |*pane| rows_before += pane.grid.gridStats().rows;
        var stats_at_measure: render.GridStats = .{};
        for (0..warmup_frames + measured_frames) |iteration| {
            frame_index += 1;
            if (!case.full) {
                // One program writes one row in one pane: a clock, a progress
                // counter, a shell echoing a key.
                const line = try std.fmt.bufPrint(&line_buffer, "\x1b[{d};1Hframe {d:0>8}", .{ pane_rows / 2, frame_index });
                panes[0].terminal.feed(line);
            }
            const started = common.nowNs(io);
            for (panes) |*pane| {
                if (case.full) pane.grid.invalidate();
                try pane.terminal.refresh(gpa);
                const viewport = render.GridViewport.fromCells(pane.origin, size, cell);
                try pane.grid.drawViewport(&surface, &fonts, &pane.terminal, true, viewport);
            }
            const submitted = common.nowNs(io);
            gpu.finish();
            const finished = common.nowNs(io);
            if (frame_index == 1) first_frame_ms = common.millis(started, finished);
            if (iteration + 1 == warmup_frames) stats_at_measure = sumStats(panes);
            if (iteration >= warmup_frames) {
                submit[iteration - warmup_frames] = common.millis(started, submitted);
                finish[iteration - warmup_frames] = common.millis(started, finished);
            }
        }
        var rows_after: u64 = 0;
        for (panes) |*pane| rows_after += pane.grid.gridStats().rows;
        const rows_per_frame = @as(f64, @floatFromInt(rows_after - rows_before)) / (warmup_frames + measured_frames);
        // Glyph work in the measured frames only: a steady screen rasterises
        // nothing and uploads no atlas, so anything here is cache churn.
        const stats_end = sumStats(panes);
        const rasterised_per_frame = @as(f64, @floatFromInt(stats_end.rasterised - stats_at_measure.rasterised)) / measured_frames;
        const atlas_uploads = stats_end.atlas_uploads - stats_at_measure.atlas_uploads;

        var case_name_buffer: [64]u8 = undefined;
        const case_name = try std.fmt.bufPrint(&case_name_buffer, "{d}-pane-scale{d}-{s}{s}", .{
            count,
            @as(u32, @intFromFloat(scale)),
            if (content == .cjk) "cjk-" else "",
            case.name,
        });
        var submit_sorted = submit;
        var finish_sorted = finish;
        const record = .{
            .bench = "frame",
            .case = case_name,
            .panes = count,
            .scale = scale,
            .surface_px = .{ surface_size.width, surface_size.height },
            .pane_grid = .{ pane_cols, pane_rows },
            .rows_per_frame = rows_per_frame,
            .first_frame_ms = first_frame_ms,
            .rasterised_per_frame = rasterised_per_frame,
            .atlas_uploads = atlas_uploads,
            .submit_ms_median = common.median(&submit_sorted),
            .submit_ms_p95 = common.percentile(&submit_sorted, 0.95),
            .finish_ms_median = common.median(&finish_sorted),
            .finish_ms_p95 = common.percentile(&finish_sorted, 0.95),
            .renderer = context.renderer,
            .indicative = context.software,
        };
        try common.emit(out, record);
        common.note("frame {s}: {d}x{d} cells/pane, {d:.1} rows/frame, {d:.1} glyphs rasterised/frame, submit {d:.2} ms (p95 {d:.2}), with glFinish {d:.2} ms (p95 {d:.2})", .{
            case_name,
            pane_cols,
            pane_rows,
            rows_per_frame,
            rasterised_per_frame,
            record.submit_ms_median,
            record.submit_ms_p95,
            record.finish_ms_median,
            record.finish_ms_p95,
        });
    }
}

const Content = enum { sgr, cjk };

/// Distinct CJK ideographs before the sequence repeats: enough to fill a
/// 1920x1080 screen of wide cells without repeating a glyph on screen, and
/// few enough that the app-sized atlas holds them all.
const distinct_wide = 1800;

/// `rows` lines of `per_row` wide glyphs, each line a CRLF, walking
/// `distinct_wide` consecutive ideographs from U+4E00.
fn distinctWide(gpa: std.mem.Allocator, per_row: usize, rows: usize) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    var next: usize = 0;
    for (0..rows) |row| {
        for (0..per_row) |_| {
            var encoded: [4]u8 = undefined;
            const codepoint: u21 = @intCast(0x4e00 + next % distinct_wide);
            const length = try std.unicode.utf8Encode(codepoint, &encoded);
            try bytes.appendSlice(gpa, encoded[0..length]);
            next += 1;
        }
        if (row + 1 < rows) try bytes.appendSlice(gpa, "\r\n");
    }
    return bytes.toOwnedSlice(gpa);
}

fn sumStats(panes: []const Pane) render.GridStats {
    var total: render.GridStats = .{};
    for (panes) |*pane| {
        const stats = pane.grid.gridStats();
        total.rasterised += stats.rasterised;
        total.atlas_uploads += stats.atlas_uploads;
    }
    return total;
}
