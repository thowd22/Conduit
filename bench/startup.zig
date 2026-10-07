//! Startup benchmark (TASK-67): wall time from `conduit-test launch` to the
//! first shell prompt drawn in the real app, median of five isolated runs.
//!
//! Each run is a fresh private root, so the app starts with no config, state
//! or font cache of its own, and the child is a `/bin/sh` with a fixed prompt
//! and no rc files. Two times are taken from the same start: `launch` returns
//! once the test driver answers an `inspect` (the window, GL context, fonts and
//! workspace exist), and `prompt` once `wait-for terminal-text` sees the
//! prompt in the terminal. `launch` polls the driver every 20 ms, which is the
//! resolution of the first number.

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

const runs = 5;
/// The prompt is spelled with an empty quoted pair inside it, so the command
/// line itself can never satisfy the wait: only the expanded `PS1` can.
const shell_command = "PS1='BENCH''> '; ENV=/dev/null; export PS1 ENV; exec /bin/sh -i";
const prompt = "BENCH> ";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try common.collectArgs(init.arena.allocator(), init.minimal.args);
    const conduit_test = common.flag(args, "conduit-test") orelse return error.MissingConduitTestPath;
    // The app binary to launch, so the benchmark measures the optimised build
    // rather than whatever `conduit-test` would find beside itself.
    const conduit = common.flag(args, "conduit") orelse return error.MissingConduitPath;

    var out_buffer: [4096]u8 = undefined;
    var out_file = Io.File.stdout().writerStreaming(io, &out_buffer);
    const out = &out_file.interface;
    defer out.flush() catch {};

    var launch_ms: [runs]f64 = undefined;
    var prompt_ms: [runs]f64 = undefined;
    for (0..runs) |index| {
        const timing = try runOnce(gpa, io, conduit_test, conduit);
        launch_ms[index] = timing.launch_ms;
        prompt_ms[index] = timing.prompt_ms;
        common.note("startup run {d}: driver ready {d:.0} ms, prompt {d:.0} ms", .{ index + 1, timing.launch_ms, timing.prompt_ms });
    }
    var prompt_sorted = prompt_ms;
    var launch_sorted = launch_ms;
    const record = .{
        .bench = "startup",
        .case = "launch-to-prompt",
        .runs = runs,
        .launch_ms_median = common.median(&launch_sorted),
        .prompt_ms_median = common.median(&prompt_sorted),
        .prompt_ms_max = prompt_sorted[runs - 1],
        .prompt_ms = prompt_ms,
    };
    try common.emit(out, record);
    common.note("startup: median driver ready {d:.0} ms, median prompt {d:.0} ms", .{ record.launch_ms_median, record.prompt_ms_median });
}

const Timing = struct { launch_ms: f64, prompt_ms: f64 };

fn runOnce(gpa: std.mem.Allocator, io: Io, conduit_test: []const u8, conduit: []const u8) !Timing {
    // A short private root under /tmp: the driver's Unix socket path must fit
    // `sun_path`, which a root inside a deep checkout may not.
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const hex = std.fmt.bytesToHex(nonce, .lower);
    var root_buffer: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, "/tmp/conduit-bench-{s}", .{&hex});
    try Dir.cwd().createDir(io, root, if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700));
    defer Dir.cwd().deleteTree(io, root) catch |err| common.note("startup: could not remove {s}: {s}", .{ root, @errorName(err) });

    var root_arg_buffer: [96]u8 = undefined;
    const root_arg = try std.fmt.bufPrint(&root_arg_buffer, "--root={s}", .{root});

    var conduit_arg_buffer: [std.fs.max_path_bytes + 16]u8 = undefined;
    const conduit_arg = try std.fmt.bufPrint(&conduit_arg_buffer, "--conduit={s}", .{conduit});

    const started = common.nowNs(io);
    const launched = try run(gpa, io, &.{
        conduit_test, root_arg,    "launch",                      "--width=960", "--height=640",
        "--scale=1",  conduit_arg, "--command=" ++ shell_command,
    });
    defer gpa.free(launched);
    const ready = common.nowNs(io);
    const run_id = std.mem.trim(u8, launched, " \t\r\n");
    var run_arg_buffer: [128]u8 = undefined;
    const run_arg = try std.fmt.bufPrint(&run_arg_buffer, "--run={s}", .{run_id});
    defer {
        const quit = run(gpa, io, &.{ conduit_test, root_arg, run_arg, "quit" }) catch null;
        if (quit) |bytes| gpa.free(bytes);
    }

    const waited = try run(gpa, io, &.{ conduit_test, root_arg, run_arg, "wait-for", "terminal-text", prompt, "10000" });
    gpa.free(waited);
    const prompted = common.nowNs(io);
    return .{ .launch_ms = common.millis(started, ready), .prompt_ms = common.millis(started, prompted) };
}

/// Run a `conduit-test` command and return its stdout; any failure is an error.
fn run(gpa: std.mem.Allocator, io: Io, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
    });
    defer gpa.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |status| status == 0,
        else => false,
    };
    if (!ok) {
        common.note("startup: {s} {s} failed: {s}", .{ argv[0], argv[argv.len - 1], result.stderr[0..@min(result.stderr.len, 2048)] });
        gpa.free(result.stdout);
        return error.ConduitTestFailed;
    }
    return result.stdout;
}
