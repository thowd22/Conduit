//! Shared helpers for Conduit's benchmark programs (TASK-67).
//!
//! Every benchmark prints one JSON object per measured case on its own line to
//! stdout, and a short human summary to stderr. `bench/runner.zig` collects the
//! lines, writes them to `--json=<path>` and, in check mode, compares them with
//! `bench/budgets.zig`. Inputs are generated here from fixed patterns, so two
//! runs on one machine feed byte-identical streams.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Monotonic nanoseconds for interval timing.
pub fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

/// CPU time this process has used, in nanoseconds.
pub fn cpuNs(io: Io) i96 {
    return Io.Clock.cpu_process.now(io).nanoseconds;
}

/// Seconds between two `nowNs` readings.
pub fn seconds(start: i96, end: i96) f64 {
    return @as(f64, @floatFromInt(end - start)) / std.time.ns_per_s;
}

/// Milliseconds between two `nowNs` readings.
pub fn millis(start: i96, end: i96) f64 {
    return @as(f64, @floatFromInt(end - start)) / std.time.ns_per_ms;
}

/// Write one benchmark record as a single JSON line. The caller flushes.
pub fn emit(out: *Io.Writer, record: anytype) !void {
    try out.print("{f}\n", .{std.json.fmt(record, .{})});
}

/// Print a line of the human summary to stderr.
pub fn note(comptime format: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    stderr.writer.print(format ++ "\n", args) catch return;
    stderr.writer.flush() catch return;
}

/// The middle value of `values`, which is sorted in place.
pub fn median(values: []f64) f64 {
    std.debug.assert(values.len != 0);
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const mid = values.len / 2;
    if (values.len % 2 == 1) return values[mid];
    return (values[mid - 1] + values[mid]) / 2.0;
}

/// The `p`th percentile (0..1) of `values`, which is sorted in place.
pub fn percentile(values: []f64, p: f64) f64 {
    std.debug.assert(values.len != 0);
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const rank = p * @as(f64, @floatFromInt(values.len - 1));
    const index: usize = @intFromFloat(@round(rank));
    return values[@min(index, values.len - 1)];
}

/// The kinds of deterministic terminal output the throughput benchmark feeds.
pub const Workload = enum {
    /// 79 printable ASCII columns and a CRLF: `cat` of a source file.
    plain,
    /// Records that overwrite one row with a carriage return: a progress bar
    /// or `yes | tr '\n' '\r'`, which never scrolls.
    cr_flood,
    /// Every word in its own 256-colour SGR plus bold/underline toggles: a
    /// coloured compiler log or `ls --color`.
    sgr,
    /// Double-width CJK text: every glyph owns two cells.
    cjk,

    pub fn label(self: Workload) []const u8 {
        return switch (self) {
            .plain => "plain",
            .cr_flood => "cr-flood",
            .sgr => "sgr",
            .cjk => "cjk",
        };
    }
};

/// Fill `out` with `workload` output, repeating a fixed line pattern. Returns
/// how many line terminators (LF or CR) the buffer holds, which is what
/// "lines per second" divides by.
pub fn generate(workload: Workload, out: []u8) usize {
    var line_buffer: [1024]u8 = undefined;
    var filled: usize = 0;
    var lines: usize = 0;
    var index: usize = 0;
    while (filled < out.len) : (index += 1) {
        // The longest line (SGR) is under 400 bytes, so a 1 KiB buffer cannot overflow; the
        // generator test below fills every workload through it.
        const line = makeLine(workload, index, &line_buffer) catch unreachable;
        const take = @min(line.len, out.len - filled);
        @memcpy(out[filled..][0..take], line[0..take]);
        filled += take;
        if (take == line.len) lines += 1;
    }
    return lines;
}

fn makeLine(workload: Workload, index: usize, buffer: []u8) Io.Writer.Error![]const u8 {
    var writer: Io.Writer = .fixed(buffer);
    switch (workload) {
        .plain => {
            try writer.print("{d:0>8}: ", .{index});
            const text = "the quick brown fox jumps over the lazy dog 0123456789 ABCDEFGHIJKLMNOPQRSTUV";
            const used = writer.end;
            try writer.writeAll(text[0 .. 79 - used]);
            try writer.writeAll("\r\n");
        },
        .cr_flood => {
            try writer.print("progress {d:0>8} 0123456789abcdef0123456789abcdef0123456789\r", .{index});
        },
        .sgr => {
            const words = [_][]const u8{ "error", "warning", "note", "src/term.zig", "42:7", "expected", "found", "here" };
            var column: usize = 0;
            var word: usize = 0;
            while (column < 70) : (word += 1) {
                const text = words[(index + word) % words.len];
                const color: u8 = @intCast((index * 7 + word * 13) % 256);
                const attribute: []const u8 = switch (word % 3) {
                    0 => "1;",
                    1 => "4;",
                    else => "",
                };
                try writer.print("\x1b[{s}38;5;{d}m{s}\x1b[0m ", .{ attribute, color, text });
                column += text.len + 1;
            }
            try writer.writeAll("\r\n");
        },
        .cjk => {
            // 39 wide glyphs (78 columns), cycling through kanji and kana.
            const glyphs = "漢字仮名交じり文端末描画速度試験日本語中文한국어表示確認";
            var view = std.unicode.Utf8View.initUnchecked(glyphs);
            var count: usize = 0;
            var start: usize = index % 7;
            var iterator = view.iterator();
            while (start > 0) : (start -= 1) _ = iterator.nextCodepointSlice();
            while (count < 39) : (count += 1) {
                const slice = iterator.nextCodepointSlice() orelse blk: {
                    iterator = view.iterator();
                    break :blk iterator.nextCodepointSlice().?;
                };
                try writer.writeAll(slice);
            }
            try writer.writeAll("\r\n");
        },
    }
    return writer.buffered();
}

/// Process memory, read from `/proc/self/status` on Linux. Zero elsewhere.
pub const ProcessMemory = struct {
    /// Resident set size now, in bytes.
    rss: u64 = 0,
    /// Peak resident set size, in bytes.
    hwm: u64 = 0,
};

/// Read the process's current and peak resident set size.
pub fn processMemory(io: Io) ProcessMemory {
    if (builtin.os.tag != .linux) return .{};
    var buffer: [8192]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, "/proc/self/status", &buffer) catch return .{};
    return .{
        .rss = statusKib(text, "VmRSS:") * 1024,
        .hwm = statusKib(text, "VmHWM:") * 1024,
    };
}

fn statusKib(text: []const u8, key: []const u8) u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        var fields = std.mem.tokenizeAny(u8, line[key.len..], " \t");
        const value = fields.next() orelse return 0;
        return std.fmt.parseInt(u64, value, 10) catch 0;
    }
    return 0;
}

/// An allocator wrapper that counts live bytes and their high-water mark.
///
/// Counters are atomics so a PTY reader thread allocating through the same
/// allocator cannot tear them. The engine's page memory is mmapped directly
/// by Ghostty rather than requested from this allocator, which is why the
/// memory benchmark reports RSS beside these counts.
pub const CountingAllocator = struct {
    child: Allocator,
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),
    allocations: std.atomic.Value(usize) = .init(0),

    pub fn init(child: Allocator) CountingAllocator {
        return .{ .child = child };
    }

    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn liveBytes(self: *const CountingAllocator) usize {
        return self.live.load(.monotonic);
    }

    pub fn peakBytes(self: *const CountingAllocator) usize {
        return self.peak.load(.monotonic);
    }

    /// Restart the high-water mark from the current live count.
    pub fn resetPeak(self: *CountingAllocator) void {
        self.peak.store(self.live.load(.monotonic), .monotonic);
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn grew(self: *CountingAllocator, bytes: usize) void {
        const now = self.live.fetchAdd(bytes, .monotonic) + bytes;
        var seen = self.peak.load(.monotonic);
        while (now > seen) {
            seen = self.peak.cmpxchgWeak(seen, now, .monotonic, .monotonic) orelse return;
        }
    }

    fn shrank(self: *CountingAllocator, bytes: usize) void {
        _ = self.live.fetchSub(bytes, .monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = self.allocations.fetchAdd(1, .monotonic);
        self.grew(len);
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) self.grew(new_len - memory.len) else self.shrank(memory.len - new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > memory.len) self.grew(new_len - memory.len) else self.shrank(memory.len - new_len);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.shrank(memory.len);
    }
};

/// Parse `--name=value` from `args`, or null.
pub fn flag(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) continue;
        const rest = arg[2..];
        if (!std.mem.startsWith(u8, rest, name)) continue;
        if (rest.len == name.len) return "";
        if (rest[name.len] == '=') return rest[name.len + 1 ..];
    }
    return null;
}

/// Collect the process arguments into `allocator`-owned memory.
pub fn collectArgs(allocator: Allocator, source: std.process.Args) ![]const []const u8 {
    var iterator = try std.process.Args.Iterator.initAllocator(source, allocator);
    defer iterator.deinit();
    var args: std.ArrayList([]const u8) = .empty;
    while (iterator.next()) |arg| try args.append(allocator, try allocator.dupe(u8, arg));
    return args.items;
}

test "generated workloads are deterministic and count their line ends" {
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    for (std.enums.values(Workload)) |workload| {
        const lines_a = generate(workload, &a);
        const lines_b = generate(workload, &b);
        try std.testing.expectEqual(lines_a, lines_b);
        try std.testing.expectEqualSlices(u8, &a, &b);
        try std.testing.expect(lines_a > 0);
    }
}

test "plain lines are exactly 79 columns and a CRLF" {
    var buffer: [81 * 3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), generate(.plain, &buffer));
    try std.testing.expectEqualStrings("\r\n", buffer[79..81]);
    try std.testing.expectEqualStrings("00000001: ", buffer[81..91]);
}

test "the counting allocator tracks live bytes and the high-water mark" {
    var counting: CountingAllocator = .init(std.testing.allocator);
    const gpa = counting.allocator();
    const first = try gpa.alloc(u8, 100);
    const second = try gpa.alloc(u8, 50);
    try std.testing.expectEqual(@as(usize, 150), counting.liveBytes());
    gpa.free(first);
    try std.testing.expectEqual(@as(usize, 50), counting.liveBytes());
    try std.testing.expectEqual(@as(usize, 150), counting.peakBytes());
    gpa.free(second);
    try std.testing.expectEqual(@as(usize, 0), counting.liveBytes());
}

test "median and percentile sort and pick" {
    var values = [_]f64{ 5, 1, 3, 2, 4 };
    try std.testing.expectEqual(@as(f64, 3), median(&values));
    var even = [_]f64{ 4, 1, 3, 2 };
    try std.testing.expectEqual(@as(f64, 2.5), median(&even));
    var tail = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try std.testing.expectEqual(@as(f64, 10), percentile(&tail, 0.99));
}

test "every generated line fits the generator's line buffer" {
    var buffer: [1024]u8 = undefined;
    for (std.enums.values(Workload)) |workload| {
        for (0..10_000) |index| {
            const line = try makeLine(workload, index, &buffer);
            try std.testing.expect(line.len < 400);
        }
    }
}
