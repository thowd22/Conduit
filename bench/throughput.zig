//! Throughput benchmark (TASK-67): how fast deterministic program output goes
//! through the terminal engine, alone and with the frames a user would see.
//!
//! Each workload (plain lines, carriage-return floods, SGR-heavy lines, wide
//! CJK) is generated once at 16 and 64 MiB and fed in the 64 KiB slices the
//! app's pump reads (`pty_read_capacity` in `src/main.zig`). Three modes:
//!
//! - `term`: `Terminal.feed` only, then one `refresh` at the end.
//! - `refresh`: as the app does it without a GPU: whenever a frame is due,
//!   `refresh` and read every visible cell, the CPU half of `Grid.draw`.
//! - `grid`: a real `render.Grid.draw` into the offscreen surface plus
//!   `glFinish`, when a GL context is available.
//!
//! A frame is due when `max(16 ms, last frame's cost)` has passed since the
//! previous one, which is `FramePacer`'s rule (TASK-72), so a slow frame
//! cannot starve the parser and a fast parser cannot skip every frame.

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

const cols: u16 = 160;
const rows: u16 = 50;
const slice_bytes = 64 * 1024;
const frame_interval_ns: i96 = 16 * std.time.ns_per_ms;

const Mode = enum { term, refresh, grid };

const Gpu = struct {
    context: gpu.Context,
    fonts: font.Manager,
    surface: render.Surface,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try common.collectArgs(init.arena.allocator(), init.minimal.args);
    // `--quick` runs 16 MiB only; the default adds 64 MiB.
    const quick = common.flag(args, "quick") != null;

    var out_buffer: [4096]u8 = undefined;
    var out_file = Io.File.stdout().writerStreaming(io, &out_buffer);
    const out = &out_file.interface;
    defer out.flush() catch {};

    var maybe_gpu: ?Gpu = blk: {
        var context = gpu.Context.open() catch |err| {
            common.note("throughput: grid mode skipped, no GL context ({s})", .{@errorName(err)});
            break :blk null;
        };
        var fonts = gpu.openFonts(gpa, io, 1.0) catch |err| {
            context.close();
            return err;
        };
        const cell = fonts.metrics().cell;
        const surface = render.Surface.init(.{ .width = cell.width_px * cols, .height = cell.height_px * rows }) catch |err| {
            fonts.deinit();
            context.close();
            return err;
        };
        break :blk .{ .context = context, .fonts = fonts, .surface = surface };
    };
    defer if (maybe_gpu) |*held| {
        held.surface.deinit();
        held.fonts.deinit();
        held.context.close();
    };
    if (maybe_gpu == null) try common.emit(out, .{ .bench = "throughput", .mode = "grid", .skipped = "no GL context" });

    const sizes = [_]usize{ 16, 64 };
    const size_count: usize = if (quick) 1 else sizes.len;
    for (sizes[0..size_count]) |mib| {
        const input = try gpa.alloc(u8, mib * 1024 * 1024);
        defer gpa.free(input);
        for (std.enums.values(common.Workload)) |workload| {
            const lines = common.generate(workload, input);
            for (std.enums.values(Mode)) |mode| {
                if (mode == .grid and maybe_gpu == null) continue;
                const gpu_ptr: ?*Gpu = if (maybe_gpu) |*held| held else null;
                const result = try run(gpa, io, input, mode, gpu_ptr);
                const secs = common.seconds(0, result.elapsed_ns);
                var case_buffer: [64]u8 = undefined;
                const case = try std.fmt.bufPrint(&case_buffer, "{s}-{d}MiB-{s}", .{ workload.label(), mib, @tagName(mode) });
                const record = .{
                    .bench = "throughput",
                    .case = case,
                    .workload = workload.label(),
                    .mode = @tagName(mode),
                    .bytes = input.len,
                    .lines = lines,
                    .seconds = secs,
                    .mib_per_s = @as(f64, @floatFromInt(mib)) / secs,
                    .lines_per_s = @as(f64, @floatFromInt(lines)) / secs,
                    .frames = result.frames,
                    .indicative = mode == .grid and maybe_gpu.?.context.software,
                };
                try common.emit(out, record);
                try out.flush();
                common.note("throughput {s}: {d:.1} MiB/s, {d:.0} lines/s, {d} frames in {d:.2} s", .{
                    case, record.mib_per_s, record.lines_per_s, result.frames, secs,
                });
            }
        }
    }
}

const RunResult = struct {
    elapsed_ns: i96,
    frames: usize,
};

fn run(gpa: std.mem.Allocator, io: Io, input: []const u8, mode: Mode, held: ?*Gpu) !RunResult {
    var terminal: term.Terminal = undefined;
    try terminal.init(io, gpa, try term.GridSize.init(cols, rows));
    defer terminal.deinit(gpa);

    var grid: ?render.Grid = null;
    defer if (grid) |*value| value.deinit();
    if (mode == .grid) {
        const state = held.?;
        grid = try render.Grid.init(gpa, gpu.colors());
        try grid.?.attachAtlas(state.fonts.atlasPixels(), .{ .width_px = gpu.atlas_px, .height_px = gpu.atlas_px });
    }

    var frames: usize = 0;
    var checksum: u64 = 0;
    const started = common.nowNs(io);
    var last_frame = started;
    var interval = frame_interval_ns;
    var offset: usize = 0;
    while (offset < input.len) {
        const end = @min(offset + slice_bytes, input.len);
        terminal.feed(input[offset..end]);
        offset = end;
        if (mode == .term) continue;
        const now = common.nowNs(io);
        if (now - last_frame < interval and offset < input.len) continue;
        try drawFrame(gpa, &terminal, mode, held, if (grid) |*value| value else null, &checksum);
        frames += 1;
        const drawn = common.nowNs(io);
        interval = @max(frame_interval_ns, drawn - now);
        last_frame = drawn;
    }
    if (mode == .term) {
        try terminal.refresh(gpa);
        frames = 1;
    }
    const elapsed = common.nowNs(io) - started;
    // The checksum keeps the cell reads observable to the optimiser.
    std.mem.doNotOptimizeAway(checksum);
    return .{ .elapsed_ns = elapsed, .frames = frames };
}

fn drawFrame(
    gpa: std.mem.Allocator,
    terminal: *term.Terminal,
    mode: Mode,
    held: ?*Gpu,
    grid: ?*render.Grid,
    checksum: *u64,
) !void {
    try terminal.refresh(gpa);
    switch (mode) {
        .term => unreachable, // `run` never draws a frame in term mode
        .refresh => {
            var row: u16 = 0;
            while (row < rows) : (row += 1) {
                var col: u16 = 0;
                while (col < cols) : (col += 1) {
                    const cell = terminal.cell(.{ .col = col, .row = row }) orelse continue;
                    checksum.* +%= @intFromBool(cell.hasText());
                }
            }
        },
        .grid => {
            const state = held.?;
            try grid.?.draw(&state.surface, &state.fonts, terminal, true);
            gpu.finish();
        },
    }
}
