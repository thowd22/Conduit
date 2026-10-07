//! TASK-67 performance budgets, enforced by `zig build bench-check`.
//!
//! Each budget names one metric of one benchmark case and the limit it must
//! not cross. The limits are the reference-hardware measurements recorded in
//! `docs/performance.md` with 25 % headroom already applied (a time or size
//! budget is the measurement x 1.25, a rate budget the measurement / 1.25), so
//! a run fails only on a regression larger than run-to-run noise. Change a
//! number here and in that document together.

/// Whether the measurement must stay at or below the limit (times, bytes) or
/// at or above it (rates).
pub const Direction = enum { at_most, at_least };

pub const Budget = struct {
    bench: []const u8,
    case: []const u8,
    metric: []const u8,
    limit: f64,
    direction: Direction,
    unit: []const u8,
};

pub const all = [_]Budget{
    // Throughput (MiB/s), measured / 1.25. `term` is the engine alone, `grid`
    // adds a real grid redraw at the frame pacer's cadence.
    .{ .bench = "throughput", .case = "plain-16MiB-term", .metric = "mib_per_s", .limit = 75, .direction = .at_least, .unit = "MiB/s" },
    .{ .bench = "throughput", .case = "plain-64MiB-term", .metric = "mib_per_s", .limit = 75, .direction = .at_least, .unit = "MiB/s" },
    .{ .bench = "throughput", .case = "plain-16MiB-grid", .metric = "mib_per_s", .limit = 54, .direction = .at_least, .unit = "MiB/s" },
    .{ .bench = "throughput", .case = "cr-flood-16MiB-term", .metric = "mib_per_s", .limit = 990, .direction = .at_least, .unit = "MiB/s" },
    .{ .bench = "throughput", .case = "sgr-16MiB-term", .metric = "mib_per_s", .limit = 43, .direction = .at_least, .unit = "MiB/s" },
    .{ .bench = "throughput", .case = "sgr-16MiB-grid", .metric = "mib_per_s", .limit = 33, .direction = .at_least, .unit = "MiB/s" },
    .{ .bench = "throughput", .case = "cjk-16MiB-term", .metric = "mib_per_s", .limit = 103, .direction = .at_least, .unit = "MiB/s" },

    // Frame time at 1920x1080 logical (ms, median of 120 frames), CPU side
    // (`submit`, before glFinish), measured x 1.25. A one-row frame measures
    // well under 0.1 ms, where scheduling jitter alone exceeds 25 %, so its
    // budget is a 0.25 ms floor instead.
    .{ .bench = "frame", .case = "1-pane-scale1-full", .metric = "submit_ms_median", .limit = 5.6, .direction = .at_most, .unit = "ms" },
    .{ .bench = "frame", .case = "9-pane-scale1-full", .metric = "submit_ms_median", .limit = 9.3, .direction = .at_most, .unit = "ms" },
    .{ .bench = "frame", .case = "9-pane-scale2-full", .metric = "submit_ms_median", .limit = 9.0, .direction = .at_most, .unit = "ms" },
    .{ .bench = "frame", .case = "9-pane-scale1-one-row", .metric = "submit_ms_median", .limit = 0.25, .direction = .at_most, .unit = "ms" },
    .{ .bench = "frame", .case = "1-pane-scale1-cjk-full", .metric = "submit_ms_median", .limit = 6.1, .direction = .at_most, .unit = "ms" },

    // Startup to the first prompt through the real app (ms, median of 5).
    .{ .bench = "startup", .case = "launch-to-prompt", .metric = "prompt_ms_median", .limit = 300, .direction = .at_most, .unit = "ms" },

    // Resident memory per idle 160x50 session with a full scrollback (MiB).
    .{ .bench = "memory", .case = "1-session", .metric = "per_session_rss_mib", .limit = 18.4, .direction = .at_most, .unit = "MiB" },
    .{ .bench = "memory", .case = "8-sessions", .metric = "per_session_rss_mib", .limit = 17.8, .direction = .at_most, .unit = "MiB" },
};
