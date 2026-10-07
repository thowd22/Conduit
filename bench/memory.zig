//! Memory benchmark (TASK-67): what an idle session with a full scrollback
//! costs, measured through the real owner the app uses.
//!
//! A local `workspace.Workspace` spawns real PTY children, each of which
//! prints more than the default 10,000-line scrollback of full-width lines and
//! then waits on its terminal. The workspace is pumped exactly as the event
//! loop pumps it until every session has drawn its marker and gone quiet, then
//! the process's resident set and the allocator's live and peak bytes are
//! read: once with one such session and again with eight.
//!
//! Ghostty maps its scrollback pages directly rather than through the
//! allocator it is given, so the resident set is the number that bounds a
//! session; the allocator counts are Conduit's own heap beside it.

const std = @import("std");
const term = @import("term");
const workspace = @import("workspace");
const session = @import("session");
const common = @import("common.zig");

const Io = std.Io;

/// Warnings and errors only: the engine logs every page-capacity change at
/// info, which would bury the summary and cost time inside the measurement.
pub const std_options: std.Options = .{ .log_level = .warn };

const cols: u16 = 160;
const rows: u16 = 50;
const marker = "MEMORY_BENCH_READY";
/// Full-width lines: more than the scrollback keeps, so the history is full.
const line_count = term.ScrollConfig.default_scrollback_lines + 2 * rows;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var out_buffer: [4096]u8 = undefined;
    var out_file = Io.File.stdout().writerStreaming(io, &out_buffer);
    const out = &out_file.interface;
    defer out.flush() catch {};

    var counting: common.CountingAllocator = .init(std.heap.smp_allocator);
    const gpa = counting.allocator();
    const size = try term.GridSize.init(cols, rows);

    const before = common.processMemory(io);
    var owner = try workspace.Workspace.initLocal(io, gpa, "memory-bench", "/tmp", size);
    defer owner.deinit() catch |err| common.note("memory: workspace teardown failed: {s}", .{@errorName(err)});

    var io_buffer: [64 * 1024]u8 = undefined;
    var response_buffer: [term.response_capacity]u8 = undefined;
    var ignored: Ignored = .{};

    const base = common.processMemory(io);
    const base_live = counting.liveBytes();

    var ids: [8]session.SessionId = undefined;
    var started: usize = 0;
    const steps = [_]usize{ 1, 8 };
    for (steps) |target| {
        while (started < target) : (started += 1) {
            ids[started] = try startSession(&owner, size);
        }
        try settle(io, &owner, ids[0..started], &io_buffer, &response_buffer, ignored.sink());

        const now = common.processMemory(io);
        const live = counting.liveBytes();
        var history_rows: usize = 0;
        for (ids[0..started]) |id| {
            const live_session = owner.sessionById(id) orelse return error.SessionNotFound;
            history_rows = @max(history_rows, live_session.terminalConst().viewport().history_rows);
        }
        const per_session_rss = (now.rss -| base.rss) / target;
        const per_session_heap = (live -| base_live) / target;
        var case_buffer: [32]u8 = undefined;
        const case = try std.fmt.bufPrint(&case_buffer, "{d}-session{s}", .{ target, if (target == 1) "" else "s" });
        const record = .{
            .bench = "memory",
            .case = case,
            .sessions = target,
            .grid = .{ cols, rows },
            .scrollback_rows = history_rows,
            .process_rss_bytes = now.rss,
            .process_hwm_bytes = now.hwm,
            .baseline_rss_bytes = base.rss,
            .startup_rss_bytes = before.rss,
            .per_session_rss_bytes = per_session_rss,
            .per_session_rss_mib = @as(f64, @floatFromInt(per_session_rss)) / (1024 * 1024),
            .heap_live_bytes = live,
            .heap_peak_bytes = counting.peakBytes(),
            .per_session_heap_bytes = per_session_heap,
        };
        try common.emit(out, record);
        try out.flush();
        common.note("memory {s}: {d} history rows, RSS {d:.1} MiB ({d:.2} MiB per session), heap live {d:.2} MiB, peak {d:.2} MiB", .{
            case,
            history_rows,
            mib(now.rss),
            record.per_session_rss_mib,
            mib(live),
            mib(counting.peakBytes()),
        });
    }
}

fn mib(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024 * 1024);
}

fn startSession(owner: *workspace.Workspace, size: term.GridSize) !session.SessionId {
    const id = try owner.createSession(.human_terminal, size);
    const script = std.fmt.comptimePrint(
        "yes 'line of a full-width terminal history: the quick brown fox jumps over the lazy dog 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz ~~~~~~~~~~~' | head -n {d}; printf '%s\\n' {s}; exec cat >/dev/null",
        .{ line_count, marker },
    );
    const request = try owner.spawnRequest(id, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .env = &.{ "PATH=/usr/bin:/bin", "TERM=xterm-256color", "LC_ALL=C" },
    });
    try owner.attachChild(id, try owner.contextRef().spawn(request));
    return id;
}

/// Pump until every session shows the marker and has no output left.
fn settle(
    io: Io,
    owner: *workspace.Workspace,
    ids: []const session.SessionId,
    io_buffer: []u8,
    response_buffer: []u8,
    sink: workspace.EventSink,
) !void {
    const deadline = common.nowNs(io) + 60 * std.time.ns_per_s;
    while (common.nowNs(io) < deadline) {
        const result = owner.pump(io_buffer, response_buffer, sink);
        if (result.first_error) |err| return err;
        if (result.bytes_drained != 0) continue;
        var ready = true;
        for (ids) |id| {
            const live = owner.sessionById(id) orelse return error.SessionNotFound;
            try live.terminal().refresh(owner.allocator);
            if (!live.terminalConst().visibleTextContains(marker)) ready = false;
        }
        if (ready and !owner.needsPump()) return;
        const first = owner.sessionById(ids[ids.len - 1]) orelse return error.SessionNotFound;
        if (first.child()) |child| _ = child.waitReadable(10);
    }
    return error.Timeout;
}

const Ignored = struct {
    fn sink(self: *Ignored) workspace.EventSink {
        return .{ .ptr = self, .on_events = ignore };
    }

    fn ignore(_: *anyopaque, _: session.SessionId, _: []const term.Event) void {}
};
