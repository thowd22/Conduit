//! `conduit-bench`: runs Conduit's benchmark programs and checks budgets
//! (TASK-67). `zig build bench` and `zig build bench-check` invoke it.
//!
//! Every benchmark runs as its own process, so one benchmark's allocations
//! and resident pages never show up in another's numbers. Their JSON lines are
//! echoed to stdout and, with `--json=<path>`, written to that file after a
//! `meta` line that records the machine. The GPU benchmarks and the startup
//! benchmark need a display: without `DISPLAY` or `WAYLAND_DISPLAY` they are
//! run under `xvfb-run -a` when it is installed. `--check` compares the records
//! with `budgets.zig` and exits non-zero on any breach or missing measurement.

const std = @import("std");
const builtin = @import("builtin");
const budgets = @import("budgets.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const usage =
    \\conduit-bench — usage
    \\
    \\  conduit-bench --throughput=<exe> --frame=<exe> --memory=<exe> --startup=<exe>
    \\                --conduit-test=<exe> --conduit=<exe>
    \\                [--json=<path>] [--check] [--quick] [--only=<name>[,<name>...]]
    \\
    \\  Names: throughput, frame, memory, startup.
    \\
;

const Bench = struct {
    name: []const u8,
    needs_display: bool,
};

const benches = [_]Bench{
    .{ .name = "throughput", .needs_display = true },
    .{ .name = "memory", .needs_display = false },
    .{ .name = "frame", .needs_display = true },
    .{ .name = "startup", .needs_display = true },
};

const max_output_bytes = 4 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try common.collectArgs(arena, init.minimal.args);
    const status = run(init, arena, args) catch |err| {
        common.note("conduit-bench: {s}\n\n{s}", .{ @errorName(err), usage });
        std.process.exit(2);
    };
    if (status != 0) std.process.exit(status);
}

fn run(init: std.process.Init, arena: Allocator, args: []const []const u8) !u8 {
    const io = init.io;
    const check = common.flag(args, "check") != null;
    const quick = common.flag(args, "quick") != null;
    const only = common.flag(args, "only");
    const json_path = common.flag(args, "json");
    const conduit_test = common.flag(args, "conduit-test") orelse return error.MissingConduitTest;
    const conduit = common.flag(args, "conduit") orelse return error.MissingConduit;

    const has_display = init.environ_map.get("DISPLAY") != null or init.environ_map.get("WAYLAND_DISPLAY") != null;
    const wrap_xvfb = builtin.os.tag == .linux and !has_display and hasXvfbRun(io);

    var records: std.ArrayList([]const u8) = .empty;
    try records.append(arena, try metaRecord(arena, io, wrap_xvfb));

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;
    try out.print("{s}\n", .{records.items[0]});
    try out.flush();

    var failed_runs: usize = 0;
    for (benches) |bench| {
        if (only) |names| if (!listed(names, bench.name)) continue;
        const exe = common.flag(args, bench.name) orelse return error.MissingBenchmarkExecutable;
        var argv: std.ArrayList([]const u8) = .empty;
        if (bench.needs_display and wrap_xvfb) {
            try argv.appendSlice(arena, &.{ "xvfb-run", "-a", "-s", "-screen 0 1920x1080x24" });
        }
        try argv.append(arena, exe);
        if (quick) try argv.append(arena, "--quick");
        if (std.mem.eql(u8, bench.name, "startup")) {
            try argv.append(arena, try std.fmt.allocPrint(arena, "--conduit-test={s}", .{conduit_test}));
            try argv.append(arena, try std.fmt.allocPrint(arena, "--conduit={s}", .{conduit}));
        }
        common.note("conduit-bench: running {s}{s}", .{ bench.name, if (bench.needs_display and wrap_xvfb) " under xvfb-run" else "" });
        const output = runBench(arena, io, argv.items) catch |err| {
            common.note("conduit-bench: {s} failed: {s}", .{ bench.name, @errorName(err) });
            failed_runs += 1;
            continue;
        };
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0) continue;
            try records.append(arena, trimmed);
            try out.print("{s}\n", .{trimmed});
        }
        try out.flush();
    }

    if (json_path) |path| try writeRecords(io, path, records.items);

    var breaches: usize = 0;
    if (check) breaches = try checkBudgets(arena, records.items[1..], only, quick);
    if (failed_runs != 0) common.note("conduit-bench: {d} benchmark(s) failed to run", .{failed_runs});
    if (check) common.note("conduit-bench: budget check {s} ({d} breach(es))", .{ if (breaches == 0 and failed_runs == 0) "PASS" else "FAIL", breaches });
    return if (failed_runs == 0 and breaches == 0) 0 else 1;
}

fn listed(names: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, names, ',');
    while (it.next()) |entry| if (std.mem.eql(u8, entry, name)) return true;
    return false;
}

fn hasXvfbRun(io: Io) bool {
    for ([_][]const u8{ "/usr/bin/xvfb-run", "/usr/local/bin/xvfb-run", "/bin/xvfb-run" }) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch continue;
        return true;
    }
    return false;
}

fn runBench(arena: Allocator, io: Io, argv: []const []const u8) ![]const u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer child.kill(io);
    var buffer: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buffer);
    const output = try reader.interface.allocRemaining(arena, .limited(max_output_bytes));
    const term = try child.wait(io);
    switch (term) {
        .exited => |status| if (status != 0) return error.BenchmarkFailed,
        else => return error.BenchmarkCrashed,
    }
    return output;
}

fn metaRecord(arena: Allocator, io: Io, xvfb: bool) ![]const u8 {
    var cpu_model: []const u8 = "unknown";
    if (builtin.os.tag == .linux) {
        // procfs reports a size of zero, so read a fixed prefix: the first
        // processor's block holds the model name.
        const buffer = try arena.alloc(u8, 8192);
        if (std.Io.Dir.cwd().readFile(io, "/proc/cpuinfo", buffer)) |text| {
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (!std.mem.startsWith(u8, line, "model name")) continue;
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                cpu_model = std.mem.trim(u8, line[colon + 1 ..], " \t");
                break;
            }
        } else |_| {}
    }
    const memory = std.process.totalSystemMemory() catch 0;
    const cores = std.Thread.getCpuCount() catch 0;
    return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .bench = "meta",
        .optimize = @tagName(builtin.mode),
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .cpu = cpu_model,
        .cores = cores,
        .memory_bytes = memory,
        .xvfb = xvfb,
    }, .{})});
}

fn writeRecords(io: Io, path: []const u8, records: []const []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    for (records) |record| try writer.interface.print("{s}\n", .{record});
    try writer.interface.flush();
    common.note("conduit-bench: wrote {d} record(s) to {s}", .{ records.len, path });
}

/// Compare every budget with its measurement. A budget whose benchmark ran
/// but produced no such case or metric is a breach, because a renamed case
/// would otherwise retire its budget silently.
fn checkBudgets(arena: Allocator, records: []const []const u8, only: ?[]const u8, quick: bool) !usize {
    var breaches: usize = 0;
    for (budgets.all) |budget| {
        if (only) |names| if (!listed(names, budget.bench)) continue;
        if (quick and std.mem.indexOf(u8, budget.case, "64MiB") != null) continue;
        const measured = findMetric(arena, records, budget) orelse {
            common.note("BUDGET MISSING {s} {s} {s}: no measurement", .{ budget.bench, budget.case, budget.metric });
            breaches += 1;
            continue;
        };
        const ok = switch (budget.direction) {
            .at_most => measured <= budget.limit,
            .at_least => measured >= budget.limit,
        };
        common.note("budget {s} {s} {s} {s} {d:.2} {s}: measured {d:.2}", .{
            if (ok) "ok  " else "FAIL",
            budget.bench,
            budget.case,
            if (budget.direction == .at_most) "<=" else ">=",
            budget.limit,
            budget.unit,
            measured,
        });
        if (!ok) breaches += 1;
    }
    return breaches;
}

fn findMetric(arena: Allocator, records: []const []const u8, budget: budgets.Budget) ?f64 {
    for (records) |line| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        if (parsed != .object) continue;
        const object = parsed.object;
        const bench = object.get("bench") orelse continue;
        const case = object.get("case") orelse continue;
        if (bench != .string or case != .string) continue;
        if (!std.mem.eql(u8, bench.string, budget.bench) or !std.mem.eql(u8, case.string, budget.case)) continue;
        const value = object.get(budget.metric) orelse return null;
        return switch (value) {
            .float => |number| number,
            .integer => |number| @floatFromInt(number),
            .number_string => |text| std.fmt.parseFloat(f64, text) catch null,
            else => null,
        };
    }
    return null;
}

test "a budget is found by bench, case and metric" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const records = [_][]const u8{
        "{\"bench\":\"frame\",\"case\":\"9-pane-scale1-full\",\"submit_ms_median\":3.5}",
        "{\"bench\":\"memory\",\"case\":\"1-session\",\"per_session_rss_mib\":12}",
    };
    const frame: budgets.Budget = .{ .bench = "frame", .case = "9-pane-scale1-full", .metric = "submit_ms_median", .limit = 4, .direction = .at_most, .unit = "ms" };
    try std.testing.expectEqual(@as(?f64, 3.5), findMetric(arena_state.allocator(), &records, frame));
    const memory: budgets.Budget = .{ .bench = "memory", .case = "1-session", .metric = "per_session_rss_mib", .limit = 4, .direction = .at_most, .unit = "MiB" };
    try std.testing.expectEqual(@as(?f64, 12), findMetric(arena_state.allocator(), &records, memory));
    const missing: budgets.Budget = .{ .bench = "frame", .case = "nope", .metric = "submit_ms_median", .limit = 4, .direction = .at_most, .unit = "ms" };
    try std.testing.expectEqual(@as(?f64, null), findMetric(arena_state.allocator(), &records, missing));
}

test "every budget has a positive limit" {
    for (budgets.all) |budget| try std.testing.expect(budget.limit > 0);
}

test "only lists are comma separated names" {
    try std.testing.expect(listed("frame,memory", "memory"));
    try std.testing.expect(!listed("frame,memory", "startup"));
}

test "a measurement past its budget, or a missing one, is a breach" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const within = [_][]const u8{
        "{\"bench\":\"memory\",\"case\":\"1-session\",\"per_session_rss_mib\":1}",
        "{\"bench\":\"memory\",\"case\":\"8-sessions\",\"per_session_rss_mib\":1}",
    };
    try std.testing.expectEqual(@as(usize, 0), try checkBudgets(arena, &within, "memory", false));
    const over = [_][]const u8{
        "{\"bench\":\"memory\",\"case\":\"1-session\",\"per_session_rss_mib\":1000}",
    };
    // One over its limit and one with no measurement at all.
    try std.testing.expectEqual(@as(usize, 2), try checkBudgets(arena, &over, "memory", false));
}
