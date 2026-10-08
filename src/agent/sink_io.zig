//! The IO under the sink-based agent side channels (TASK-61, decision-7
//! rule 5, decision-8 "Remote file reads, commands and agents").
//!
//! A Claude Code hook relay and Conduit's Pi extension report by appending
//! JSON lines to a file in a private per-agent *sink* directory and read
//! Conduit's permission answers from files there. In a Local workspace the
//! sink is on this machine; in an SSH workspace it is on the remote host,
//! where the harness runs, and every access crosses the workspace's
//! ExecutionContext. `SinkIo` is the one seam both cases go through, so the
//! adapters parse harness data and never decide where a file lives:
//!
//! - `readAt` follows an append-only file from an offset (the event sink,
//!   a transcript);
//! - `readFile`, `stat` and `listDir` find a hand-started session's registry
//!   record and transcript;
//! - `writeFile` publishes a permission answer or stages a launch file
//!   atomically (temporary file and rename, so a polling reader never sees a
//!   prefix), and `makePrivateDir` creates the sink 0700.
//!
//! Nothing here is harness-specific; the paths it is given are.
//!
//! **Local** (`SinkIo.local`) acts on this machine's file system through
//! `workspace.localFiles()`, the Local context's own stateless file
//! functions. **Remote** (`SinkIo.forContext` with an SSH or WSL `Ref`)
//! calls the borrowed workspace context; each call is one or a few exec
//! channels over the workspace's connection. Since an agent's IO worker
//! polls every 50 ms, a remote `readAt` that found nothing new does not ask
//! the remote side about that path again for
//! `Options.idle_read_interval_ms`; a read that found bytes is never held
//! back, so a burst of events streams at channel speed. That bounds an idle
//! remote agent to about two exec channels per second per followed file
//! (its event sink and its transcript) instead of forty. A `watch` would not
//! help: the remote watch loop fingerprints every two seconds.
//!
//! Errors: a missing file or directory is `null`, not an error, because a
//! sink file may not exist until the harness first writes it. A file larger
//! than the caller's buffer is `NoSpaceLeft`. Everything else, including a
//! lost connection, is `Disconnected`.
//!
//! Threads: a `SinkIo` belongs to one adapter and is used by that adapter's
//! single IO worker at a time (adapter.zig); the read throttle is
//! unsynchronised state for that reason. The borrowed context must outlive
//! it. Never called on the render thread: a remote call blocks on the
//! connection.
//!
//! Safety: paths come from the adapters, which validate every identifier
//! that reaches one; contents are never logged, and paths not at all.

const std = @import("std");
const workspace = @import("workspace");

const Io = std.Io;
const Ref = workspace.ExecutionContext.Ref;
const log = std.log.scoped(.agent_sink);

/// Failures a sink operation reports to an adapter; every member is also an
/// `adapter.Error`.
pub const Error = error{
    /// The file is larger than the caller's buffer.
    NoSpaceLeft,
    OutOfMemory,
    /// The file system, or the connection under it, failed.
    Disconnected,
};

/// Mode bits for the data files the adapters write (owner only).
pub const private_file_mode: u32 = 0o600;

/// How long a remote `readAt` that found nothing skips asking again.
pub const default_idle_read_interval_ms: u32 = 500;

pub const Options = struct {
    /// See the file comment. Zero asks the context on every call.
    idle_read_interval_ms: u32 = default_idle_read_interval_ms,
};

/// Where an agent's sink lives and how to reach it. A plain value: it holds
/// the borrowed context and the read throttle, no other pointers.
pub const SinkIo = struct {
    ref: Ref,
    remote: bool,
    idle_read_interval_ms: u32,
    idle: [idle_slots]Idle = @splat(.{}),
    next_slot: usize = 0,

    const idle_slots = 4;

    /// A followed path that was idle at `since_ms`.
    const Idle = struct {
        hash: u64 = 0,
        since_ms: i64 = 0,
        used: bool = false,
    };

    /// This machine's file system.
    pub fn local() SinkIo {
        return .{ .ref = workspace.localFiles(), .remote = false, .idle_read_interval_ms = 0 };
    }

    /// The seam for a workspace's context: Local when it is null or a Local
    /// context, so a Local workspace keeps reading this machine's files
    /// directly; otherwise every call goes through `context`.
    pub fn forContext(context: ?Ref, options: Options) SinkIo {
        const ref = context orelse return local();
        if (!ref.kind().isRemote()) return local();
        return .{ .ref = ref, .remote = true, .idle_read_interval_ms = options.idle_read_interval_ms };
    }

    /// Whether the files live on another machine.
    pub fn isRemote(self: *const SinkIo) bool {
        return self.remote;
    }

    /// Read up to `buffer.len` bytes of `path` from `offset`: how many were
    /// read (0 when nothing new is there yet), or null when the file does
    /// not exist yet.
    pub fn readAt(self: *SinkIo, io: Io, path: []const u8, offset: u64, buffer: []u8) Error!?usize {
        const hash = std.hash.Wyhash.hash(0, path);
        const now = if (self.idle_read_interval_ms == 0) 0 else Io.Clock.awake.now(io).toMilliseconds();
        const slot = self.slotFor(hash);
        if (slot) |idle| {
            if (now - idle.since_ms < self.idle_read_interval_ms) return 0;
        }
        const read = self.ref.readFileAt(io, path, offset, buffer) catch |err| switch (err) {
            error.NotFound => {
                self.markIdle(hash, now);
                return null;
            },
            else => return mapError("follow a file", err),
        };
        if (read == 0) {
            self.markIdle(hash, now);
        } else if (slot) |idle| {
            idle.used = false;
        }
        return read;
    }

    /// The whole of a small file, in `buffer`; null when it does not exist.
    pub fn readFile(self: *SinkIo, io: Io, path: []const u8, buffer: []u8) Error!?[]u8 {
        return self.ref.readFile(io, path, buffer) catch |err| switch (err) {
            error.NotFound => null,
            else => mapError("read a file", err),
        };
    }

    /// What `path` is, following links; null when it does not exist.
    pub fn stat(self: *SinkIo, io: Io, path: []const u8) Error!?workspace.PathStat {
        return self.ref.statPath(io, path) catch |err| switch (err) {
            error.NotFound => null,
            else => mapError("stat a path", err),
        };
    }

    /// Visit the entries of the directory at `path` (kinds follow links);
    /// false when it does not exist. The visitor bounds the listing.
    pub fn listDir(self: *SinkIo, io: Io, path: []const u8, visitor: workspace.DirVisitor) Error!bool {
        self.ref.listDir(io, path, visitor) catch |err| switch (err) {
            error.NotFound => return false,
            else => return mapError("list a directory", err),
        };
        return true;
    }

    /// Replace `path` with `bytes` atomically, with mode `mode`; missing
    /// parents are created private. At most `workspace.max_write_bytes`.
    pub fn writeFile(self: *SinkIo, io: Io, path: []const u8, bytes: []const u8, mode: u32) Error!void {
        self.ref.writeFile(io, path, bytes, mode) catch |err| return mapError("write a file", err);
    }

    /// Create `path` and its missing parents 0700, and make `path` 0700.
    pub fn makePrivateDir(self: *SinkIo, io: Io, path: []const u8) Error!void {
        self.ref.makePrivateDir(io, path) catch |err| return mapError("create a private directory", err);
    }

    fn slotFor(self: *SinkIo, hash: u64) ?*Idle {
        for (&self.idle) |*idle| {
            if (idle.used and idle.hash == hash) return idle;
        }
        return null;
    }

    fn markIdle(self: *SinkIo, hash: u64, now: i64) void {
        if (self.idle_read_interval_ms == 0) return;
        const idle = self.slotFor(hash) orelse claim: {
            for (&self.idle) |*free| {
                if (!free.used) break :claim free;
            }
            // More followed files than slots: reuse round-robin. A path that
            // loses its slot is merely asked again sooner.
            const reused = &self.idle[self.next_slot];
            self.next_slot = (self.next_slot + 1) % idle_slots;
            break :claim reused;
        };
        idle.* = .{ .hash = hash, .since_ms = now, .used = true };
    }
};

/// Map a context failure (other than a missing path, which callers turn
/// into null) onto `Error`.
fn mapError(what: []const u8, err: workspace.FsError) Error {
    return switch (err) {
        error.TooLarge => error.NoSpaceLeft,
        error.OutOfMemory => error.OutOfMemory,
        else => {
            log.debug("cannot {s}: {s}", .{ what, @errorName(err) });
            return error.Disconnected;
        },
    };
}

// Tests ------------------------------------------------------------------------

const testing = std.testing;

/// A remote-looking context that serves one in-memory file and counts every
/// call, so the throttle and error mapping can be checked without SSH.
const ScriptedContext = struct {
    content: std.ArrayList(u8) = .empty,
    exists: bool = true,
    fail: ?workspace.FsError = null,
    reads: usize = 0,
    writes: usize = 0,
    written_path: [128]u8 = undefined,
    written_path_len: usize = 0,
    written_mode: u32 = 0,
    dirs: usize = 0,

    const vtable: workspace.ExecutionContext.VTable = .{
        .spawn = spawn,
        .kind = kind,
        .destroy = destroy,
        .read_file_at = readFileAt,
        .write_file = writeFile,
        .make_private_dir = makePrivateDir,
    };

    fn ref(self: *ScriptedContext) Ref {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const spawn_fn = @typeInfo(@typeInfo(workspace.ExecutionContext.SpawnFn).pointer.child).@"fn";

    fn spawn(_: *anyopaque, _: spawn_fn.params[1].type.?) spawn_fn.return_type.? {
        return error.Closed;
    }

    fn kind(_: *const anyopaque) workspace.ExecutionContextKind {
        return .ssh;
    }

    fn destroy(_: *anyopaque) void {}

    fn readFileAt(ptr: *anyopaque, _: Io, _: []const u8, offset: u64, buffer: []u8) workspace.FsError!usize {
        const self: *ScriptedContext = @ptrCast(@alignCast(ptr));
        self.reads += 1;
        if (self.fail) |err| return err;
        if (!self.exists) return error.NotFound;
        if (offset >= self.content.items.len) return 0;
        const rest = self.content.items[@intCast(offset)..];
        const n = @min(rest.len, buffer.len);
        @memcpy(buffer[0..n], rest[0..n]);
        return n;
    }

    fn writeFile(ptr: *anyopaque, _: Io, path: []const u8, bytes: []const u8, mode: u32) workspace.FsError!void {
        const self: *ScriptedContext = @ptrCast(@alignCast(ptr));
        self.writes += 1;
        if (self.fail) |err| return err;
        @memcpy(self.written_path[0..path.len], path);
        self.written_path_len = path.len;
        self.written_mode = mode;
        self.content.clearRetainingCapacity();
        self.content.appendSlice(testing.allocator, bytes) catch return error.OutOfMemory;
    }

    fn makePrivateDir(ptr: *anyopaque, _: Io, _: []const u8) workspace.FsError!void {
        const self: *ScriptedContext = @ptrCast(@alignCast(ptr));
        self.dirs += 1;
        if (self.fail) |err| return err;
    }
};

test "a Local or missing context means this machine's files" {
    var local_context = try workspace.ExecutionContext.local(testing.allocator);
    defer local_context.deinit();
    try testing.expect(!SinkIo.forContext(null, .{}).isRemote());
    try testing.expect(!SinkIo.forContext(local_context.borrow(), .{}).isRemote());
    var scripted: ScriptedContext = .{};
    try testing.expect(SinkIo.forContext(scripted.ref(), .{}).isRemote());
}

test "the Local seam follows, reads, stats, lists and writes this machine's files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    var path_buffer: [256]u8 = undefined;
    var sink = SinkIo.local();

    const dir = try std.fmt.bufPrint(&path_buffer, "{s}/sink/decisions", .{root});
    try sink.makePrivateDir(testing.io, dir);
    var events_buffer: [256]u8 = undefined;
    const events = try std.fmt.bufPrint(&events_buffer, "{s}/sink/events.jsonl", .{root});
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(?usize, null), try sink.readAt(testing.io, events, 0, &buffer));
    try sink.writeFile(testing.io, events, "one\ntwo\n", private_file_mode);
    try testing.expectEqual(@as(?usize, 8), try sink.readAt(testing.io, events, 0, &buffer));
    try testing.expectEqual(@as(?usize, 0), try sink.readAt(testing.io, events, 8, &buffer));
    var small: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, sink.readFile(testing.io, events, &small));
    try testing.expectEqualStrings("one\ntwo\n", (try sink.readFile(testing.io, events, &buffer)).?);
    try testing.expectEqual(workspace.PathKind.file, (try sink.stat(testing.io, events)).?.kind);
    try testing.expectEqual(@as(?workspace.PathStat, null), try sink.stat(testing.io, dir[0 .. dir.len - 1]));

    const Count = struct {
        n: usize = 0,
        fn visit(ptr: *anyopaque, _: workspace.DirEntry) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.n += 1;
            return true;
        }
    };
    var count: Count = .{};
    var sink_dir_buffer: [256]u8 = undefined;
    try testing.expect(try sink.listDir(testing.io, try std.fmt.bufPrint(&sink_dir_buffer, "{s}/sink", .{root}), .{ .context = &count, .visit_fn = Count.visit }));
    try testing.expectEqual(@as(usize, 2), count.n);
    try testing.expect(!try sink.listDir(testing.io, try std.fmt.bufPrint(&sink_dir_buffer, "{s}/absent", .{root}), .{ .context = &count, .visit_fn = Count.visit }));
}

test "a remote seam skips idle files between reads but never holds back new bytes" {
    var scripted: ScriptedContext = .{};
    defer scripted.content.deinit(testing.allocator);
    var sink = SinkIo.forContext(scripted.ref(), .{ .idle_read_interval_ms = 60_000 });
    var buffer: [16]u8 = undefined;

    // Missing, then idle: asked once, then held back for the interval.
    scripted.exists = false;
    try testing.expectEqual(@as(?usize, null), try sink.readAt(testing.io, "/r/events.jsonl", 0, &buffer));
    try testing.expectEqual(@as(?usize, 0), try sink.readAt(testing.io, "/r/events.jsonl", 0, &buffer));
    try testing.expectEqual(@as(usize, 1), scripted.reads);

    // Another path has its own throttle.
    scripted.exists = true;
    try scripted.content.appendSlice(testing.allocator, "line\n");
    try testing.expectEqual(@as(?usize, 5), try sink.readAt(testing.io, "/r/transcript.jsonl", 0, &buffer));
    // Bytes keep it hot: the next read asks again.
    try testing.expectEqual(@as(?usize, 0), try sink.readAt(testing.io, "/r/transcript.jsonl", 5, &buffer));
    try testing.expectEqual(@as(usize, 3), scripted.reads);
    // ...and now it is idle.
    try testing.expectEqual(@as(?usize, 0), try sink.readAt(testing.io, "/r/transcript.jsonl", 5, &buffer));
    try testing.expectEqual(@as(usize, 3), scripted.reads);

    // With no interval every call reaches the context.
    var eager = SinkIo.forContext(scripted.ref(), .{ .idle_read_interval_ms = 0 });
    _ = try eager.readAt(testing.io, "/r/transcript.jsonl", 5, &buffer);
    _ = try eager.readAt(testing.io, "/r/transcript.jsonl", 5, &buffer);
    try testing.expectEqual(@as(usize, 5), scripted.reads);

    // Writes and directories go straight through, and failures map.
    try eager.writeFile(testing.io, "/r/decisions/1-2", "allow", private_file_mode);
    try testing.expectEqualStrings("/r/decisions/1-2", scripted.written_path[0..scripted.written_path_len]);
    try testing.expectEqual(private_file_mode, scripted.written_mode);
    try testing.expectEqualStrings("allow", scripted.content.items);
    try eager.makePrivateDir(testing.io, "/r");
    try testing.expectEqual(@as(usize, 1), scripted.dirs);
    scripted.fail = error.Unavailable;
    try testing.expectError(error.Disconnected, eager.readAt(testing.io, "/r/x", 0, &buffer));
    try testing.expectError(error.Disconnected, eager.writeFile(testing.io, "/r/x", "y", private_file_mode));
    scripted.fail = error.TooLarge;
    try testing.expectError(error.NoSpaceLeft, eager.writeFile(testing.io, "/r/x", "y", private_file_mode));
    // A context without the capability is a disconnected channel, not a crash.
    scripted.fail = null;
    try testing.expectError(error.Disconnected, eager.readFile(testing.io, "/r/x", &buffer));
}
