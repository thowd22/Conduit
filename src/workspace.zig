//! Workspace ownership below the UI layer (CONDUIT.md §13).
//!
//! A workspace owns its copied display name and working directory, one execution
//! context, and every session created in that context. Sessions are addressed
//! by monotonic ids and live independently of tabs, panes, or any other view.
//! The one scratchpad session exists from workspace creation. Its child starts
//! and restarts through the same borrowed context capability as other sessions,
//! while presentation remains a UI concern. Session records are created on the
//! owner thread; a worker uses that capability to spawn, then transfers the
//! resulting PTY back for attachment. Process creation therefore never blocks
//! the render/UI thread.
//!
//! Memory: `Workspace` owns its name, working-directory bytes, context, stable
//! session records, terminals, and PTYs. `WorkspaceRegistry` owns heap-stable
//! workspace records and preserves their monotonic identities independently of
//! mutable display names. `ExecutionContext` owns its erased implementation.
//! Passing a context to `Workspace.init` transfers ownership even when
//! initialization fails. The allocator and `std.Io` are borrowed and must
//! outlive the workspace.

const std = @import("std");
const builtin = @import("builtin");
const pty = @import("pty");
const session = @import("session");
// The `state` module, under another name: `state` is also a PTY vtable
// callback name in this file.
const persistence = @import("state");
const term = @import("term");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.workspace);

/// Validated display name for one workspace.
///
/// A Workspace copies this trimmed value. Names are unique only within a
/// WorkspaceRegistry and may be changed there; WorkspaceKey is stable identity.
pub const WorkspaceId = struct {
    /// The trimmed name. This parser borrows it; `Workspace` copies it.
    name: []const u8,

    pub const Error = error{EmptyName};

    /// Validate a name and trim surrounding ASCII whitespace.
    pub fn init(name: []const u8) Error!WorkspaceId {
        const trimmed = std.mem.trim(u8, name, std.ascii.whitespace[0..]);
        if (trimmed.len == 0) return error.EmptyName;
        return .{ .name = trimmed };
    }
};

/// Which environment a workspace runs in. Concrete connection state belongs
/// to the erased `ExecutionContext` implementation, not to callers.
pub const ExecutionContextKind = enum {
    local,
    ssh,
    wsl,

    pub const Error = error{UnknownContext};

    /// Parse the exact persisted spelling.
    pub fn parse(text: []const u8) Error!ExecutionContextKind {
        inline for (@typeInfo(ExecutionContextKind).@"enum".fields) |field| {
            const kind: ExecutionContextKind = @enumFromInt(field.value);
            if (std.mem.eql(u8, text, kind.label())) return kind;
        }
        return error.UnknownContext;
    }

    /// Return the exact persisted spelling.
    pub fn label(self: ExecutionContextKind) []const u8 {
        return switch (self) {
            .local => "local",
            .ssh => "ssh",
            .wsl => "wsl",
        };
    }

    /// Whether paths and processes belong to another machine.
    pub fn isRemote(self: ExecutionContextKind) bool {
        return self != .local;
    }
};

/// Failures of a context's file-system capability (`readFile`, `listDir`,
/// `statPath`). The set is closed so a remote context maps its transport
/// failures onto the same vocabulary a Local one uses.
pub const FsError = error{
    NotFound,
    AccessDenied,
    NotADirectory,
    IsADirectory,
    /// The file is larger than the caller's buffer.
    TooLarge,
    NameTooLong,
    /// The context has no file system capability (the default vtable entry).
    Unsupported,
    OutOfMemory,
    /// Any other read failure, including a lost remote connection.
    Unavailable,
};

/// What a path names, in the terms every context can answer.
pub const PathKind = enum { file, directory, other };

/// The metadata `statPath` reports. `mtime_ns` is nanoseconds since the Unix
/// epoch in the context's own clock; callers compare it only for equality.
pub const PathStat = struct {
    kind: PathKind,
    size: u64,
    mtime_ns: i128,
};

/// One directory entry. `name` borrows the context's iteration buffer and is
/// valid only during the visit callback.
pub const DirEntry = struct {
    name: []const u8,
    kind: PathKind,
};

/// The callback `listDir` calls once per entry, on the caller's thread.
/// Returning `false` stops the listing early, which is how a caller bounds it.
pub const DirVisitor = struct {
    context: *anyopaque,
    visit_fn: *const fn (context: *anyopaque, entry: DirEntry) bool,
};

/// One bounded, non-interactive command (`ExecutionContext.run`).
///
/// `argv` is passed to the program verbatim, never through a shell; `argv[0]`
/// is resolved on the context's own `PATH`. All slices are borrowed for the
/// call. The child's stdin is `stdin` followed by end of file, or empty.
pub const RunRequest = struct {
    argv: []const []const u8,
    /// The child's working directory, in the context's own path syntax.
    cwd: []const u8,
    /// At most `max_stdin` bytes, so writing it up front can never block on a
    /// child that is not reading.
    stdin: ?[]const u8 = null,
    /// The most bytes kept from each of stdout and stderr. A child that
    /// writes more fails with `error.OutputTooLarge` and is killed.
    max_output: usize = 256 * 1024,
    /// Wall-clock bound on the whole run. On expiry the child is killed and
    /// the call fails with `error.Timeout`.
    timeout_ms: u32 = 10_000,

    pub const max_stdin: usize = 16 * 1024;
};

/// The outcome of a command that ran to completion. `stdout` and `stderr` are
/// owned by the allocator passed to `run`; release them with `deinit`.
pub const RunResult = struct {
    /// The exit status, or `null` when the child did not exit normally.
    exit_code: ?u8,
    /// The terminating signal, when there was one.
    signal: ?u32 = null,
    stdout: []u8,
    stderr: []u8,

    /// Whether the command exited with status 0.
    pub fn succeeded(self: RunResult) bool {
        return self.exit_code != null and self.exit_code.? == 0;
    }

    pub fn deinit(self: *RunResult, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

/// Failures of `ExecutionContext.run` that prevent a result. A command that
/// starts and exits non-zero is a `RunResult`, not an error.
pub const RunError = error{
    /// `argv[0]` does not exist on the context's `PATH`.
    CommandNotFound,
    AccessDenied,
    /// Empty argv, or stdin over `RunRequest.max_stdin`.
    InvalidRequest,
    Timeout,
    OutputTooLarge,
    SpawnFailed,
    /// The context cannot run commands (the default vtable entry).
    Unsupported,
    OutOfMemory,
    Unavailable,
};

/// Failures of `ExecutionContext.watch`. A path that does not exist yet is
/// not an error: the watch reports a change once it appears.
pub const WatchError = error{ Unsupported, OutOfMemory, Unavailable };

/// An owned change flag for one directory, created by
/// `ExecutionContext.watch`.
///
/// Thread ownership: the handle belongs to the thread that created it. It
/// starts no thread and never calls back; `pollChanges` is non-blocking and
/// only says whether anything in the directory (an entry's creation, removal,
/// rename, content or metadata) may have changed since the previous poll. The
/// caller then re-reads what it needs through the context, so no file content
/// ever crosses threads. False positives are allowed; a missed change is not.
pub const WatchHandle = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        poll_changes: *const fn (*anyopaque) bool,
        destroy: *const fn (*anyopaque) void,
    };

    /// Whether the directory may have changed since the last poll.
    pub fn pollChanges(self: WatchHandle) bool {
        return self.vtable.poll_changes(self.ptr);
    }

    /// Release the watch and everything it holds.
    pub fn deinit(self: *WatchHandle) void {
        self.vtable.destroy(self.ptr);
        self.* = undefined;
    }
};

/// An owned, type-erased place in which workspace processes start and
/// workspace files are read.
///
/// `initOwned` transfers ownership of `ptr`; its vtable must release that
/// implementation in `destroy`. This public seam lets tests and future SSH or
/// WSL contexts participate without exposing local process APIs to callers.
/// Do not copy an owning value: transfer it into one workspace and call
/// `deinit` exactly once.
///
/// Every capability takes paths in the context's own syntax (`/`-separated
/// for Local, SSH and WSL alike) and borrows `std.Io` from the caller. Local
/// inherits this machine; remote contexts supply their own implementations of
/// the same entries (TASK-43, TASK-47), and an entry a context does not
/// implement defaults to `error.Unsupported`.
///
/// Threads: `spawn`, `readFile`, `listDir`, `statPath` and `run` keep no
/// mutable state in the context and may be called from any thread holding a
/// `Ref`. They block on IO for as long as the operation takes (a remote
/// context waits on its connection), so the render/UI thread must not call
/// them for a remote context; `run` additionally waits for the child, up to
/// its timeout, and so belongs on a worker thread everywhere. A `WatchHandle`
/// belongs to the thread that created it.
pub const ExecutionContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const SpawnFn = *const fn (*anyopaque, pty.SpawnRequest) pty.Error!pty.Pty;
    pub const KindFn = *const fn (*const anyopaque) ExecutionContextKind;
    pub const DestroyFn = *const fn (*anyopaque) void;
    /// Read the whole file at `path` into `buffer` and return the filled
    /// prefix. A file longer than `buffer` is `error.TooLarge`, so
    /// `buffer.len` is the read bound.
    pub const ReadFileFn = *const fn (*anyopaque, std.Io, []const u8, []u8) FsError![]u8;
    /// Call the visitor once per entry of the directory at `path`, excluding
    /// `.` and `..`, in no particular order.
    pub const ListDirFn = *const fn (*anyopaque, std.Io, []const u8, DirVisitor) FsError!void;
    /// Describe `path`, following symbolic links.
    pub const StatPathFn = *const fn (*anyopaque, std.Io, []const u8) FsError!PathStat;
    /// Start an owned change watch on the directory at `path`.
    pub const WatchFn = *const fn (*anyopaque, Allocator, std.Io, []const u8) WatchError!WatchHandle;
    /// Run one bounded command to completion; output is owned by the allocator.
    pub const RunFn = *const fn (*anyopaque, Allocator, std.Io, RunRequest) RunError!RunResult;

    pub const VTable = struct {
        spawn: SpawnFn,
        kind: KindFn,
        destroy: DestroyFn,
        read_file: ReadFileFn = unsupportedReadFile,
        list_dir: ListDirFn = unsupportedListDir,
        stat_path: StatPathFn = unsupportedStatPath,
        watch: WatchFn = unsupportedWatch,
        run: RunFn = unsupportedRun,
    };

    /// A non-owning execution capability. It may start work, read files and
    /// inspect the context kind, but cannot destroy the implementation. The
    /// owning `ExecutionContext` must outlive every borrowed reference.
    pub const Ref = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        /// Spawn through the borrowed concrete context.
        pub fn spawn(self: Ref, request: pty.SpawnRequest) pty.Error!pty.Pty {
            return self.vtable.spawn(self.ptr, request);
        }

        /// Identify the borrowed concrete environment.
        pub fn kind(self: Ref) ExecutionContextKind {
            return self.vtable.kind(self.ptr);
        }

        /// See `ReadFileFn`.
        pub fn readFile(self: Ref, io: std.Io, path: []const u8, buffer: []u8) FsError![]u8 {
            return self.vtable.read_file(self.ptr, io, path, buffer);
        }

        /// See `ListDirFn`.
        pub fn listDir(self: Ref, io: std.Io, path: []const u8, visitor: DirVisitor) FsError!void {
            return self.vtable.list_dir(self.ptr, io, path, visitor);
        }

        /// See `StatPathFn`.
        pub fn statPath(self: Ref, io: std.Io, path: []const u8) FsError!PathStat {
            return self.vtable.stat_path(self.ptr, io, path);
        }

        /// See `WatchFn` and `WatchHandle`.
        pub fn watch(self: Ref, allocator: Allocator, io: std.Io, path: []const u8) WatchError!WatchHandle {
            return self.vtable.watch(self.ptr, allocator, io, path);
        }

        /// See `RunFn` and `RunRequest`.
        pub fn run(self: Ref, allocator: Allocator, io: std.Io, request: RunRequest) RunError!RunResult {
            return self.vtable.run(self.ptr, allocator, io, request);
        }
    };

    /// Wrap an owned implementation. `vtable` must live at least as long as
    /// the returned context, normally as a static declaration.
    pub fn initOwned(ptr: *anyopaque, vtable: *const VTable) ExecutionContext {
        return .{ .ptr = ptr, .vtable = vtable };
    }

    /// Create the production local context.
    pub fn local(allocator: Allocator) Allocator.Error!ExecutionContext {
        return LocalExecutionContext.create(allocator);
    }

    /// Borrow a capability handle without transferring destruction rights.
    pub fn borrow(self: *const ExecutionContext) Ref {
        return .{ .ptr = self.ptr, .vtable = self.vtable };
    }

    /// Identify the environment without exposing its concrete state.
    pub fn kind(self: *const ExecutionContext) ExecutionContextKind {
        return self.vtable.kind(self.ptr);
    }

    /// Release the erased implementation.
    pub fn deinit(self: *ExecutionContext) void {
        self.vtable.destroy(self.ptr);
        self.* = undefined;
    }

    fn unsupportedReadFile(_: *anyopaque, _: std.Io, _: []const u8, _: []u8) FsError![]u8 {
        return error.Unsupported;
    }

    fn unsupportedListDir(_: *anyopaque, _: std.Io, _: []const u8, _: DirVisitor) FsError!void {
        return error.Unsupported;
    }

    fn unsupportedStatPath(_: *anyopaque, _: std.Io, _: []const u8) FsError!PathStat {
        return error.Unsupported;
    }

    fn unsupportedWatch(_: *anyopaque, _: Allocator, _: std.Io, _: []const u8) WatchError!WatchHandle {
        return error.Unsupported;
    }

    fn unsupportedRun(_: *anyopaque, _: Allocator, _: std.Io, _: RunRequest) RunError!RunResult {
        return error.Unsupported;
    }
};

/// The SSH execution context (TASK-43, decision-8): `ssh.SshContext.create`
/// builds an owned `ExecutionContext` of kind `.ssh` whose processes ride one
/// OpenSSH ControlMaster connection.
pub const ssh = @import("ssh.zig");

/// The local execution implementation. With the SSH context's spawns of the
/// local `ssh` client (`ssh.zig`), this is deliberately the only production
/// call to `pty.spawn` in this module; every workspace caller sees only
/// `ExecutionContext.Ref.spawn`. Its file and command capabilities act on
/// this machine and keep no state in the context, so they are safe from any
/// thread. `run` children inherit Conduit's process environment, like every
/// Local child (TASK-73).
pub const LocalExecutionContext = struct {
    allocator: Allocator,

    const vtable: ExecutionContext.VTable = .{
        .spawn = spawn,
        .kind = kind,
        .destroy = destroy,
        .read_file = readFile,
        .list_dir = listDir,
        .stat_path = statPath,
        .watch = watch,
        .run = run,
    };

    /// Allocate an owned local context implementation.
    pub fn create(allocator: Allocator) Allocator.Error!ExecutionContext {
        const self = try allocator.create(LocalExecutionContext);
        self.* = .{ .allocator = allocator };
        return ExecutionContext.initOwned(self, &vtable);
    }

    fn spawn(ptr: *anyopaque, request: pty.SpawnRequest) pty.Error!pty.Pty {
        const self: *LocalExecutionContext = @ptrCast(@alignCast(ptr));
        return pty.spawn(self.allocator, request);
    }

    fn kind(_: *const anyopaque) ExecutionContextKind {
        return .local;
    }

    fn destroy(ptr: *anyopaque) void {
        const self: *LocalExecutionContext = @ptrCast(@alignCast(ptr));
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn fsError(err: anyerror) FsError {
        return switch (err) {
            error.FileNotFound => error.NotFound,
            error.AccessDenied, error.PermissionDenied => error.AccessDenied,
            error.NotDir => error.NotADirectory,
            error.IsDir => error.IsADirectory,
            error.NameTooLong => error.NameTooLong,
            error.OutOfMemory, error.SystemResources => error.OutOfMemory,
            else => error.Unavailable,
        };
    }

    fn pathKind(file_kind: std.Io.File.Kind) PathKind {
        return switch (file_kind) {
            .file => .file,
            .directory => .directory,
            else => .other,
        };
    }

    fn readFile(_: *anyopaque, io: std.Io, path: []const u8, buffer: []u8) FsError![]u8 {
        var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| return fsError(err);
        defer file.close(io);
        const stat = file.stat(io) catch |err| return fsError(err);
        if (stat.kind == .directory) return error.IsADirectory;
        if (stat.size > buffer.len) return error.TooLarge;

        var reader = file.reader(io, &.{});
        const n = reader.interface.readSliceShort(buffer) catch return error.Unavailable;
        if (n == buffer.len) {
            // The file may have grown since `stat`; one more byte decides.
            var probe: [1]u8 = undefined;
            const extra = reader.interface.readSliceShort(&probe) catch return error.Unavailable;
            if (extra != 0) return error.TooLarge;
        }
        return buffer[0..n];
    }

    fn listDir(_: *anyopaque, io: std.Io, path: []const u8, visitor: DirVisitor) FsError!void {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| return fsError(err);
        defer dir.close(io);
        var iterator = dir.iterate();
        while (iterator.next(io) catch |err| return fsError(err)) |entry| {
            var entry_kind = pathKind(entry.kind);
            if (entry.kind == .sym_link or entry.kind == .unknown) {
                // Follow the link so a symlinked task file still counts as a file; a
                // dangling link is simply not a file.
                entry_kind = if (dir.statFile(io, entry.name, .{})) |target|
                    pathKind(target.kind)
                else |_|
                    .other;
            }
            if (!visitor.visit_fn(visitor.context, .{ .name = entry.name, .kind = entry_kind })) return;
        }
    }

    fn statPath(_: *anyopaque, io: std.Io, path: []const u8) FsError!PathStat {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| return fsError(err);
        return .{
            .kind = pathKind(stat.kind),
            .size = stat.size,
            .mtime_ns = stat.mtime.nanoseconds,
        };
    }

    fn watch(_: *anyopaque, allocator: Allocator, io: std.Io, path: []const u8) WatchError!WatchHandle {
        return LocalWatch.create(allocator, io, path);
    }

    fn run(_: *anyopaque, allocator: Allocator, io: std.Io, request: RunRequest) RunError!RunResult {
        return runLocalProcess(allocator, io, request);
    }
};

/// Run one bounded command on this machine over pipes: the Local context's
/// `run`, shared with contexts whose transport is itself a local program (the
/// SSH context runs `ssh` through it). The child inherits Conduit's process
/// environment (TASK-73); an empty `request.cwd` means Conduit's own working
/// directory. Blocks until the child exits or the timeout kills it, so it is
/// for worker threads only.
pub fn runLocalProcess(allocator: Allocator, io: std.Io, request: RunRequest) RunError!RunResult {
    if (request.argv.len == 0) return error.InvalidRequest;
    if (request.stdin) |bytes| {
        if (bytes.len > RunRequest.max_stdin) return error.InvalidRequest;
    }
    var child = std.process.spawn(io, .{
        .argv = request.argv,
        .cwd = if (request.cwd.len == 0) .inherit else .{ .path = request.cwd },
        .stdin = if (request.stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return switch (err) {
        error.FileNotFound => error.CommandNotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.OutOfMemory => error.OutOfMemory,
        else => error.SpawnFailed,
    };
    // Kills and reaps a child that is still running on every early return;
    // after `wait` it does nothing.
    defer child.kill(io);

    if (request.stdin) |bytes| {
        if (child.stdin) |stdin| {
            // A child that exits without reading closes the pipe; its exit status, not
            // this write, is the outcome the caller is told about.
            stdin.writeStreamingAll(io, bytes) catch |err|
                log.debug("run: stdin not fully delivered: {s}", .{@errorName(err)});
            stdin.close(io);
            child.stdin = null;
        }
    }

    const timeout = (std.Io.Timeout{ .duration = .{
        .raw = .fromMilliseconds(request.timeout_ms),
        .clock = .awake,
    } }).toDeadline(io);

    var streams_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, streams_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(64, timeout)) |_| {
        if (stdout_reader.buffered().len > request.max_output or
            stderr_reader.buffered().len > request.max_output)
        {
            return error.OutputTooLarge;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => return error.Timeout,
        else => return error.Unavailable,
    }
    multi_reader.checkAnyError() catch return error.Unavailable;

    const term_status = child.wait(io) catch return error.Unavailable;
    const stdout = multi_reader.toOwnedSlice(0) catch return error.OutOfMemory;
    errdefer allocator.free(stdout);
    const stderr = multi_reader.toOwnedSlice(1) catch return error.OutOfMemory;
    return switch (term_status) {
        .exited => |code| .{ .exit_code = code, .stdout = stdout, .stderr = stderr },
        .signal, .stopped => |sig| .{
            .exit_code = null,
            .signal = @intCast(@intFromEnum(sig)),
            .stdout = stdout,
            .stderr = stderr,
        },
        .unknown => .{ .exit_code = null, .stdout = stdout, .stderr = stderr },
    };
}

/// How often a polling watch re-scans its directory. The Linux watch also
/// uses it while the directory does not exist yet.
pub const watch_poll_interval_ms: i64 = 1000;
/// The most entries a polling watch fingerprints, so a scan stays bounded.
pub const watch_max_entries: usize = 4096;

/// The Local `WatchHandle`: inotify on the directory on Linux, drained without
/// a thread from a non-blocking descriptor at `pollChanges`; elsewhere, and on
/// Linux while the directory does not exist, a rate-limited fingerprint of the
/// directory's entries (name, kind, size, mtime). The design follows
/// `config.Watcher` (TASK-37) minus its thread and wake callback, because the
/// owner polls.
const LocalWatch = struct {
    allocator: Allocator,
    io: std.Io,
    /// Owned, NUL-terminated copy of the watched directory path.
    path: [:0]u8,
    /// Linux inotify descriptor, or -1 when inotify is unavailable.
    inotify_fd: i32 = -1,
    /// Whether the inotify watch on `path` is established.
    watching: bool = false,
    fingerprint: u64 = 0,
    last_scan_ms: i64 = 0,

    const handle_vtable: WatchHandle.VTable = .{
        .poll_changes = pollChanges,
        .destroy = destroy,
    };

    fn create(allocator: Allocator, io: std.Io, path: []const u8) WatchError!WatchHandle {
        const self = try allocator.create(LocalWatch);
        errdefer allocator.destroy(self);
        const owned = try allocator.dupeZ(u8, path);
        self.* = .{ .allocator = allocator, .io = io, .path = owned };
        if (comptime builtin.os.tag == .linux) {
            const linux = std.os.linux;
            const rc = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
            if (linux.errno(rc) == .SUCCESS) {
                self.inotify_fd = @intCast(rc);
                _ = self.addWatch();
            } else {
                log.warn("inotify is unavailable; polling a watched directory every {d} ms", .{watch_poll_interval_ms});
            }
        }
        if (!self.watching) {
            self.fingerprint = self.scan();
            self.last_scan_ms = nowMs(io);
        }
        return .{ .ptr = self, .vtable = &handle_vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const self: *LocalWatch = @ptrCast(@alignCast(ptr));
        if (comptime builtin.os.tag == .linux) {
            if (self.inotify_fd >= 0) _ = std.os.linux.close(self.inotify_fd);
        }
        const allocator = self.allocator;
        allocator.free(self.path);
        allocator.destroy(self);
    }

    fn nowMs(io: std.Io) i64 {
        return std.Io.Clock.awake.now(io).toMilliseconds();
    }

    /// Establish the inotify watch. Linux only; returns whether it now holds.
    fn addWatch(self: *LocalWatch) bool {
        if (comptime builtin.os.tag != .linux) return false;
        if (self.inotify_fd < 0) return false;
        const linux = std.os.linux;
        const mask: u32 = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.MOVED_FROM |
            linux.IN.CREATE | linux.IN.DELETE | linux.IN.ATTRIB | linux.IN.MODIFY |
            linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.ONLYDIR;
        const rc = linux.inotify_add_watch(self.inotify_fd, self.path.ptr, mask);
        self.watching = linux.errno(rc) == .SUCCESS;
        return self.watching;
    }

    fn pollChanges(ptr: *anyopaque) bool {
        const self: *LocalWatch = @ptrCast(@alignCast(ptr));
        if (self.watching) {
            const changed = self.drainInotify();
            if (self.watching) return changed;
            // The directory itself went away or was replaced. Re-watch it now if
            // it is back, otherwise fall back to rate-limited fingerprinting until
            // it reappears; either way this poll is a change.
            if (!self.addWatch()) {
                self.fingerprint = self.scan();
                self.last_scan_ms = nowMs(self.io);
            }
            return true;
        }
        // The directory appeared since the last poll: everything in it is new.
        if (self.addWatch()) return true;

        const now = nowMs(self.io);
        if (now - self.last_scan_ms < watch_poll_interval_ms) return false;
        self.last_scan_ms = now;
        const fingerprint = self.scan();
        if (fingerprint == self.fingerprint) return false;
        self.fingerprint = fingerprint;
        return true;
    }

    /// Read every queued inotify event. Any event, an overflowed queue, or the
    /// directory itself going away is a change.
    fn drainInotify(self: *LocalWatch) bool {
        if (comptime builtin.os.tag != .linux) return false;
        const linux = std.os.linux;
        var changed = false;
        var buffer: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const rc = linux.read(self.inotify_fd, &buffer, buffer.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return changed;
            var offset: usize = 0;
            while (offset + @sizeOf(linux.inotify_event) <= rc) {
                const event: *const linux.inotify_event = @ptrCast(@alignCast(&buffer[offset]));
                const span = @sizeOf(linux.inotify_event) + event.len;
                if (offset + span > rc) break;
                if (event.mask & (linux.IN.IGNORED | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF) != 0) {
                    self.watching = false;
                }
                changed = true;
                offset += span;
            }
        }
    }

    /// An order-independent fingerprint of the directory: whether it exists,
    /// and each entry's name, kind, size and mtime.
    fn scan(self: *LocalWatch) u64 {
        const io = self.io;
        var dir = std.Io.Dir.cwd().openDir(io, self.path, .{ .iterate = true }) catch return 0;
        defer dir.close(io);
        var sum: u64 = 1;
        var count: usize = 0;
        var iterator = dir.iterate();
        while (iterator.next(io) catch null) |entry| {
            if (count == watch_max_entries) break;
            count += 1;
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(entry.name);
            if (dir.statFile(io, entry.name, .{})) |stat| {
                hasher.update(std.mem.asBytes(&stat.size));
                const mtime: i128 = stat.mtime.nanoseconds;
                hasher.update(std.mem.asBytes(&mtime));
                hasher.update(&.{@intFromEnum(stat.kind)});
            } else |_| {}
            sum +%= hasher.final();
        }
        return sum;
    }
};

/// Borrowed process inputs for one terminal. `Workspace.spawnRequest` adds the
/// workspace-owned cwd and the session's grid size before a worker spawns.
pub const ProcessSpec = struct {
    argv: []const []const u8,
    env: []const []const u8,
};

/// Synchronous handling of terminal events produced during `Workspace.pump`.
///
/// Event slices and their payloads borrow a terminal and are valid only during
/// the callback. Handling them before the pump advances prevents a later feed
/// from reusing their payload storage.
pub const EventSink = struct {
    ptr: *anyopaque,
    on_events: *const fn (*anyopaque, session.SessionId, []const term.Event) void,

    fn send(self: EventSink, id: session.SessionId, events: []const term.Event) void {
        self.on_events(self.ptr, id, events);
    }
};

/// Counts from one bounded, allocation-free workspace pump.
pub const PumpResult = struct {
    sessions_visited: usize = 0,
    bytes_drained: usize = 0,
    response_bytes_written: usize = 0,
    response_bytes_pending: usize = 0,
    first_error: ?pty.Error = null,

    /// Whether any serviced session needs another response flush.
    pub fn hasPendingResponses(self: PumpResult) bool {
        return self.response_bytes_pending != 0;
    }
};

/// How much child output one event-loop wake may drain before it must return
/// to the window queue, the test driver and the frame decision.
///
/// A single pump moves at most one buffer per session, which is a few KiB from
/// a real PTY. Draining is therefore a loop of pumps, and this is what bounds
/// that loop: it stops when a pass found nothing, when the byte budget is
/// spent, or when the time slice is used up. Both limits exist because neither
/// alone is enough: bytes bound the work a fast parser does between frames, and
/// time bounds how long a slow (Debug) parser can keep input and the driver
/// waiting. The check is pure so its every edge can be tested without a clock.
pub const DrainBudget = struct {
    /// Most bytes one wake may feed into terminals across all sessions.
    max_bytes: usize,
    /// Longest one wake may spend draining, in nanoseconds.
    max_ns: u64,

    /// The event loop's budget: 4 MiB or 8 ms, whichever comes first. Eight
    /// milliseconds is half a 60 Hz frame, so a wake that drains and then
    /// draws still fits about one display interval, and 4 MiB is more than a
    /// release-build parser feeds in that slice, so on a fast machine time is
    /// the binding limit and the byte cap only guards a pathological clock.
    pub const per_wake: DrainBudget = .{
        .max_bytes = 4 * 1024 * 1024,
        .max_ns = 8 * std.time.ns_per_ms,
    };

    /// Whether to run another pump pass after one that drained
    /// `last_pass_bytes`, with `total_bytes` drained and `elapsed_ns` spent
    /// so far in this wake.
    pub fn allowsAnotherPass(
        self: DrainBudget,
        last_pass_bytes: usize,
        total_bytes: usize,
        elapsed_ns: u64,
    ) bool {
        if (last_pass_bytes == 0) return false;
        if (total_bytes >= self.max_bytes) return false;
        return elapsed_ns < self.max_ns;
    }
};

const SessionRecord = struct {
    id: session.SessionId,
    kind: session.Session.Kind,
    lifecycle: session.Lifecycle,
    live: ?session.Session,
};

/// Stable identity for a tab within one workspace. Values are one-based,
/// monotonic, and never reused.
pub const TabId = enum(u32) {
    first = 1,
    _,

    /// Build the id for a zero-based allocation ordinal.
    pub fn fromOrdinal(ordinal_value: u32) TabId {
        return @enumFromInt(ordinal_value + 1);
    }

    /// Return the zero-based allocation ordinal.
    pub fn ordinal(self: TabId) u32 {
        return @intFromEnum(self) - 1;
    }
};

/// Attention retained for a background tab. A bell outranks ordinary output
/// until the user activates the tab, which clears either state.
pub const TabAttention = enum {
    none,
    activity,
    bell,
};

/// Stable identity of one terminal pane within a workspace. Values are
/// one-based, monotonic, and never reused even after a pane or tab closes.
pub const PaneId = enum(u32) {
    first = 1,
    _,

    /// Build an id for a zero-based allocation ordinal.
    pub fn fromOrdinal(ordinal_value: u32) PaneId {
        return @enumFromInt(ordinal_value + 1);
    }

    /// Return the zero-based allocation ordinal.
    pub fn ordinal(self: PaneId) u32 {
        return @intFromEnum(self) - 1;
    }
};

/// Stable identity of one draggable divider within a workspace.
pub const DividerId = enum(u32) {
    first = 1,
    _,

    /// Build an id for a zero-based allocation ordinal.
    pub fn fromOrdinal(ordinal_value: u32) DividerId {
        return @enumFromInt(ordinal_value + 1);
    }

    /// Return the zero-based allocation ordinal.
    pub fn ordinal(self: DividerId) u32 {
        return @intFromEnum(self) - 1;
    }
};

/// Where a new pane is placed relative to an existing leaf.
pub const PaneSplit = enum {
    right,
    down,
};

/// A spatial direction used for focus and keyboard-divider movement.
pub const PaneDirection = enum {
    left,
    right,
    up,
    down,
};

/// A terminal-cell rectangle in the workspace canvas.
pub const CellRect = struct {
    col: u16,
    row: u16,
    cols: u16,
    rows: u16,

    /// Construct a non-empty cell rectangle.
    pub fn init(
        col: u16,
        row: u16,
        cols: u16,
        rows: u16,
    ) error{ EmptyRect, RectOverflow }!CellRect {
        if (cols == 0 or rows == 0) return error.EmptyRect;
        if (@as(u32, col) + cols > @as(u32, std.math.maxInt(u16)) + 1 or
            @as(u32, row) + rows > @as(u32, std.math.maxInt(u16)) + 1)
        {
            return error.RectOverflow;
        }
        return .{ .col = col, .row = row, .cols = cols, .rows = rows };
    }
};

/// One visible pane produced by a layout traversal.
pub const PaneLayout = struct {
    pane_id: PaneId,
    session_id: session.SessionId,
    rect: CellRect,
    focused: bool,
};

/// One visible one-cell divider produced by a layout traversal.
pub const DividerLayout = struct {
    divider_id: DividerId,
    split: PaneSplit,
    rect: CellRect,
};

/// The result of requesting that one pane close.
pub const ClosePaneResult = enum {
    /// A non-final pane and its session were removed.
    pane_closed,
    /// The pane is the tab's final leaf; the caller must close the tab.
    close_tab,
};

/// Location of a session that is currently presented by a pane.
pub const PaneLocation = struct {
    tab_id: TabId,
    pane_id: PaneId,
};

const min_pane_cols: u16 = 2;
const min_pane_rows: u16 = 2;

const PaneLeaf = struct {
    id: PaneId,
    session_id: session.SessionId,
};

const PaneBranch = struct {
    id: DividerId,
    split: PaneSplit,
    first_weight: u32,
    total_weight: u32,
    first: *PaneNode,
    second: *PaneNode,
};

const PaneNode = union(enum) {
    leaf: PaneLeaf,
    branch: PaneBranch,
};

const MinimumSize = struct {
    cols: u32,
    rows: u32,
};

fn validCellRect(rect: CellRect) bool {
    return rect.cols != 0 and rect.rows != 0 and
        @as(u32, rect.col) + rect.cols <= @as(u32, std.math.maxInt(u16)) + 1 and
        @as(u32, rect.row) + rect.rows <= @as(u32, std.math.maxInt(u16)) + 1;
}

fn minimumSize(node: *const PaneNode) MinimumSize {
    return switch (node.*) {
        .leaf => .{ .cols = min_pane_cols, .rows = min_pane_rows },
        .branch => |branch| blk: {
            const first = minimumSize(branch.first);
            const second = minimumSize(branch.second);
            break :blk switch (branch.split) {
                .right => .{
                    .cols = first.cols + 1 + second.cols,
                    .rows = @max(first.rows, second.rows),
                },
                .down => .{
                    .cols = @max(first.cols, second.cols),
                    .rows = first.rows + 1 + second.rows,
                },
            };
        },
    };
}

fn treeFits(node: *const PaneNode, rect: CellRect) bool {
    if (!validCellRect(rect)) return false;
    const minimum = minimumSize(node);
    return rect.cols >= minimum.cols and rect.rows >= minimum.rows;
}

fn destroyPaneTree(allocator: Allocator, node: *PaneNode) void {
    switch (node.*) {
        .leaf => {},
        .branch => |branch| {
            destroyPaneTree(allocator, branch.first);
            destroyPaneTree(allocator, branch.second);
        },
    }
    allocator.destroy(node);
}

fn countPaneLeaves(node: *const PaneNode) usize {
    return switch (node.*) {
        .leaf => 1,
        .branch => |branch| countPaneLeaves(branch.first) + countPaneLeaves(branch.second),
    };
}

fn findPaneConst(node: *const PaneNode, id: PaneId) ?*const PaneLeaf {
    return switch (node.*) {
        .leaf => |*leaf| if (leaf.id == id) leaf else null,
        .branch => |branch| findPaneConst(branch.first, id) orelse findPaneConst(branch.second, id),
    };
}

fn findSessionPane(node: *const PaneNode, session_id: session.SessionId) ?PaneId {
    return switch (node.*) {
        .leaf => |leaf| if (leaf.session_id == session_id) leaf.id else null,
        .branch => |branch| findSessionPane(branch.first, session_id) orelse
            findSessionPane(branch.second, session_id),
    };
}

fn splitExtent(branch: PaneBranch, rect: CellRect) u16 {
    const extent: u32 = switch (branch.split) {
        .right => rect.cols,
        .down => rect.rows,
    };
    const available = extent - 1;
    const first_minimum = minimumSize(branch.first);
    const second_minimum = minimumSize(branch.second);
    const first_min = switch (branch.split) {
        .right => first_minimum.cols,
        .down => first_minimum.rows,
    };
    const second_min = switch (branch.split) {
        .right => second_minimum.cols,
        .down => second_minimum.rows,
    };
    const scaled = (@as(u64, available) * branch.first_weight + branch.total_weight / 2) /
        branch.total_weight;
    return @intCast(std.math.clamp(
        scaled,
        @as(u64, first_min),
        @as(u64, available - second_min),
    ));
}

const Partition = struct {
    first: CellRect,
    divider: CellRect,
    second: CellRect,
};

fn partition(branch: PaneBranch, rect: CellRect) Partition {
    const first_extent = splitExtent(branch, rect);
    return switch (branch.split) {
        .right => .{
            .first = .{ .col = rect.col, .row = rect.row, .cols = first_extent, .rows = rect.rows },
            .divider = .{
                .col = rect.col + first_extent,
                .row = rect.row,
                .cols = 1,
                .rows = rect.rows,
            },
            .second = .{
                .col = rect.col + first_extent + 1,
                .row = rect.row,
                .cols = rect.cols - first_extent - 1,
                .rows = rect.rows,
            },
        },
        .down => .{
            .first = .{ .col = rect.col, .row = rect.row, .cols = rect.cols, .rows = first_extent },
            .divider = .{
                .col = rect.col,
                .row = rect.row + first_extent,
                .cols = rect.cols,
                .rows = 1,
            },
            .second = .{
                .col = rect.col,
                .row = rect.row + first_extent + 1,
                .cols = rect.cols,
                .rows = rect.rows - first_extent - 1,
            },
        },
    };
}

fn nodeForPane(node: *PaneNode, id: PaneId) ?*PaneNode {
    return switch (node.*) {
        .leaf => |leaf| if (leaf.id == id) node else null,
        .branch => |branch| nodeForPane(branch.first, id) orelse nodeForPane(branch.second, id),
    };
}

fn firstLeaf(node: *const PaneNode) PaneLeaf {
    return switch (node.*) {
        .leaf => |leaf| leaf,
        .branch => |branch| firstLeaf(branch.first),
    };
}

fn isLeaf(node: *const PaneNode) bool {
    return switch (node.*) {
        .leaf => true,
        .branch => false,
    };
}

fn isLeafPane(node: *const PaneNode, id: PaneId) bool {
    return switch (node.*) {
        .leaf => |leaf| leaf.id == id,
        .branch => false,
    };
}

fn rectForPane(node: *const PaneNode, id: PaneId, rect: CellRect) ?CellRect {
    return switch (node.*) {
        .leaf => |leaf| if (leaf.id == id) rect else null,
        .branch => |branch| blk: {
            const parts = partition(branch, rect);
            break :blk rectForPane(branch.first, id, parts.first) orelse
                rectForPane(branch.second, id, parts.second);
        },
    };
}

fn writePaneLayouts(
    node: *const PaneNode,
    rect: CellRect,
    focused_id: PaneId,
    output: []PaneLayout,
    index: *usize,
) void {
    switch (node.*) {
        .leaf => |leaf| {
            output[index.*] = .{
                .pane_id = leaf.id,
                .session_id = leaf.session_id,
                .rect = rect,
                .focused = leaf.id == focused_id,
            };
            index.* += 1;
        },
        .branch => |branch| {
            const parts = partition(branch, rect);
            writePaneLayouts(branch.first, parts.first, focused_id, output, index);
            writePaneLayouts(branch.second, parts.second, focused_id, output, index);
        },
    }
}

fn writeDividerLayouts(
    node: *const PaneNode,
    rect: CellRect,
    output: []DividerLayout,
    index: *usize,
) void {
    switch (node.*) {
        .leaf => {},
        .branch => |branch| {
            const parts = partition(branch, rect);
            output[index.*] = .{
                .divider_id = branch.id,
                .split = branch.split,
                .rect = parts.divider,
            };
            index.* += 1;
            writeDividerLayouts(branch.first, parts.first, output, index);
            writeDividerLayouts(branch.second, parts.second, output, index);
        },
    }
}

const DirectionSearch = struct {
    source: CellRect,
    direction: PaneDirection,
    source_id: PaneId,
    best_id: ?PaneId = null,
    best_score: u64 = std.math.maxInt(u64),
};

fn rectEnd(origin: u16, extent: u16) u32 {
    return @as(u32, origin) + extent;
}

fn intervalDistance(a_start: u32, a_end: u32, b_start: u32, b_end: u32) u32 {
    if (a_end <= b_start) return b_start - a_end;
    if (b_end <= a_start) return a_start - b_end;
    return 0;
}

fn directionScore(source: CellRect, candidate: CellRect, direction: PaneDirection) ?u64 {
    const source_left: u32 = source.col;
    const source_top: u32 = source.row;
    const source_right = rectEnd(source.col, source.cols);
    const source_bottom = rectEnd(source.row, source.rows);
    const candidate_left: u32 = candidate.col;
    const candidate_top: u32 = candidate.row;
    const candidate_right = rectEnd(candidate.col, candidate.cols);
    const candidate_bottom = rectEnd(candidate.row, candidate.rows);

    const primary: u32 = switch (direction) {
        .left => if (candidate_right <= source_left) source_left - candidate_right else return null,
        .right => if (candidate_left >= source_right) candidate_left - source_right else return null,
        .up => if (candidate_bottom <= source_top) source_top - candidate_bottom else return null,
        .down => if (candidate_top >= source_bottom) candidate_top - source_bottom else return null,
    };
    const orthogonal = switch (direction) {
        .left, .right => intervalDistance(source_top, source_bottom, candidate_top, candidate_bottom),
        .up, .down => intervalDistance(source_left, source_right, candidate_left, candidate_right),
    };
    const source_center: u32 = switch (direction) {
        .left, .right => source_top * 2 + source.rows,
        .up, .down => source_left * 2 + source.cols,
    };
    const candidate_center: u32 = switch (direction) {
        .left, .right => candidate_top * 2 + candidate.rows,
        .up, .down => candidate_left * 2 + candidate.cols,
    };
    const center_delta = if (source_center > candidate_center)
        source_center - candidate_center
    else
        candidate_center - source_center;
    return @as(u64, primary) * 1_000_000 + @as(u64, orthogonal) * 1_000 + center_delta;
}

fn searchDirection(node: *const PaneNode, rect: CellRect, search: *DirectionSearch) void {
    switch (node.*) {
        .leaf => |leaf| {
            if (leaf.id == search.source_id) return;
            const score = directionScore(search.source, rect, search.direction) orelse return;
            if (score < search.best_score or
                (score == search.best_score and
                    (search.best_id == null or leaf.id.ordinal() < search.best_id.?.ordinal())))
            {
                search.best_score = score;
                search.best_id = leaf.id;
            }
        },
        .branch => |branch| {
            const parts = partition(branch, rect);
            searchDirection(branch.first, parts.first, search);
            searchDirection(branch.second, parts.second, search);
        },
    }
}

const PaneParent = struct {
    parent: *PaneNode,
    target: *PaneNode,
    sibling: *PaneNode,
};

fn parentForPane(node: *PaneNode, id: PaneId) ?PaneParent {
    return switch (node.*) {
        .leaf => null,
        .branch => |branch| blk: {
            if (findPaneConst(branch.first, id) != null) {
                if (isLeafPane(branch.first, id)) {
                    break :blk .{ .parent = node, .target = branch.first, .sibling = branch.second };
                }
                break :blk parentForPane(branch.first, id);
            }
            if (findPaneConst(branch.second, id) != null) {
                if (isLeafPane(branch.second, id)) {
                    break :blk .{ .parent = node, .target = branch.second, .sibling = branch.first };
                }
                break :blk parentForPane(branch.second, id);
            }
            break :blk null;
        },
    };
}

const PaneEdge = struct {
    divider_id: DividerId,
    delta_sign: i32,
};

fn paneEdge(node: *const PaneNode, id: PaneId, direction: PaneDirection) ?PaneEdge {
    return switch (node.*) {
        .leaf => null,
        .branch => |branch| blk: {
            const in_first = findPaneConst(branch.first, id) != null;
            const child = if (in_first) branch.first else branch.second;
            if (!in_first and findPaneConst(branch.second, id) == null) break :blk null;
            const deeper = paneEdge(child, id, direction);
            if (deeper != null) break :blk deeper;
            break :blk switch (direction) {
                .left => if (branch.split == .right and !in_first)
                    PaneEdge{ .divider_id = branch.id, .delta_sign = -1 }
                else
                    null,
                .right => if (branch.split == .right and in_first)
                    PaneEdge{ .divider_id = branch.id, .delta_sign = 1 }
                else
                    null,
                .up => if (branch.split == .down and !in_first)
                    PaneEdge{ .divider_id = branch.id, .delta_sign = -1 }
                else
                    null,
                .down => if (branch.split == .down and in_first)
                    PaneEdge{ .divider_id = branch.id, .delta_sign = 1 }
                else
                    null,
            };
        },
    };
}

fn resizeDividerInTree(
    node: *PaneNode,
    id: DividerId,
    delta: i32,
    rect: CellRect,
) ?bool {
    return switch (node.*) {
        .leaf => null,
        .branch => |*branch| blk: {
            const parts = partition(branch.*, rect);
            if (branch.id == id) {
                const current: i64 = switch (branch.split) {
                    .right => parts.first.cols,
                    .down => parts.first.rows,
                };
                const available: u32 = switch (branch.split) {
                    .right => @as(u32, rect.cols) - 1,
                    .down => @as(u32, rect.rows) - 1,
                };
                const first_minimum = minimumSize(branch.first);
                const second_minimum = minimumSize(branch.second);
                const first_min: u32 = switch (branch.split) {
                    .right => first_minimum.cols,
                    .down => first_minimum.rows,
                };
                const second_min: u32 = switch (branch.split) {
                    .right => second_minimum.cols,
                    .down => second_minimum.rows,
                };
                const requested = current + @as(i64, delta);
                const desired: u32 = @intCast(std.math.clamp(
                    requested,
                    @as(i64, first_min),
                    @as(i64, available - second_min),
                ));
                if (desired == @as(u32, @intCast(current))) break :blk false;
                branch.first_weight = desired;
                branch.total_weight = available;
                break :blk true;
            }
            break :blk resizeDividerInTree(branch.first, id, delta, parts.first) orelse
                resizeDividerInTree(branch.second, id, delta, parts.second);
        },
    };
}

const tab_label_prefix_len = 2;

fn attentionPrefix(attention: TabAttention) *const [tab_label_prefix_len]u8 {
    return switch (attention) {
        .none => "  ",
        .activity => "* ",
        .bell => "! ",
    };
}

fn allocateTabLabel(allocator: Allocator, name: []const u8) Allocator.Error![]u8 {
    const len = std.math.add(usize, tab_label_prefix_len, name.len) catch return error.OutOfMemory;
    const bytes = try allocator.alloc(u8, len);
    @memcpy(bytes[0..tab_label_prefix_len], attentionPrefix(.none));
    @memcpy(bytes[tab_label_prefix_len..], name);
    return bytes;
}

/// One workspace-owned tab label and binary pane layout.
///
/// The display label is one allocation owned by this record: two prefix bytes
/// cache attention without allocating in the pump path, followed by the name.
/// The semantic id is formatted once into inline storage, so `ui.Tree` can
/// borrow both values across frames without stack storage or per-frame work.
pub const Tab = struct {
    const semantic_capacity = "tab.".len + 10;

    id_value: TabId,
    // Kept as the TASK-29 compatibility accessor for the initial/root session.
    session_id: session.SessionId,
    root: *PaneNode,
    focused_pane_id: PaneId,
    zoomed_pane_id: ?PaneId,
    label_bytes: []u8,
    attention_value: TabAttention,
    // Set by `renameTab`: only a name the user chose is persisted (TASK-65).
    user_named: bool,
    semantic_storage: [semantic_capacity]u8,
    semantic_len: u8,

    /// Stable tab identity.
    pub fn id(self: *const Tab) TabId {
        return self.id_value;
    }

    /// Copied user-facing tab label.
    pub fn name(self: *const Tab) []const u8 {
        return self.label_bytes[tab_label_prefix_len..];
    }

    /// Cached attention prefix followed by the copied tab name.
    pub fn displayLabel(self: *const Tab) []const u8 {
        return self.label_bytes;
    }

    /// Whether the name was chosen by the user through `renameTab`, rather
    /// than derived by the app when the tab was created.
    pub fn userNamed(self: *const Tab) bool {
        return self.user_named;
    }

    /// Current background attention state.
    pub fn attention(self: *const Tab) TabAttention {
        return self.attention_value;
    }

    /// The initial session used to create this tab.
    ///
    /// New pane-aware code should use `Workspace.focusedPaneSessionId` or
    /// `Workspace.paneSessionId`; this compatibility value never changes.
    pub fn sessionId(self: *const Tab) session.SessionId {
        return self.session_id;
    }

    /// Stable identity of the pane that receives terminal input.
    pub fn focusedPaneId(self: *const Tab) PaneId {
        return self.focused_pane_id;
    }

    /// Stable identity of the pane filling the tab, or null for normal layout.
    pub fn zoomedPaneId(self: *const Tab) ?PaneId {
        return self.zoomed_pane_id;
    }

    /// Number of terminal leaves retained by this tab.
    pub fn paneCount(self: *const Tab) usize {
        return countPaneLeaves(self.root);
    }

    /// Stable `tab.<id>` identifier for the semantic tree.
    pub fn semanticId(self: *const Tab) []const u8 {
        return self.semantic_storage[0..self.semantic_len];
    }

    fn setAttention(self: *Tab, next_attention: TabAttention) bool {
        if (self.attention_value == next_attention) return false;
        self.attention_value = next_attention;
        @memcpy(self.label_bytes[0..tab_label_prefix_len], attentionPrefix(next_attention));
        return true;
    }
};

fn initializeTab(
    tab_record: *Tab,
    id: TabId,
    session_id: session.SessionId,
    root: *PaneNode,
    root_pane_id: PaneId,
    label_bytes: []u8,
) void {
    tab_record.* = .{
        .id_value = id,
        .session_id = session_id,
        .root = root,
        .focused_pane_id = root_pane_id,
        .zoomed_pane_id = null,
        .label_bytes = label_bytes,
        .attention_value = .none,
        .user_named = false,
        .semantic_storage = undefined,
        .semantic_len = 0,
    };
    // `tab.` plus the ten decimal digits of any u32 exactly fits the inline
    // buffer, so formatting this validated id cannot run out.
    const semantic_id = std.fmt.bufPrint(
        &tab_record.semantic_storage,
        "tab.{d}",
        .{@intFromEnum(id)},
    ) catch unreachable;
    tab_record.semantic_len = @intCast(semantic_id.len);
}

/// The non-visual owner of one workspace and all its sessions.
///
/// Session and tab records have stable heap addresses and monotonic ids. A
/// pointer returned by `sessionById` remains stable until that session is
/// closed; a borrowed tab remains stable for its registration lifetime.
/// Each tab owns a binary pane tree whose leaves refer to workspace-owned
/// sessions. Hiding or zooming a leaf never changes session ownership.
pub const Workspace = struct {
    pub const InitError = Allocator.Error || WorkspaceId.Error || term.Terminal.Error;
    pub const CreateSessionError = Allocator.Error || term.Terminal.Error || error{
        ScratchpadAlreadyExists,
        SessionLimit,
    };
    pub const SpawnRequestError = error{
        SessionNotFound,
        SessionAlreadyStarted,
    };
    pub const AttachChildError = SpawnRequestError;
    pub const ScratchpadRestartRequestError = error{ScratchpadNotRunning};
    pub const ReplaceScratchpadError = term.Terminal.Error || error{
        ScratchpadNotRunning,
        ChildAlreadyAttached,
    };
    /// Outcome after a scratchpad replacement has committed. A cleanup error
    /// belongs to the old child; the replacement remains live and owned.
    pub const ScratchpadReplacement = struct {
        old_child_deinit_error: ?pty.Error = null,
    };
    pub const CloseSessionError = pty.Error || error{
        SessionNotFound,
        ScratchpadCannotClose,
    };
    pub const RegisterTabError = Allocator.Error || error{
        UnknownSession,
        SessionExited,
        ScratchpadSession,
        SessionAlreadyRegistered,
        TabLimit,
        PaneLimit,
    };
    pub const CreatedTab = struct {
        tab_id: TabId,
        session_id: session.SessionId,
    };
    /// Identities committed by one successful pane-session transaction.
    pub const CreatedPane = struct {
        pane_id: PaneId,
        session_id: session.SessionId,
    };
    pub const CreateTabError = Allocator.Error || term.Terminal.Error || error{
        SessionLimit,
        TabLimit,
        PaneLimit,
    };
    pub const RenameTabError = Allocator.Error || error{UnknownTab};
    pub const MoveTabError = error{ UnknownTab, InvalidIndex };
    pub const CloseTabError = CloseSessionError || error{UnknownTab};
    pub const ActivateTabError = error{UnknownTab};
    pub const PaneLookupError = error{ UnknownTab, UnknownPane };
    pub const LayoutError = error{ UnknownTab, InvalidGeometry, BufferTooSmall };
    pub const SplitPaneError = Allocator.Error || error{
        UnknownTab,
        UnknownPane,
        UnknownSession,
        SessionExited,
        ScratchpadSession,
        SessionAlreadyRegistered,
        InvalidGeometry,
        PaneLimit,
        DividerLimit,
    };
    /// Failures that leave pane, session, identity, focus, and zoom state
    /// unchanged while atomically creating a pane and its session.
    pub const CreatePaneSessionError = Allocator.Error || term.Terminal.Error || error{
        UnknownTab,
        UnknownPane,
        ScratchpadSession,
        InvalidGeometry,
        SessionLimit,
        PaneLimit,
        DividerLimit,
    };
    pub const FocusPaneError = error{ UnknownTab, UnknownPane, InvalidGeometry };
    pub const ResizePaneError = error{
        UnknownTab,
        UnknownPane,
        UnknownDivider,
        InvalidGeometry,
    };
    pub const ClosePaneError = CloseSessionError || error{ UnknownTab, UnknownPane };

    const PaneSplitTarget = struct {
        tab: *Tab,
        node: *PaneNode,
        rect: CellRect,
    };

    allocator: Allocator,
    io: std.Io,
    name_bytes: []u8,
    cwd_bytes: []u8,
    context: ExecutionContext,
    sessions: std.ArrayList(*SessionRecord),
    scratchpad_id: session.SessionId,
    tabs: std.ArrayList(*Tab),
    next_tab_ordinal: u32,
    next_pane_ordinal: u32,
    next_divider_ordinal: u32,
    active_tab_id: ?TabId,

    /// Create a workspace and its one childless scratchpad session.
    ///
    /// Ownership of `context` transfers on entry, including every error path.
    /// The copied name, cwd, context, and scratchpad are released by `deinit`.
    pub fn init(
        io: std.Io,
        allocator: Allocator,
        workspace_name: []const u8,
        working_directory: []const u8,
        context: ExecutionContext,
        scratchpad_size: term.GridSize,
    ) InitError!Workspace {
        var owned_context = context;
        errdefer owned_context.deinit();

        const identity = try WorkspaceId.init(workspace_name);
        const name_bytes = try allocator.dupe(u8, identity.name);
        errdefer allocator.free(name_bytes);
        const cwd_bytes = try allocator.dupe(u8, working_directory);
        errdefer allocator.free(cwd_bytes);

        var sessions: std.ArrayList(*SessionRecord) = .empty;
        errdefer sessions.deinit(allocator);
        try sessions.ensureUnusedCapacity(allocator, 1);

        var tabs: std.ArrayList(*Tab) = .empty;
        errdefer tabs.deinit(allocator);

        const record = try allocator.create(SessionRecord);
        errdefer allocator.destroy(record);
        const scratchpad = try session.Session.init(io, allocator, .scratchpad, scratchpad_size);
        record.* = .{
            .id = .first,
            .kind = .scratchpad,
            .lifecycle = .starting,
            .live = scratchpad,
        };
        sessions.appendAssumeCapacity(record);

        return .{
            .allocator = allocator,
            .io = io,
            .name_bytes = name_bytes,
            .cwd_bytes = cwd_bytes,
            .context = owned_context,
            .sessions = sessions,
            .scratchpad_id = .first,
            .tabs = tabs,
            .next_tab_ordinal = 0,
            .next_pane_ordinal = 0,
            .next_divider_ordinal = 0,
            .active_tab_id = null,
        };
    }

    /// Create a workspace backed by the production local context.
    pub fn initLocal(
        io: std.Io,
        allocator: Allocator,
        workspace_name: []const u8,
        working_directory: []const u8,
        scratchpad_size: term.GridSize,
    ) (Allocator.Error || InitError)!Workspace {
        const context = try ExecutionContext.local(allocator);
        return init(io, allocator, workspace_name, working_directory, context, scratchpad_size);
    }

    /// Destroy all sessions and the context, returning the first PTY hangup
    /// failure only after every owned resource has been released.
    pub fn deinit(self: *Workspace) pty.Error!void {
        var first_failure: ?pty.Error = null;
        for (self.tabs.items) |tab_record| {
            destroyPaneTree(self.allocator, tab_record.root);
            self.allocator.free(tab_record.label_bytes);
            self.allocator.destroy(tab_record);
        }
        self.tabs.deinit(self.allocator);
        for (self.sessions.items) |record| {
            if (record.live) |*live| {
                record.lifecycle = .closing;
                live.deinit() catch |err| {
                    if (first_failure == null) first_failure = err;
                };
                record.live = null;
                record.lifecycle = .exited;
            }
            self.allocator.destroy(record);
        }
        self.sessions.deinit(self.allocator);
        self.context.deinit();
        self.allocator.free(self.cwd_bytes);
        self.allocator.free(self.name_bytes);
        self.* = undefined;
        if (first_failure) |err| return err;
    }

    /// The copied workspace identity.
    pub fn name(self: *const Workspace) []const u8 {
        return self.name_bytes;
    }

    /// The copied working directory used for every context spawn.
    pub fn workingDirectory(self: *const Workspace) []const u8 {
        return self.cwd_bytes;
    }

    /// Which concrete execution environment this workspace owns.
    pub fn contextKind(self: *const Workspace) ExecutionContextKind {
        return self.context.kind();
    }

    /// Borrow the spawn capability for an IO worker. The workspace remains
    /// the sole owner and must outlive the returned reference and its call.
    pub fn contextRef(self: *const Workspace) ExecutionContext.Ref {
        return self.context.borrow();
    }

    /// The permanent id of this workspace's one scratchpad session.
    pub fn scratchpadId(self: *const Workspace) session.SessionId {
        return self.scratchpad_id;
    }

    /// Atomically create and select a human terminal tab. Every allocation is
    /// completed before either registry is changed, so an error leaves tab and
    /// session counts, ids and active selection untouched.
    pub fn createTab(
        self: *Workspace,
        display_name: []const u8,
        size: term.GridSize,
    ) CreateTabError!CreatedTab {
        if (self.sessions.items.len >= std.math.maxInt(u32)) return error.SessionLimit;
        if (self.next_tab_ordinal == std.math.maxInt(u32)) return error.TabLimit;
        if (self.next_pane_ordinal == std.math.maxInt(u32)) return error.PaneLimit;

        try self.sessions.ensureUnusedCapacity(self.allocator, 1);
        try self.tabs.ensureUnusedCapacity(self.allocator, 1);

        const session_record = try self.allocator.create(SessionRecord);
        errdefer self.allocator.destroy(session_record);
        const tab_record = try self.allocator.create(Tab);
        errdefer self.allocator.destroy(tab_record);
        const label_bytes = try allocateTabLabel(self.allocator, display_name);
        errdefer self.allocator.free(label_bytes);
        const root = try self.allocator.create(PaneNode);
        errdefer self.allocator.destroy(root);

        // No fallible work follows successful terminal construction. That
        // keeps the new terminal out of an error cleanup path which could only
        // fail by signalling a child that this session cannot yet have.
        const live = try session.Session.init(self.io, self.allocator, .human_terminal, size);
        const session_id = session.SessionId.fromOrdinal(@intCast(self.sessions.items.len));
        const tab_id = TabId.fromOrdinal(self.next_tab_ordinal);
        const pane_id = PaneId.fromOrdinal(self.next_pane_ordinal);
        root.* = .{ .leaf = .{ .id = pane_id, .session_id = session_id } };
        session_record.* = .{
            .id = session_id,
            .kind = .human_terminal,
            .lifecycle = .starting,
            .live = live,
        };
        initializeTab(tab_record, tab_id, session_id, root, pane_id, label_bytes);

        self.sessions.appendAssumeCapacity(session_record);
        self.tabs.appendAssumeCapacity(tab_record);
        self.next_tab_ordinal += 1;
        self.next_pane_ordinal += 1;
        self.active_tab_id = tab_id;
        return .{ .tab_id = tab_id, .session_id = session_id };
    }

    /// Register a copied tab label for an existing live non-scratchpad
    /// session. This does not create, start, or close a session. The first tab
    /// registered becomes active; later registrations preserve the selection.
    pub fn registerTab(
        self: *Workspace,
        display_name: []const u8,
        session_id: session.SessionId,
    ) RegisterTabError!TabId {
        const session_record = self.recordByIdConst(session_id) orelse return error.UnknownSession;
        if (session_record.kind == .scratchpad) return error.ScratchpadSession;
        if (session_record.live == null or session_record.lifecycle == .exited) return error.SessionExited;
        for (self.tabs.items) |tab_record| {
            if (findSessionPane(tab_record.root, session_id) != null) return error.SessionAlreadyRegistered;
        }
        if (self.next_tab_ordinal == std.math.maxInt(u32)) return error.TabLimit;
        if (self.next_pane_ordinal == std.math.maxInt(u32)) return error.PaneLimit;

        try self.tabs.ensureUnusedCapacity(self.allocator, 1);
        const tab_record = try self.allocator.create(Tab);
        errdefer self.allocator.destroy(tab_record);
        const label_bytes = try allocateTabLabel(self.allocator, display_name);
        errdefer self.allocator.free(label_bytes);
        const root = try self.allocator.create(PaneNode);
        errdefer self.allocator.destroy(root);

        const id = TabId.fromOrdinal(self.next_tab_ordinal);
        const pane_id = PaneId.fromOrdinal(self.next_pane_ordinal);
        root.* = .{ .leaf = .{ .id = pane_id, .session_id = session_id } };
        initializeTab(tab_record, id, session_id, root, pane_id, label_bytes);

        self.tabs.appendAssumeCapacity(tab_record);
        self.next_tab_ordinal += 1;
        self.next_pane_ordinal += 1;
        if (self.active_tab_id == null) self.active_tab_id = id;
        return id;
    }

    /// Number of tabs in stable sidebar order.
    pub fn tabCount(self: *const Workspace) usize {
        return self.tabs.items.len;
    }

    /// Borrow the tab at one stable-order index.
    pub fn tabAt(self: *const Workspace, index: usize) ?*const Tab {
        if (index >= self.tabs.items.len) return null;
        return self.tabs.items[index];
    }

    /// Borrow one tab by stable id.
    pub fn tab(self: *const Workspace, id: TabId) ?*const Tab {
        for (self.tabs.items) |tab_record| {
            if (tab_record.id_value == id) return tab_record;
        }
        return null;
    }

    /// Current stable-order index of a tab id.
    pub fn tabIndex(self: *const Workspace, id: TabId) ?usize {
        for (self.tabs.items, 0..) |tab_record, index| {
            if (tab_record.id_value == id) return index;
        }
        return null;
    }

    /// Replace a copied tab name without moving or replacing its stable record.
    /// Allocation completes before the old label is released.
    pub fn renameTab(
        self: *Workspace,
        id: TabId,
        display_name: []const u8,
    ) RenameTabError!void {
        const index = self.tabIndex(id) orelse return error.UnknownTab;
        const label_bytes = try allocateTabLabel(self.allocator, display_name);
        const tab_record = self.tabs.items[index];
        @memcpy(label_bytes[0..tab_label_prefix_len], attentionPrefix(tab_record.attention_value));
        const old_label = tab_record.label_bytes;
        tab_record.label_bytes = label_bytes;
        tab_record.user_named = true;
        self.allocator.free(old_label);
    }

    /// Move one stable tab record to its final zero-based sidebar index.
    pub fn moveTab(self: *Workspace, id: TabId, final_index: usize) MoveTabError!void {
        const current_index = self.tabIndex(id) orelse return error.UnknownTab;
        if (final_index >= self.tabs.items.len) return error.InvalidIndex;
        if (current_index == final_index) return;
        const tab_record = self.tabs.orderedRemove(current_index);
        self.tabs.insertAssumeCapacity(final_index, tab_record);
    }

    /// Focused pane in a tab, or null when the tab id is unknown.
    pub fn focusedPaneId(self: *const Workspace, tab_id: TabId) ?PaneId {
        const tab_record = self.tab(tab_id) orelse return null;
        return tab_record.focused_pane_id;
    }

    /// Session currently receiving terminal input in a tab.
    pub fn focusedPaneSessionId(self: *const Workspace, tab_id: TabId) ?session.SessionId {
        const tab_record = self.tab(tab_id) orelse return null;
        const leaf = findPaneConst(tab_record.root, tab_record.focused_pane_id) orelse return null;
        return leaf.session_id;
    }

    /// Session presented by one pane id in one tab.
    pub fn paneSessionId(
        self: *const Workspace,
        tab_id: TabId,
        pane_id: PaneId,
    ) ?session.SessionId {
        const tab_record = self.tab(tab_id) orelse return null;
        const leaf = findPaneConst(tab_record.root, pane_id) orelse return null;
        return leaf.session_id;
    }

    /// Find the visible pane that presents a session across all tabs.
    pub fn paneForSession(self: *const Workspace, session_id: session.SessionId) ?PaneLocation {
        for (self.tabs.items) |tab_record| {
            const pane_id = findSessionPane(tab_record.root, session_id) orelse continue;
            return .{ .tab_id = tab_record.id_value, .pane_id = pane_id };
        }
        return null;
    }

    /// Write all visible pane rectangles in tree order without allocation.
    /// When zoomed, only the zoomed leaf is visible and fills `bounds`.
    pub fn layoutPanes(
        self: *const Workspace,
        tab_id: TabId,
        bounds: CellRect,
        output: []PaneLayout,
    ) LayoutError!usize {
        const tab_record = self.tab(tab_id) orelse return error.UnknownTab;
        if (tab_record.zoomed_pane_id) |zoomed_id| {
            if (!validCellRect(bounds) or
                bounds.cols < min_pane_cols or bounds.rows < min_pane_rows)
            {
                return error.InvalidGeometry;
            }
            if (output.len < 1) return error.BufferTooSmall;
            const leaf = findPaneConst(tab_record.root, zoomed_id) orelse return error.InvalidGeometry;
            output[0] = .{
                .pane_id = leaf.id,
                .session_id = leaf.session_id,
                .rect = bounds,
                .focused = leaf.id == tab_record.focused_pane_id,
            };
            return 1;
        }
        if (!treeFits(tab_record.root, bounds)) return error.InvalidGeometry;
        const count = countPaneLeaves(tab_record.root);
        if (output.len < count) return error.BufferTooSmall;
        var index: usize = 0;
        writePaneLayouts(tab_record.root, bounds, tab_record.focused_pane_id, output, &index);
        return index;
    }

    /// Write all visible divider rectangles in tree order without allocation.
    /// A zoomed tab has no visible divider.
    pub fn layoutDividers(
        self: *const Workspace,
        tab_id: TabId,
        bounds: CellRect,
        output: []DividerLayout,
    ) LayoutError!usize {
        const tab_record = self.tab(tab_id) orelse return error.UnknownTab;
        if (tab_record.zoomed_pane_id != null) return 0;
        if (!treeFits(tab_record.root, bounds)) return error.InvalidGeometry;
        const count = countPaneLeaves(tab_record.root) - 1;
        if (output.len < count) return error.BufferTooSmall;
        var index: usize = 0;
        writeDividerLayouts(tab_record.root, bounds, output, &index);
        return index;
    }

    fn paneSplitTarget(
        self: *Workspace,
        tab_id: TabId,
        pane_id: PaneId,
        split: PaneSplit,
        bounds: CellRect,
    ) error{ UnknownTab, UnknownPane, InvalidGeometry }!PaneSplitTarget {
        const tab_index = self.tabIndex(tab_id) orelse return error.UnknownTab;
        const tab_record = self.tabs.items[tab_index];
        if (!treeFits(tab_record.root, bounds)) return error.InvalidGeometry;
        const target = nodeForPane(tab_record.root, pane_id) orelse return error.UnknownPane;
        const target_rect = rectForPane(tab_record.root, pane_id, bounds) orelse return error.UnknownPane;
        const needed: u16 = min_pane_cols * 2 + 1;
        const enough_room = switch (split) {
            .right => target_rect.cols >= needed and target_rect.rows >= min_pane_rows,
            .down => target_rect.rows >= needed and target_rect.cols >= min_pane_cols,
        };
        if (!enough_room) return error.InvalidGeometry;
        return .{ .tab = tab_record, .node = target, .rect = target_rect };
    }

    fn commitPaneSplit(
        self: *Workspace,
        target: PaneSplitTarget,
        new_session_id: session.SessionId,
        split: PaneSplit,
        first: *PaneNode,
        second: *PaneNode,
    ) PaneId {
        const old_leaf = target.node.leaf;
        const new_pane_id = PaneId.fromOrdinal(self.next_pane_ordinal);
        const divider_id = DividerId.fromOrdinal(self.next_divider_ordinal);
        first.* = .{ .leaf = old_leaf };
        second.* = .{ .leaf = .{ .id = new_pane_id, .session_id = new_session_id } };
        const available: u32 = switch (split) {
            .right => @as(u32, target.rect.cols) - 1,
            .down => @as(u32, target.rect.rows) - 1,
        };
        target.node.* = .{ .branch = .{
            .id = divider_id,
            .split = split,
            .first_weight = available / 2,
            .total_weight = available,
            .first = first,
            .second = second,
        } };
        target.tab.focused_pane_id = new_pane_id;
        target.tab.zoomed_pane_id = null;
        self.next_pane_ordinal += 1;
        self.next_divider_ordinal += 1;
        return new_pane_id;
    }

    /// Split a leaf, placing `new_session_id` to its right or below it.
    /// Allocation and validation complete before the tree or monotonic ids
    /// change. The new pane receives focus and normal layout becomes visible.
    pub fn splitPane(
        self: *Workspace,
        tab_id: TabId,
        pane_id: PaneId,
        new_session_id: session.SessionId,
        split: PaneSplit,
        bounds: CellRect,
    ) SplitPaneError!PaneId {
        const split_target = try self.paneSplitTarget(tab_id, pane_id, split, bounds);

        const session_record = self.recordByIdConst(new_session_id) orelse return error.UnknownSession;
        if (session_record.kind == .scratchpad) return error.ScratchpadSession;
        if (session_record.live == null or session_record.lifecycle == .exited) return error.SessionExited;
        if (self.paneForSession(new_session_id) != null) return error.SessionAlreadyRegistered;
        if (self.next_pane_ordinal == std.math.maxInt(u32)) return error.PaneLimit;
        if (self.next_divider_ordinal == std.math.maxInt(u32)) return error.DividerLimit;

        const first = try self.allocator.create(PaneNode);
        errdefer self.allocator.destroy(first);
        const second = try self.allocator.create(PaneNode);
        errdefer self.allocator.destroy(second);

        return self.commitPaneSplit(split_target, new_session_id, split, first, second);
    }

    /// Atomically create a childless non-scratchpad session and present it in
    /// a new pane. Geometry and limits are validated and every allocation is
    /// completed before the session registry, pane tree, monotonic ids, focus,
    /// or zoom state changes. On success the returned ids both become live;
    /// on any error neither id has existed and neither is consumed.
    pub fn createPaneSession(
        self: *Workspace,
        tab_id: TabId,
        pane_id: PaneId,
        kind: session.Session.Kind,
        size: term.GridSize,
        split: PaneSplit,
        bounds: CellRect,
    ) CreatePaneSessionError!CreatedPane {
        const split_target = try self.paneSplitTarget(tab_id, pane_id, split, bounds);
        if (kind == .scratchpad) return error.ScratchpadSession;
        if (self.sessions.items.len >= std.math.maxInt(u32)) return error.SessionLimit;
        if (self.next_pane_ordinal == std.math.maxInt(u32)) return error.PaneLimit;
        if (self.next_divider_ordinal == std.math.maxInt(u32)) return error.DividerLimit;

        try self.sessions.ensureUnusedCapacity(self.allocator, 1);
        const session_record = try self.allocator.create(SessionRecord);
        errdefer self.allocator.destroy(session_record);
        const first = try self.allocator.create(PaneNode);
        errdefer self.allocator.destroy(first);
        const second = try self.allocator.create(PaneNode);
        errdefer self.allocator.destroy(second);

        // No fallible work follows successful terminal construction, so the
        // session and pane enter their owner registries as one transaction.
        const live = try session.Session.init(self.io, self.allocator, kind, size);
        const session_id = session.SessionId.fromOrdinal(@intCast(self.sessions.items.len));
        session_record.* = .{
            .id = session_id,
            .kind = kind,
            .lifecycle = .starting,
            .live = live,
        };
        self.sessions.appendAssumeCapacity(session_record);
        const new_pane_id = self.commitPaneSplit(split_target, session_id, split, first, second);
        return .{ .pane_id = new_pane_id, .session_id = session_id };
    }

    /// Focus an existing leaf. If the tab is zoomed, zoom follows the newly
    /// focused leaf so input and the sole visible terminal stay aligned.
    pub fn focusPane(self: *Workspace, tab_id: TabId, pane_id: PaneId) PaneLookupError!void {
        const tab_index = self.tabIndex(tab_id) orelse return error.UnknownTab;
        const tab_record = self.tabs.items[tab_index];
        if (findPaneConst(tab_record.root, pane_id) == null) return error.UnknownPane;
        tab_record.focused_pane_id = pane_id;
        if (tab_record.zoomed_pane_id != null) tab_record.zoomed_pane_id = pane_id;
    }

    /// Move focus to the best pane in a spatial direction. Returns false at a
    /// layout edge or while zoomed, without changing focus.
    pub fn focusPaneDirection(
        self: *Workspace,
        tab_id: TabId,
        direction: PaneDirection,
        bounds: CellRect,
    ) FocusPaneError!bool {
        const tab_index = self.tabIndex(tab_id) orelse return error.UnknownTab;
        const tab_record = self.tabs.items[tab_index];
        if (tab_record.zoomed_pane_id != null) return false;
        if (!treeFits(tab_record.root, bounds)) return error.InvalidGeometry;
        const source = rectForPane(tab_record.root, tab_record.focused_pane_id, bounds) orelse
            return error.UnknownPane;
        var search: DirectionSearch = .{
            .source = source,
            .direction = direction,
            .source_id = tab_record.focused_pane_id,
        };
        searchDirection(tab_record.root, bounds, &search);
        const next = search.best_id orelse return false;
        tab_record.focused_pane_id = next;
        return true;
    }

    /// Move one divider by a signed number of cells. Positive values move it
    /// right or down; negative values move it left or up. Leaf minimums clamp
    /// the result, and the return value says whether geometry changed.
    pub fn resizeDivider(
        self: *Workspace,
        tab_id: TabId,
        divider_id: DividerId,
        delta: i32,
        bounds: CellRect,
    ) ResizePaneError!bool {
        const tab_index = self.tabIndex(tab_id) orelse return error.UnknownTab;
        const tab_record = self.tabs.items[tab_index];
        if (tab_record.zoomed_pane_id != null) return false;
        if (!treeFits(tab_record.root, bounds)) return error.InvalidGeometry;
        return resizeDividerInTree(tab_record.root, divider_id, delta, bounds) orelse
            error.UnknownDivider;
    }

    /// Grow a pane toward one edge by `cells`, resizing its nearest divider.
    /// Returns false when that pane has no divider on the requested edge or
    /// when minimum sizes already clamp it.
    pub fn resizePaneEdge(
        self: *Workspace,
        tab_id: TabId,
        pane_id: PaneId,
        direction: PaneDirection,
        cells: u16,
        bounds: CellRect,
    ) ResizePaneError!bool {
        const tab_index = self.tabIndex(tab_id) orelse return error.UnknownTab;
        const tab_record = self.tabs.items[tab_index];
        if (findPaneConst(tab_record.root, pane_id) == null) return error.UnknownPane;
        const edge = paneEdge(tab_record.root, pane_id, direction) orelse return false;
        return self.resizeDivider(
            tab_id,
            edge.divider_id,
            edge.delta_sign * @as(i32, cells),
            bounds,
        );
    }

    /// Toggle the focused pane between normal layout and filling its tab.
    /// No session, node, divider, or layout weight is recreated.
    pub fn togglePaneZoom(self: *Workspace, tab_id: TabId) error{UnknownTab}!bool {
        const tab_index = self.tabIndex(tab_id) orelse return error.UnknownTab;
        const tab_record = self.tabs.items[tab_index];
        if (tab_record.zoomed_pane_id != null) {
            tab_record.zoomed_pane_id = null;
            return false;
        }
        tab_record.zoomed_pane_id = tab_record.focused_pane_id;
        return true;
    }

    /// Set the divider directly above a leaf to give the parent's first child
    /// `ratio` of the space beside it (TASK-65 restore). Restore calls it on
    /// the pane a split just created, whose parent is that new divider. Like
    /// every weight, it is clamped to the leaf minimums at layout time, so it
    /// needs no geometry. A ratio outside `persistence.min_ratio..persistence.max_ratio`
    /// (including NaN) is refused.
    pub fn setPaneSplitRatio(
        self: *Workspace,
        tab_id: TabId,
        pane_id: PaneId,
        ratio: f32,
    ) error{ UnknownTab, UnknownPane, NotSplit, InvalidRatio }!void {
        if (!(ratio >= persistence.min_ratio and ratio <= persistence.max_ratio)) return error.InvalidRatio;
        const tab_index = self.tabIndex(tab_id) orelse return error.UnknownTab;
        const tab_record = self.tabs.items[tab_index];
        if (findPaneConst(tab_record.root, pane_id) == null) return error.UnknownPane;
        const parent = parentForPane(tab_record.root, pane_id) orelse return error.NotSplit;
        const branch = &parent.parent.branch;
        branch.total_weight = ratio_weight_total;
        branch.first_weight = @intFromFloat(@round(ratio * @as(f32, ratio_weight_total)));
    }

    /// The divider weight scale `setPaneSplitRatio` writes: four decimals,
    /// the precision the state file keeps.
    const ratio_weight_total: u32 = 10_000;

    /// Capture this workspace's persistent layout into `arena` (TASK-65):
    /// tab order, user-chosen tab names, every pane tree with split ratios
    /// and each leaf's tracked OSC 7 cwd (the workspace cwd when none was
    /// reported), focus, zoom, the active tab, and the SSH target. Terminal
    /// contents are never read. `scratchpad_percent` is presentation state
    /// and is left null for the app to fill.
    pub fn captureState(self: *const Workspace, arena: Allocator) Allocator.Error!persistence.WorkspaceState {
        const cwd = try arena.dupe(u8, self.cwd_bytes);
        const kind: persistence.ContextKind = switch (self.contextKind()) {
            .local => .local,
            .ssh => .ssh,
            .wsl => .wsl,
        };
        var target: ?persistence.SshTarget = null;
        if (ssh.SshContext.fromContext(&self.context)) |context| {
            const options = try arena.alloc([]const u8, context.options.len);
            for (context.options, options) |option, *out| out.* = try arena.dupe(u8, option);
            target = .{
                .destination = try arena.dupe(u8, context.destination),
                .port = context.port,
                .options = options,
            };
        }
        const tabs = try arena.alloc(persistence.TabState, self.tabs.items.len);
        var active_tab: ?usize = null;
        for (self.tabs.items, tabs, 0..) |tab_record, *out, index| {
            if (self.active_tab_id == tab_record.id_value) active_tab = index;
            var walk: CaptureWalk = .{ .focused = tab_record.focused_pane_id };
            out.* = .{
                .name = if (tab_record.user_named) try arena.dupe(u8, tab_record.name()) else null,
                .panes = try self.capturePanes(arena, tab_record.root, cwd, &walk),
                .focused_leaf = walk.focused_leaf,
                .zoomed = tab_record.zoomed_pane_id != null,
            };
        }
        return .{
            .name = try arena.dupe(u8, self.name_bytes),
            .kind = kind,
            .cwd = cwd,
            .ssh = target,
            .active_tab = active_tab,
            .tabs = tabs,
        };
    }

    const CaptureWalk = struct {
        focused: PaneId,
        next_leaf: usize = 0,
        focused_leaf: usize = 0,
    };

    fn capturePanes(
        self: *const Workspace,
        arena: Allocator,
        node: *const PaneNode,
        workspace_cwd: []const u8,
        walk: *CaptureWalk,
    ) Allocator.Error!persistence.PaneNode {
        switch (node.*) {
            .leaf => |leaf| {
                if (leaf.id == walk.focused) walk.focused_leaf = walk.next_leaf;
                walk.next_leaf += 1;
                const record = self.recordByIdConst(leaf.session_id);
                const tracked: ?[]const u8 = if (record) |value|
                    if (value.live) |*live| live.workingDirectory() else null
                else
                    null;
                return .{ .leaf = .{
                    .cwd = if (tracked) |dir| try arena.dupe(u8, dir) else workspace_cwd,
                } };
            },
            .branch => |branch| {
                const first = try arena.create(persistence.PaneNode);
                first.* = try self.capturePanes(arena, branch.first, workspace_cwd, walk);
                const second = try arena.create(persistence.PaneNode);
                second.* = try self.capturePanes(arena, branch.second, workspace_cwd, walk);
                const share = @as(f32, @floatFromInt(branch.first_weight)) /
                    @as(f32, @floatFromInt(branch.total_weight));
                return .{ .split = .{
                    .direction = switch (branch.split) {
                        .right => .right,
                        .down => .down,
                    },
                    .ratio = std.math.clamp(share, persistence.min_ratio, persistence.max_ratio),
                    .first = first,
                    .second = second,
                } };
            },
        }
    }

    /// Close a non-final pane, release its session, and promote its sibling.
    /// A final leaf is left untouched and returns `.close_tab` so the caller
    /// can apply tab-level confirmation and selection policy.
    pub fn closePane(
        self: *Workspace,
        tab_id: TabId,
        pane_id: PaneId,
    ) ClosePaneError!ClosePaneResult {
        const tab_index = self.tabIndex(tab_id) orelse return error.UnknownTab;
        const tab_record = self.tabs.items[tab_index];
        const leaf = findPaneConst(tab_record.root, pane_id) orelse return error.UnknownPane;
        if (isLeaf(tab_record.root)) return .close_tab;
        const relation = parentForPane(tab_record.root, pane_id) orelse return error.UnknownPane;
        const replacement_focus = firstLeaf(relation.sibling).id;
        const closing_session_id = leaf.session_id;
        relation.parent.* = relation.sibling.*;
        self.allocator.destroy(relation.sibling);
        self.allocator.destroy(relation.target);
        if (tab_record.focused_pane_id == pane_id) tab_record.focused_pane_id = replacement_focus;
        if (tab_record.zoomed_pane_id == pane_id) tab_record.zoomed_pane_id = null;
        try self.closeSession(closing_session_id);
        return .pane_closed;
    }

    /// Remove one tab and close every terminal session in its pane tree. Closing the active tab
    /// selects the next tab now occupying its index, or the previous tab when
    /// the removed tab was last. A final tab leaves no active selection.
    ///
    /// PTY signalling failures are returned only after the tab has been freed,
    /// its session is exited, and active selection is internally consistent.
    pub fn closeTab(self: *Workspace, id: TabId) CloseTabError!void {
        const index = self.tabIndex(id) orelse return error.UnknownTab;
        const tab_record = self.tabs.orderedRemove(index);
        if (self.active_tab_id == id) {
            self.active_tab_id = if (self.tabs.items.len == 0)
                null
            else if (index < self.tabs.items.len)
                self.tabs.items[index].id_value
            else
                self.tabs.items[self.tabs.items.len - 1].id_value;
        }
        var first_failure: ?CloseSessionError = null;
        self.closePaneSessions(tab_record.root, &first_failure);
        destroyPaneTree(self.allocator, tab_record.root);
        self.allocator.free(tab_record.label_bytes);
        self.allocator.destroy(tab_record);
        if (first_failure) |err| return err;
    }

    /// Currently selected tab, or null before the first registration.
    pub fn activeTabId(self: *const Workspace) ?TabId {
        return self.active_tab_id;
    }

    /// Select a registered tab without changing tab or session lifetime, and
    /// clear the attention the user has now visited.
    pub fn activateTab(self: *Workspace, id: TabId) ActivateTabError!void {
        const index = self.tabIndex(id) orelse return error.UnknownTab;
        self.active_tab_id = id;
        _ = self.tabs.items[index].setAttention(.none);
    }

    /// Mark output from a registered background session. Bell attention has
    /// precedence over ordinary activity until activation clears it. Unknown,
    /// unregistered and active sessions are deliberately ignored.
    ///
    /// Returns whether the retained state and cached display label changed.
    pub fn noteBackgroundActivity(
        self: *Workspace,
        session_id: session.SessionId,
        rang_bell: bool,
    ) bool {
        for (self.tabs.items) |tab_record| {
            if (findSessionPane(tab_record.root, session_id) == null) continue;
            if (self.active_tab_id == tab_record.id_value) return false;
            const attention: TabAttention = if (rang_bell)
                .bell
            else if (tab_record.attention_value == .bell)
                .bell
            else
                .activity;
            return tab_record.setAttention(attention);
        }
        return false;
    }

    /// Live session presented by the active tab. A tab whose session was
    /// closed outside tab lifecycle work has no active session.
    pub fn activeSessionId(self: *const Workspace) ?session.SessionId {
        const active_id = self.active_tab_id orelse return null;
        const active_tab = self.tab(active_id) orelse return null;
        const pane = findPaneConst(active_tab.root, active_tab.focused_pane_id) orelse return null;
        const session_record = self.recordByIdConst(pane.session_id) orelse return null;
        if (session_record.live == null or session_record.lifecycle == .exited) return null;
        return pane.session_id;
    }

    /// Number of records that still own a live terminal, including the
    /// childless scratchpad. Closing a session decrements this count.
    pub fn sessionCount(self: *const Workspace) usize {
        var count: usize = 0;
        for (self.sessions.items) |record| {
            if (record.live != null) count += 1;
        }
        return count;
    }

    /// Number of ids ever issued. Closed ids remain registered as exited and
    /// are never reused.
    pub fn registeredSessionCount(self: *const Workspace) usize {
        return self.sessions.items.len;
    }

    /// Borrow a live stable session, or null for an unknown or exited id.
    pub fn sessionById(self: *Workspace, id: session.SessionId) ?*session.Session {
        const record = self.recordById(id) orelse return null;
        return if (record.live) |*live| live else null;
    }

    /// Return the immutable kind retained even after a session exits.
    pub fn sessionKind(self: *const Workspace, id: session.SessionId) ?session.Session.Kind {
        const record = self.recordByIdConst(id) orelse return null;
        return record.kind;
    }

    /// Return lifecycle state retained even after a session exits.
    pub fn sessionLifecycle(self: *const Workspace, id: session.SessionId) ?session.Lifecycle {
        const record = self.recordByIdConst(id) orelse return null;
        return record.lifecycle;
    }

    /// Whether any live registry entry currently owns a PTY.
    pub fn hasAttachedChild(self: *const Workspace) bool {
        for (self.sessions.items) |record| {
            const live = if (record.live) |*value| value else continue;
            if (live.child() != null) return true;
        }
        return false;
    }

    /// Whether any live session requests another owner-thread service pass.
    /// Session owns exited-child quiescence and response readiness; this
    /// aggregate stays nonblocking and allocation-free for event-loop polling.
    pub fn needsPump(self: *Workspace) bool {
        for (self.sessions.items) |record| {
            const live = if (record.live) |*value| value else continue;
            if (live.needsPump()) return true;
        }
        return false;
    }

    /// Create a childless human or agent record without blocking on a spawn.
    /// Scratchpad creation is intentionally impossible; the one scratchpad
    /// already exists from `init`.
    pub fn createSession(
        self: *Workspace,
        kind: session.Session.Kind,
        size: term.GridSize,
    ) CreateSessionError!session.SessionId {
        if (kind == .scratchpad) return error.ScratchpadAlreadyExists;
        if (self.sessions.items.len >= std.math.maxInt(u32)) return error.SessionLimit;

        try self.sessions.ensureUnusedCapacity(self.allocator, 1);
        const record = try self.allocator.create(SessionRecord);
        errdefer self.allocator.destroy(record);

        const live = try session.Session.init(self.io, self.allocator, kind, size);

        const id = session.SessionId.fromOrdinal(@intCast(self.sessions.items.len));
        record.* = .{
            .id = id,
            .kind = kind,
            .lifecycle = .starting,
            .live = live,
        };
        self.sessions.appendAssumeCapacity(record);
        return id;
    }

    /// Build the request an IO worker passes to `contextRef().spawn`. The cwd
    /// always comes from this workspace and the size from the registered
    /// session, so neither can drift while callers prepare a local/remote job.
    /// The returned slices borrow the workspace and `process` until spawn
    /// returns.
    pub fn spawnRequest(
        self: *const Workspace,
        id: session.SessionId,
        process: ProcessSpec,
    ) SpawnRequestError!pty.SpawnRequest {
        const record = self.recordByIdConst(id) orelse return error.SessionNotFound;
        const live = if (record.live) |*value| value else return error.SessionNotFound;
        if (record.lifecycle != .starting or live.child() != null) return error.SessionAlreadyStarted;
        const size = live.terminalConst().gridSize();
        return .{
            .argv = process.argv,
            .env = process.env,
            .cwd = self.cwd_bytes,
            .size = pty.WindowSize.init(size.rows, size.cols),
        };
    }

    /// Transfer a worker-spawned PTY into a starting session on its owner
    /// thread. On error, ownership remains with the caller.
    pub fn attachChild(self: *Workspace, id: session.SessionId, child: pty.Pty) AttachChildError!void {
        const record = self.recordById(id) orelse return error.SessionNotFound;
        const live = if (record.live) |*value| value else return error.SessionNotFound;
        if (record.lifecycle != .starting or live.child() != null) return error.SessionAlreadyStarted;
        live.attachChild(child) catch return error.SessionAlreadyStarted;
        record.lifecycle = .running;
    }

    /// Build a worker request for a fresh scratchpad child without disturbing
    /// the currently running scratchpad. The returned slices borrow the
    /// workspace and `process` until spawning finishes. A later owner-thread
    /// call to `replaceScratchpad` performs the ownership transfer.
    pub fn scratchpadRestartRequest(
        self: *const Workspace,
        process: ProcessSpec,
    ) ScratchpadRestartRequestError!pty.SpawnRequest {
        const record = self.recordByIdConst(self.scratchpad_id) orelse
            return error.ScratchpadNotRunning;
        const live = if (record.live) |*value| value else return error.ScratchpadNotRunning;
        if (record.lifecycle != .running or live.child() == null)
            return error.ScratchpadNotRunning;
        const size = live.terminalConst().gridSize();
        return .{
            .argv = process.argv,
            .env = process.env,
            .cwd = self.cwd_bytes,
            .size = pty.WindowSize.init(size.rows, size.cols),
        };
    }

    /// Atomically replace the running scratchpad terminal and child while
    /// preserving its permanent session id and `running` lifecycle.
    ///
    /// Before commit, the old scratchpad remains untouched and ownership of
    /// `child` remains with the caller on every error. The fresh PTY is resized
    /// to the scratchpad's current size before it transfers into a fresh
    /// terminal. After commit this function cannot fail: a hangup error from
    /// releasing the old child is reported in the successful result, while the
    /// new scratchpad remains valid and owned by the workspace.
    pub fn replaceScratchpad(
        self: *Workspace,
        child: pty.Pty,
    ) ReplaceScratchpadError!ScratchpadReplacement {
        const record = self.recordById(self.scratchpad_id) orelse
            return error.ScratchpadNotRunning;
        const current = if (record.live) |*value| value else return error.ScratchpadNotRunning;
        if (record.lifecycle != .running or current.child() == null)
            return error.ScratchpadNotRunning;

        const size = current.terminalConst().gridSize();
        var replacement = try session.Session.init(
            self.io,
            self.allocator,
            .scratchpad,
            size,
        );
        child.resize(pty.WindowSize.init(size.rows, size.cols)) catch |err| {
            deinitChildlessReplacement(&replacement);
            return err;
        };
        replacement.attachChild(child) catch |err| {
            deinitChildlessReplacement(&replacement);
            return err;
        };

        var previous = record.live.?;
        record.live = replacement;
        record.lifecycle = .running;

        var result: ScratchpadReplacement = .{};
        previous.deinit() catch |err| {
            result.old_child_deinit_error = err;
        };
        return result;
    }

    /// Close one non-scratchpad session. The stable id remains as an exited
    /// record, while all terminal and PTY ownership is released before an
    /// optional hangup failure is returned.
    pub fn closeSession(self: *Workspace, id: session.SessionId) CloseSessionError!void {
        if (id == self.scratchpad_id) return error.ScratchpadCannotClose;
        const record = self.recordById(id) orelse return error.SessionNotFound;
        const live = if (record.live) |*value| value else return error.SessionNotFound;

        record.lifecycle = .closing;
        var failure: ?pty.Error = null;
        live.deinit() catch |err| {
            failure = err;
        };
        record.live = null;
        record.lifecycle = .exited;
        if (failure) |err| return err;
    }

    /// Service both directions of every live session once without blocking or
    /// allocating, then synchronously deliver each feed's terminal events.
    pub fn pump(
        self: *Workspace,
        io_buffer: []u8,
        response_buffer: []u8,
        event_sink: EventSink,
    ) PumpResult {
        return self.pumpExcept(null, io_buffer, response_buffer, event_sink);
    }

    /// Service the sessions present on entry, except `skip_id`, once each.
    ///
    /// A callback may create sessions or close the current or another session;
    /// newly created records wait until the next pump. It must not deinitialize
    /// the workspace. Event payloads are valid on callback entry and until the
    /// callback feeds or closes that same session. The pump never retains a
    /// session pointer across the callback and reloads every later record by
    /// index, so an ArrayList growth or a close cannot invalidate its walk.
    /// Output is fed, events are taken, and responses are flushed before the
    /// callback. The first PTY write failure is retained while the remaining
    /// initially-present records are still serviced.
    pub fn pumpExcept(
        self: *Workspace,
        skip_id: ?session.SessionId,
        io_buffer: []u8,
        response_buffer: []u8,
        event_sink: EventSink,
    ) PumpResult {
        var result: PumpResult = .{};
        const initial_count = self.sessions.items.len;
        var index: usize = 0;
        while (index < initial_count) : (index += 1) {
            if (index >= self.sessions.items.len) break;
            const record = self.sessions.items[index];
            const id = record.id;
            if (skip_id != null and skip_id.? == id) continue;
            const live = if (record.live) |*value| value else continue;
            result.sessions_visited +|= 1;
            const drained = live.drainChildOutput(io_buffer);
            result.bytes_drained +|= drained;
            const events = if (drained != 0) live.terminal().takeEvents() else &.{};

            const flushed = live.flushChildResponses(response_buffer) catch |err| {
                if (result.first_error == null) result.first_error = err;
                result.response_bytes_pending +|= live.pendingResponseBytes();
                if (drained != 0) event_sink.send(id, events);
                continue;
            };
            result.response_bytes_written +|= flushed.written;
            result.response_bytes_pending +|= flushed.pending;
            if (drained != 0) event_sink.send(id, events);
        }
        return result;
    }

    fn recordById(self: *Workspace, id: session.SessionId) ?*SessionRecord {
        const ordinal = id.ordinal();
        if (ordinal >= self.sessions.items.len) return null;
        const record = self.sessions.items[ordinal];
        if (record.id != id) return null;
        return record;
    }

    fn recordByIdConst(self: *const Workspace, id: session.SessionId) ?*const SessionRecord {
        const ordinal = id.ordinal();
        if (ordinal >= self.sessions.items.len) return null;
        const record = self.sessions.items[ordinal];
        if (record.id != id) return null;
        return record;
    }

    fn closePaneSessions(
        self: *Workspace,
        node: *const PaneNode,
        first_failure: *?CloseSessionError,
    ) void {
        switch (node.*) {
            .leaf => |leaf| self.closeSession(leaf.session_id) catch |err| {
                if (first_failure.* == null) first_failure.* = err;
            },
            .branch => |branch| {
                self.closePaneSessions(branch.first, first_failure);
                self.closePaneSessions(branch.second, first_failure);
            },
        }
    }
};

fn deinitChildlessReplacement(replacement: *session.Session) void {
    // This helper is called only before `attachChild` succeeds, so the session
    // has no PTY and `Session.deinit` has no fallible operation. Keep a log in
    // case that ownership contract changes instead of turning cleanup into a
    // process crash.
    replacement.deinit() catch |err| {
        log.err(
            "childless scratchpad replacement cleanup failed: {s}",
            .{@errorName(err)},
        );
    };
}

/// Stable identity of one workspace in a WorkspaceRegistry.
///
/// Values are one-based, monotonic, and never reused after removal. Display
/// names remain mutable and are deliberately not identities.
pub const WorkspaceKey = enum(u64) {
    first = 1,
    _,

    /// Build a key for a zero-based allocation ordinal.
    pub fn fromOrdinal(ordinal_value: u64) WorkspaceKey {
        std.debug.assert(ordinal_value < std.math.maxInt(u64));
        return @enumFromInt(ordinal_value + 1);
    }

    /// Return the zero-based allocation ordinal.
    pub fn ordinal(self: WorkspaceKey) u64 {
        return @intFromEnum(self) - 1;
    }
};

/// Owning, ordered collection of independent workspaces.
///
/// Each record has a stable heap address until removal, even when the ordered
/// pointer array grows. insert accepts an already-initialized workspace by
/// pointer and transfers it only after every fallible check and allocation has
/// succeeded. A successful insert sets the caller's value to undefined.
pub const WorkspaceRegistry = struct {
    pub const InsertError = Allocator.Error || error{
        DuplicateName,
        WorkspaceLimit,
    };
    pub const RenameError = Allocator.Error || WorkspaceId.Error || error{
        UnknownWorkspace,
        DuplicateName,
    };
    pub const ActivateError = error{UnknownWorkspace};
    pub const RemoveError = error{UnknownWorkspace};

    /// Result of committed workspace removal. Teardown failures belong to the
    /// removed workspace; the returned active selection and remaining registry
    /// are already valid.
    pub const RemoveResult = struct {
        active_key: ?WorkspaceKey,
        teardown_error: ?pty.Error = null,
    };

    const Record = struct {
        key: WorkspaceKey,
        workspace: Workspace,
    };

    allocator: Allocator,
    records: std.ArrayList(*Record) = .empty,
    next_key_value: u64 = @intFromEnum(WorkspaceKey.first),
    active_key: ?WorkspaceKey = null,

    /// Create an empty registry. The allocator must outlive the registry's
    /// final deinit; each workspace retains its own existing allocator and IO
    /// lifetime requirements.
    pub fn init(allocator: Allocator) WorkspaceRegistry {
        return .{ .allocator = allocator };
    }

    /// Release every workspace in insertion order, continuing after teardown
    /// errors and returning the first PTY failure only after all records,
    /// sessions, contexts, names, and pointer storage have been released.
    pub fn deinit(self: *WorkspaceRegistry) pty.Error!void {
        var first_failure: ?pty.Error = null;
        for (self.records.items) |record| {
            record.workspace.deinit() catch |err| {
                if (first_failure == null) first_failure = err;
            };
            self.allocator.destroy(record);
        }
        self.records.deinit(self.allocator);
        self.* = undefined;
        if (first_failure) |err| return err;
    }

    /// Number of live workspace records in presentation order.
    pub fn count(self: *const WorkspaceRegistry) usize {
        return self.records.items.len;
    }

    /// Stable key at one presentation-order index.
    pub fn keyAt(self: *const WorkspaceRegistry, index: usize) ?WorkspaceKey {
        if (index >= self.records.items.len) return null;
        return self.records.items[index].key;
    }

    /// Mutable workspace at one presentation-order index. The returned pointer
    /// remains stable until that workspace is removed.
    pub fn at(self: *WorkspaceRegistry, index: usize) ?*Workspace {
        if (index >= self.records.items.len) return null;
        return &self.records.items[index].workspace;
    }

    /// Look up a mutable workspace by its stable key.
    pub fn byKey(self: *WorkspaceRegistry, key: WorkspaceKey) ?*Workspace {
        const index = self.indexOfKey(key) orelse return null;
        return &self.records.items[index].workspace;
    }

    /// Look up a stable key by a validated, trimmed display name.
    pub fn keyForName(self: *const WorkspaceRegistry, name: []const u8) ?WorkspaceKey {
        const identity = WorkspaceId.init(name) catch return null;
        for (self.records.items) |record| {
            if (std.mem.eql(u8, record.workspace.name(), identity.name)) return record.key;
        }
        return null;
    }

    /// Look up a mutable workspace by a validated, trimmed display name.
    pub fn byName(self: *WorkspaceRegistry, name: []const u8) ?*Workspace {
        const key = self.keyForName(name) orelse return null;
        return self.byKey(key);
    }

    /// Stable key of the selected workspace, or null while empty.
    pub fn activeKey(self: *const WorkspaceRegistry) ?WorkspaceKey {
        return self.active_key;
    }

    /// Selected mutable workspace, or null while empty.
    pub fn active(self: *WorkspaceRegistry) ?*Workspace {
        const key = self.active_key orelse return null;
        return self.byKey(key);
    }

    /// Atomically insert an initialized workspace.
    ///
    /// On every error the candidate remains owned and unchanged by its caller,
    /// no key is consumed, and visible registry order and selection are
    /// unchanged. On success ownership transfers and candidate is undefined.
    pub fn insert(self: *WorkspaceRegistry, candidate: *Workspace) InsertError!WorkspaceKey {
        if (self.next_key_value == 0) return error.WorkspaceLimit;
        if (self.keyForName(candidate.name()) != null) return error.DuplicateName;

        try self.records.ensureUnusedCapacity(self.allocator, 1);
        const record = try self.allocator.create(Record);
        const key: WorkspaceKey = @enumFromInt(self.next_key_value);
        record.* = .{
            .key = key,
            .workspace = candidate.*,
        };

        self.records.appendAssumeCapacity(record);
        candidate.* = undefined;
        self.next_key_value +%= 1;
        if (self.active_key == null) self.active_key = key;
        return key;
    }

    /// Replace one display name with a validated, trimmed owned copy.
    ///
    /// Duplicate names are rejected without allocating. Allocation completes
    /// before the old name is released, so all errors preserve registry state.
    pub fn rename(
        self: *WorkspaceRegistry,
        key: WorkspaceKey,
        new_name: []const u8,
    ) RenameError!void {
        const index = self.indexOfKey(key) orelse return error.UnknownWorkspace;
        const identity = try WorkspaceId.init(new_name);
        for (self.records.items, 0..) |record, candidate_index| {
            if (candidate_index == index) continue;
            if (std.mem.eql(u8, record.workspace.name(), identity.name)) {
                return error.DuplicateName;
            }
        }

        const target = &self.records.items[index].workspace;
        if (std.mem.eql(u8, target.name(), identity.name)) return;
        const copied = try target.allocator.dupe(u8, identity.name);
        target.allocator.free(target.name_bytes);
        target.name_bytes = copied;
    }

    /// Select a workspace without changing its order or owned state.
    pub fn activate(self: *WorkspaceRegistry, key: WorkspaceKey) ActivateError!void {
        _ = self.indexOfKey(key) orelse return error.UnknownWorkspace;
        self.active_key = key;
    }

    /// Capture every live workspace, in presentation order, with the active
    /// selection, as an owned `persistence.Snapshot` (TASK-65). Owner thread only.
    /// The theme, window geometry, save time and each workspace's scratchpad
    /// size belong to the app, which fills them through `Owned.allocator()`
    /// before `persistence.encode`. A layout beyond the state file's bounds is
    /// still captured; `persistence.encode` reports it as unrepresentable.
    pub fn snapshot(self: *const WorkspaceRegistry, allocator: Allocator) Allocator.Error!persistence.Owned {
        var owned: persistence.Owned = .{ .arena = .init(allocator), .snapshot = .{} };
        errdefer owned.arena.deinit();
        const arena = owned.arena.allocator();
        const workspaces = try arena.alloc(persistence.WorkspaceState, self.records.items.len);
        for (self.records.items, workspaces) |record, *out| {
            out.* = try record.workspace.captureState(arena);
        }
        owned.snapshot.workspaces = workspaces;
        if (self.active_key) |key| owned.snapshot.active_workspace = self.indexOfKey(key);
        return owned;
    }

    /// Remove and fully deinitialize a workspace.
    ///
    /// Removing the active record selects the next record now at its index, or
    /// the previous record when the removed one was last. Removing the final
    /// record selects null. A PTY teardown error is reported in the result only
    /// after the record has been removed and all of its ownership released.
    pub fn remove(self: *WorkspaceRegistry, key: WorkspaceKey) RemoveError!RemoveResult {
        const index = self.indexOfKey(key) orelse return error.UnknownWorkspace;
        const record = self.records.orderedRemove(index);
        if (self.active_key == key) {
            self.active_key = if (self.records.items.len == 0)
                null
            else if (index < self.records.items.len)
                self.records.items[index].key
            else
                self.records.items[self.records.items.len - 1].key;
        }

        const teardown_error: ?pty.Error = result: {
            record.workspace.deinit() catch |err| break :result err;
            break :result null;
        };
        self.allocator.destroy(record);
        return .{
            .active_key = self.active_key,
            .teardown_error = teardown_error,
        };
    }

    fn indexOfKey(self: *const WorkspaceRegistry, key: WorkspaceKey) ?usize {
        for (self.records.items, 0..) |record, index| {
            if (record.key == key) return index;
        }
        return null;
    }
};

const fake_capacity = 8;

const FakeAudit = struct {
    spawn_count: usize = 0,
    kill_count: usize = 0,
    destroy_count: usize = 0,
    write_count: usize = 0,
    resize_count: usize = 0,
    written: [512]u8 = undefined,
    written_len: usize = 0,
    context_destroyed: bool = false,
    context_destroyed_with_live_children: bool = false,
    last_cwd: [256]u8 = undefined,
    last_cwd_len: usize = 0,
    outputs: [fake_capacity][]const u8 = .{""} ** fake_capacity,
    write_limits: [fake_capacity][]const usize = .{&[_]usize{}} ** fake_capacity,
    fail_write: [fake_capacity]bool = .{false} ** fake_capacity,
    fail_resize: [fake_capacity]bool = .{false} ** fake_capacity,
    fail_hangup: [fake_capacity]bool = .{false} ** fake_capacity,
    resize_rows: [fake_capacity]u16 = .{0} ** fake_capacity,
    resize_cols: [fake_capacity]u16 = .{0} ** fake_capacity,

    fn accepted(self: *const FakeAudit) []const u8 {
        return self.written[0..self.written_len];
    }
};

const FakeContext = struct {
    allocator: Allocator,
    audit: *FakeAudit,
    context_kind: ExecutionContextKind,

    const vtable: ExecutionContext.VTable = .{
        .spawn = spawn,
        .kind = kind,
        .destroy = destroy,
    };

    fn create(allocator: Allocator, audit: *FakeAudit, context_kind: ExecutionContextKind) !ExecutionContext {
        const self = try allocator.create(FakeContext);
        self.* = .{
            .allocator = allocator,
            .audit = audit,
            .context_kind = context_kind,
        };
        return ExecutionContext.initOwned(self, &vtable);
    }

    fn spawn(ptr: *anyopaque, request: pty.SpawnRequest) pty.Error!pty.Pty {
        const self: *FakeContext = @ptrCast(@alignCast(ptr));
        if (self.audit.spawn_count >= fake_capacity or request.cwd.len > self.audit.last_cwd.len) {
            return error.SystemError;
        }
        const index = self.audit.spawn_count;
        const child = try self.allocator.create(FakePty);
        child.* = .{
            .allocator = self.allocator,
            .audit = self.audit,
            .index = index,
            .pending = self.audit.outputs[index],
            .write_limits = self.audit.write_limits[index],
            .fail_write = self.audit.fail_write[index],
            .fail_resize = self.audit.fail_resize[index],
            .fail_hangup = self.audit.fail_hangup[index],
        };
        self.audit.spawn_count += 1;
        @memcpy(self.audit.last_cwd[0..request.cwd.len], request.cwd);
        self.audit.last_cwd_len = request.cwd.len;
        return child.asPty();
    }

    fn kind(ptr: *const anyopaque) ExecutionContextKind {
        const self: *const FakeContext = @ptrCast(@alignCast(ptr));
        return self.context_kind;
    }

    fn destroy(ptr: *anyopaque) void {
        const self: *FakeContext = @ptrCast(@alignCast(ptr));
        self.audit.context_destroyed_with_live_children = self.audit.destroy_count != self.audit.spawn_count;
        self.audit.context_destroyed = true;
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

const FakePty = struct {
    allocator: Allocator,
    audit: *FakeAudit,
    index: usize,
    pending: []const u8,
    write_limits: []const usize,
    write_index: usize = 0,
    fail_write: bool,
    fail_resize: bool,
    fail_hangup: bool,

    const vtable: pty.Pty.VTable = .{
        .write = write,
        .resize = resize,
        .kill = kill,
        .takeBytes = takeBytes,
        .state = state,
        .waitReadable = waitReadable,
        .destroy = destroy,
    };

    fn asPty(self: *FakePty) pty.Pty {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn write(ptr: *anyopaque, bytes: []const u8) pty.Error!usize {
        const self: *FakePty = @ptrCast(@alignCast(ptr));
        self.audit.write_count += 1;
        if (self.fail_write) return error.SystemError;
        const limit = if (self.write_index < self.write_limits.len)
            self.write_limits[self.write_index]
        else
            bytes.len;
        self.write_index += 1;
        const count = @min(bytes.len, limit);
        if (self.audit.written.len - self.audit.written_len < count) return error.SystemError;
        @memcpy(self.audit.written[self.audit.written_len..][0..count], bytes[0..count]);
        self.audit.written_len += count;
        return count;
    }

    fn resize(ptr: *anyopaque, size: pty.WindowSize) pty.Error!void {
        const self: *FakePty = @ptrCast(@alignCast(ptr));
        self.audit.resize_count += 1;
        self.audit.resize_rows[self.index] = size.rows;
        self.audit.resize_cols[self.index] = size.cols;
        if (self.fail_resize) return error.SystemError;
    }

    fn kill(ptr: *anyopaque, signal: pty.Signal) pty.Error!void {
        const self: *FakePty = @ptrCast(@alignCast(ptr));
        self.audit.kill_count += 1;
        if (signal == .hangup and self.fail_hangup) return error.SystemError;
    }

    fn takeBytes(ptr: *anyopaque, dest: []u8) usize {
        const self: *FakePty = @ptrCast(@alignCast(ptr));
        const count = @min(dest.len, self.pending.len);
        @memcpy(dest[0..count], self.pending[0..count]);
        self.pending = self.pending[count..];
        return count;
    }

    fn state(_: *anyopaque) pty.ChildState {
        return .running;
    }

    fn waitReadable(ptr: *anyopaque, _: u32) bool {
        const self: *FakePty = @ptrCast(@alignCast(ptr));
        return self.pending.len != 0;
    }

    fn destroy(ptr: *anyopaque) void {
        const self: *FakePty = @ptrCast(@alignCast(ptr));
        self.audit.destroy_count += 1;
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

fn testProcess() ProcessSpec {
    return .{
        .argv = &.{"fake-shell"},
        .env = &.{"PATH=/test"},
    };
}

fn spawnAndAttach(workspace: *Workspace, id: session.SessionId) !void {
    const request = try workspace.spawnRequest(id, testProcess());
    const child = try workspace.contextRef().spawn(request);
    try workspace.attachChild(id, child);
}

fn insertFakeWorkspace(
    registry: *WorkspaceRegistry,
    io: std.Io,
    allocator: Allocator,
    audit: *FakeAudit,
    name: []const u8,
    cwd: []const u8,
    size: term.GridSize,
) !WorkspaceKey {
    const context = try FakeContext.create(allocator, audit, .local);
    var candidate = try Workspace.init(io, allocator, name, cwd, context, size);
    return registry.insert(&candidate) catch |err| {
        candidate.deinit() catch |cleanup_err| std.debug.panic(
            "workspace candidate cleanup failed: {s}",
            .{@errorName(cleanup_err)},
        );
        return err;
    };
}

fn destroyCallerOwnedTestChild(child: pty.Pty) void {
    child.kill(.hangup) catch |err| std.debug.panic(
        "caller-owned test child cleanup failed: {s}",
        .{@errorName(err)},
    );
    child.destroy();
}

const CapturedEvents = struct {
    calls: usize = 0,
    session_id: ?session.SessionId = null,
    title: [32]u8 = undefined,
    title_len: usize = 0,
    audit: ?*FakeAudit = null,
    write_count_during_callback: usize = 0,

    fn sink(self: *CapturedEvents) EventSink {
        return .{ .ptr = self, .on_events = capture };
    }

    fn capture(ptr: *anyopaque, id: session.SessionId, events: []const term.Event) void {
        const self: *CapturedEvents = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.session_id = id;
        if (self.audit) |audit| self.write_count_during_callback = audit.write_count;
        for (events) |event| switch (event) {
            .title => |title| {
                const count = @min(title.len, self.title.len);
                @memcpy(self.title[0..count], title[0..count]);
                self.title_len = count;
            },
            else => {},
        };
    }
};

const IgnoredEvents = struct {
    fn sink(self: *IgnoredEvents) EventSink {
        return .{ .ptr = self, .on_events = ignore };
    }

    fn ignore(_: *anyopaque, _: session.SessionId, _: []const term.Event) void {}
};

const MutatingEvents = struct {
    workspace: *Workspace,
    size: term.GridSize,
    mutate_id: session.SessionId,
    calls: usize = 0,
    created: ?session.SessionId = null,
    closed_current: bool = false,
    failed: bool = false,

    fn sink(self: *MutatingEvents) EventSink {
        return .{ .ptr = self, .on_events = mutate };
    }

    fn mutate(ptr: *anyopaque, id: session.SessionId, events: []const term.Event) void {
        const self: *MutatingEvents = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        // Consume borrowed payloads before closing the session that owns them.
        for (events) |event| switch (event) {
            .title => |title| {
                if (title.len == 0) self.failed = true;
            },
            else => {},
        };
        if (id != self.mutate_id) return;
        self.created = self.workspace.createSession(.agent_terminal, self.size) catch {
            self.failed = true;
            return;
        };
        self.workspace.closeSession(id) catch {
            self.failed = true;
            return;
        };
        self.closed_current = true;
    }
};

const primary_device_attributes = "\x1b[?62;22c";

test "workspace registry keeps records stable and workspace state independent" {
    const testing = std.testing;
    const first_size = try term.GridSize.init(40, 12);
    const second_size = try term.GridSize.init(50, 14);
    const bounds = try CellRect.init(0, 0, 31, 11);
    var first_audit: FakeAudit = .{};
    var second_audit: FakeAudit = .{};
    var registry = WorkspaceRegistry.init(testing.allocator);
    defer registry.deinit() catch |err| std.debug.panic(
        "workspace registry cleanup failed: {s}",
        .{@errorName(err)},
    );

    const first_key = try insertFakeWorkspace(
        &registry,
        testing.io,
        testing.allocator,
        &first_audit,
        "first",
        "/first",
        first_size,
    );
    const first_before_growth = registry.byKey(first_key).?;
    const second_key = try insertFakeWorkspace(
        &registry,
        testing.io,
        testing.allocator,
        &second_audit,
        "second",
        "/second",
        second_size,
    );

    try testing.expectEqual(WorkspaceKey.first, first_key);
    try testing.expectEqual(WorkspaceKey.fromOrdinal(1), second_key);
    try testing.expectEqual(@as(usize, 2), registry.count());
    try testing.expectEqual(first_key, registry.keyAt(0).?);
    try testing.expectEqual(second_key, registry.keyAt(1).?);
    try testing.expect(registry.keyAt(2) == null);
    try testing.expect(first_before_growth == registry.byKey(first_key).?);
    try testing.expect(registry.at(0).? == first_before_growth);
    try testing.expect(registry.byName(" second ").? == registry.byKey(second_key).?);
    try testing.expectEqual(first_key, registry.activeKey().?);

    const first = registry.byKey(first_key).?;
    const second = registry.byKey(second_key).?;
    try testing.expectEqual(session.SessionId.first, first.scratchpadId());
    try testing.expectEqual(session.SessionId.first, second.scratchpadId());
    try testing.expect(first.sessionById(first.scratchpadId()).? != second.sessionById(second.scratchpadId()).?);
    try testing.expectEqual(first_size, first.sessionById(first.scratchpadId()).?.terminalConst().gridSize());
    try testing.expectEqual(second_size, second.sessionById(second.scratchpadId()).?.terminalConst().gridSize());

    const first_tab = try first.createTab("first tab", first_size);
    const second_tab = try second.createTab("second tab", second_size);
    try testing.expectEqual(TabId.first, first_tab.tab_id);
    try testing.expectEqual(TabId.first, second_tab.tab_id);
    try testing.expectEqual(PaneId.first, first.focusedPaneId(first_tab.tab_id).?);
    try testing.expectEqual(PaneId.first, second.focusedPaneId(second_tab.tab_id).?);

    const extra_session = try first.createSession(.human_terminal, first_size);
    const extra_pane = try first.splitPane(
        first_tab.tab_id,
        PaneId.first,
        extra_session,
        .right,
        bounds,
    );
    try testing.expectEqual(PaneId.fromOrdinal(1), extra_pane);
    try testing.expectEqual(@as(usize, 2), first.tab(first_tab.tab_id).?.paneCount());
    try testing.expectEqual(@as(usize, 1), second.tab(second_tab.tab_id).?.paneCount());

    try registry.activate(second_key);
    try testing.expectEqual(second_key, registry.activeKey().?);
    try testing.expect(registry.active().? == second);
    try testing.expectEqual(@as(usize, 2), registry.byKey(first_key).?.tab(first_tab.tab_id).?.paneCount());
    try testing.expectEqualStrings("/first", first.workingDirectory());
    try testing.expectEqualStrings("/second", second.workingDirectory());
}

test "workspace registry validates copies and uniquely resolves mutable names" {
    const testing = std.testing;
    const size = try term.GridSize.init(24, 6);
    var alpha_audit: FakeAudit = .{};
    var beta_audit: FakeAudit = .{};
    var duplicate_audit: FakeAudit = .{};
    var registry = WorkspaceRegistry.init(testing.allocator);
    defer registry.deinit() catch |err| std.debug.panic(
        "workspace registry cleanup failed: {s}",
        .{@errorName(err)},
    );

    const alpha = try insertFakeWorkspace(
        &registry,
        testing.io,
        testing.allocator,
        &alpha_audit,
        "alpha",
        "/alpha",
        size,
    );
    const beta = try insertFakeWorkspace(
        &registry,
        testing.io,
        testing.allocator,
        &beta_audit,
        "beta",
        "/beta",
        size,
    );
    try testing.expectError(error.EmptyName, registry.rename(alpha, " \t "));
    try testing.expectError(error.DuplicateName, registry.rename(alpha, " beta "));
    try testing.expectEqualStrings("alpha", registry.byKey(alpha).?.name());
    try testing.expectEqualStrings("beta", registry.byKey(beta).?.name());

    var renamed = [_]u8{ ' ', 'g', 'a', 'm', 'm', 'a', ' ' };
    try registry.rename(alpha, &renamed);
    @memset(&renamed, 'x');
    try testing.expectEqualStrings("gamma", registry.byKey(alpha).?.name());
    try testing.expectEqual(alpha, registry.keyForName(" gamma ").?);
    try testing.expect(registry.keyForName(" \n ") == null);
    try testing.expect(registry.byName("alpha") == null);

    const duplicate_context = try FakeContext.create(testing.allocator, &duplicate_audit, .local);
    var duplicate = try Workspace.init(
        testing.io,
        testing.allocator,
        " gamma ",
        "/duplicate",
        duplicate_context,
        size,
    );
    defer duplicate.deinit() catch |err| std.debug.panic(
        "duplicate workspace cleanup failed: {s}",
        .{@errorName(err)},
    );
    try testing.expectError(error.DuplicateName, registry.insert(&duplicate));
    try testing.expectEqualStrings("gamma", duplicate.name());
    try testing.expect(!duplicate_audit.context_destroyed);
    try testing.expectEqual(@as(usize, 2), registry.count());
    try testing.expectEqual(alpha, registry.activeKey().?);

    const missing = WorkspaceKey.fromOrdinal(40);
    try testing.expectError(error.UnknownWorkspace, registry.rename(missing, "missing"));
    try testing.expectError(error.UnknownWorkspace, registry.activate(missing));
    try testing.expectError(error.UnknownWorkspace, registry.remove(missing));
    try testing.expectEqual(alpha, registry.activeKey().?);
    try testing.expectEqual(@as(usize, 2), registry.count());
}

test "workspace registry keys are not reused and active removal chooses next then previous" {
    const testing = std.testing;
    const size = try term.GridSize.init(24, 6);
    var audits = [_]FakeAudit{.{}} ** 5;
    var registry = WorkspaceRegistry.init(testing.allocator);
    defer registry.deinit() catch |err| std.debug.panic(
        "workspace registry cleanup failed: {s}",
        .{@errorName(err)},
    );

    const first = try insertFakeWorkspace(&registry, testing.io, testing.allocator, &audits[0], "one", "/one", size);
    const second = try insertFakeWorkspace(&registry, testing.io, testing.allocator, &audits[1], "two", "/two", size);
    const third = try insertFakeWorkspace(&registry, testing.io, testing.allocator, &audits[2], "three", "/three", size);
    try testing.expectEqual(first, registry.activeKey().?);

    try registry.activate(second);
    const removed_middle = try registry.remove(second);
    try testing.expectEqual(third, removed_middle.active_key.?);
    try testing.expect(removed_middle.teardown_error == null);
    try testing.expect(audits[1].context_destroyed);

    const removed_last = try registry.remove(third);
    try testing.expectEqual(first, removed_last.active_key.?);
    try testing.expect(removed_last.teardown_error == null);
    const fourth = try insertFakeWorkspace(&registry, testing.io, testing.allocator, &audits[3], "four", "/four", size);
    try testing.expectEqual(WorkspaceKey.fromOrdinal(3), fourth);
    try testing.expectEqual(first, registry.activeKey().?);

    const removed_inactive = try registry.remove(fourth);
    try testing.expectEqual(first, removed_inactive.active_key.?);
    const fifth = try insertFakeWorkspace(&registry, testing.io, testing.allocator, &audits[4], "five", "/five", size);
    try testing.expectEqual(WorkspaceKey.fromOrdinal(4), fifth);

    const removed_first = try registry.remove(first);
    try testing.expectEqual(fifth, removed_first.active_key.?);
    const removed_final = try registry.remove(fifth);
    try testing.expect(removed_final.active_key == null);
    try testing.expect(registry.activeKey() == null);
    try testing.expect(registry.active() == null);
    try testing.expectEqual(@as(usize, 0), registry.count());
}

test "workspace registry insert and rename allocation failures preserve state and identities" {
    const testing = std.testing;
    const size = try term.GridSize.init(24, 6);
    var registry_failing = testing.FailingAllocator.init(testing.allocator, .{});
    var insert_audit: FakeAudit = .{};
    var registry = WorkspaceRegistry.init(registry_failing.allocator());
    defer registry.deinit() catch |err| std.debug.panic(
        "workspace registry cleanup failed: {s}",
        .{@errorName(err)},
    );

    const insert_context = try FakeContext.create(testing.allocator, &insert_audit, .local);
    var candidate = try Workspace.init(
        testing.io,
        testing.allocator,
        "atomic insert",
        "/atomic",
        insert_context,
        size,
    );
    var candidate_owned = true;
    defer if (candidate_owned) candidate.deinit() catch |err| std.debug.panic(
        "workspace candidate cleanup failed: {s}",
        .{@errorName(err)},
    );

    registry_failing.fail_index = registry_failing.alloc_index;
    registry_failing.resize_fail_index = registry_failing.resize_index;
    try testing.expectError(error.OutOfMemory, registry.insert(&candidate));
    try testing.expectEqualStrings("atomic insert", candidate.name());
    try testing.expect(!insert_audit.context_destroyed);
    try testing.expectEqual(@as(usize, 0), registry.count());
    try testing.expect(registry.activeKey() == null);

    registry_failing.fail_index = std.math.maxInt(usize);
    registry_failing.resize_fail_index = std.math.maxInt(usize);
    const inserted = try registry.insert(&candidate);
    candidate_owned = false;
    try testing.expectEqual(WorkspaceKey.first, inserted);
    try testing.expectEqual(inserted, registry.activeKey().?);

    var name_failing = testing.FailingAllocator.init(testing.allocator, .{});
    var rename_audit: FakeAudit = .{};
    const rename_context = try FakeContext.create(name_failing.allocator(), &rename_audit, .local);
    var rename_candidate = try Workspace.init(
        testing.io,
        name_failing.allocator(),
        "before",
        "/rename",
        rename_context,
        size,
    );
    const rename_key = registry.insert(&rename_candidate) catch |err| {
        rename_candidate.deinit() catch |cleanup_err| std.debug.panic(
            "rename candidate cleanup failed: {s}",
            .{@errorName(cleanup_err)},
        );
        return err;
    };

    name_failing.fail_index = name_failing.alloc_index;
    name_failing.resize_fail_index = name_failing.resize_index;
    try testing.expectError(error.OutOfMemory, registry.rename(rename_key, "after"));
    try testing.expectEqualStrings("before", registry.byKey(rename_key).?.name());
    try testing.expectEqual(rename_key, registry.keyForName("before").?);
    try testing.expect(registry.keyForName("after") == null);

    name_failing.fail_index = std.math.maxInt(usize);
    name_failing.resize_fail_index = std.math.maxInt(usize);
    try registry.rename(rename_key, " after ");
    try testing.expectEqualStrings("after", registry.byKey(rename_key).?.name());
}

test "workspace registry removal and aggregate teardown release every child and context" {
    const testing = std.testing;
    const size = try term.GridSize.init(24, 6);
    var remove_audit: FakeAudit = .{};
    remove_audit.fail_hangup[0] = true;
    var registry = WorkspaceRegistry.init(testing.allocator);
    defer registry.deinit() catch |err| std.debug.panic(
        "workspace registry cleanup failed: {s}",
        .{@errorName(err)},
    );

    const removed_key = try insertFakeWorkspace(
        &registry,
        testing.io,
        testing.allocator,
        &remove_audit,
        "remove",
        "/remove",
        size,
    );
    const removed_workspace = registry.byKey(removed_key).?;
    try spawnAndAttach(removed_workspace, session.SessionId.first);
    const extra_session = try removed_workspace.createSession(.human_terminal, size);
    try spawnAndAttach(removed_workspace, extra_session);
    const removed = try registry.remove(removed_key);
    try testing.expect(removed.teardown_error.? == error.SystemError);
    try testing.expect(removed.active_key == null);
    try testing.expectEqual(@as(usize, 0), registry.count());
    try testing.expectEqual(@as(usize, 2), remove_audit.kill_count);
    try testing.expectEqual(@as(usize, 2), remove_audit.destroy_count);
    try testing.expect(remove_audit.context_destroyed);
    try testing.expect(!remove_audit.context_destroyed_with_live_children);

    var first_audit: FakeAudit = .{};
    var second_audit: FakeAudit = .{};
    first_audit.fail_hangup[0] = true;
    second_audit.fail_hangup[0] = true;
    var aggregate = WorkspaceRegistry.init(testing.allocator);
    var aggregate_owned = true;
    defer if (aggregate_owned) aggregate.deinit() catch |err| std.debug.panic(
        "aggregate workspace registry cleanup failed: {s}",
        .{@errorName(err)},
    );
    const first = try insertFakeWorkspace(
        &aggregate,
        testing.io,
        testing.allocator,
        &first_audit,
        "first failing",
        "/first",
        size,
    );
    const second = try insertFakeWorkspace(
        &aggregate,
        testing.io,
        testing.allocator,
        &second_audit,
        "second failing",
        "/second",
        size,
    );
    try spawnAndAttach(aggregate.byKey(first).?, session.SessionId.first);
    try spawnAndAttach(aggregate.byKey(second).?, session.SessionId.first);
    const aggregate_result = aggregate.deinit();
    aggregate_owned = false;
    try testing.expectError(error.SystemError, aggregate_result);
    try testing.expectEqual(@as(usize, 1), first_audit.kill_count);
    try testing.expectEqual(@as(usize, 1), first_audit.destroy_count);
    try testing.expect(first_audit.context_destroyed);
    try testing.expect(!first_audit.context_destroyed_with_live_children);
    try testing.expectEqual(@as(usize, 1), second_audit.kill_count);
    try testing.expectEqual(@as(usize, 1), second_audit.destroy_count);
    try testing.expect(second_audit.context_destroyed);
    try testing.expect(!second_audit.context_destroyed_with_live_children);
}

test "a workspace name is trimmed and never empty" {
    const testing = std.testing;

    try testing.expectEqualStrings("conduit", (try WorkspaceId.init("conduit")).name);
    try testing.expectEqualStrings("conduit", (try WorkspaceId.init("  conduit\t\n")).name);
    try testing.expectEqualStrings("my project", (try WorkspaceId.init(" my project ")).name);

    for ([_][]const u8{ "", " ", "\t", "\n", " \t\r\n " }) |nameless| {
        try testing.expectError(error.EmptyName, WorkspaceId.init(nameless));
    }
}

test "an execution context is local, ssh or wsl, spelled exactly" {
    const testing = std.testing;

    try testing.expectEqual(ExecutionContextKind.local, try ExecutionContextKind.parse("local"));
    try testing.expectEqual(ExecutionContextKind.ssh, try ExecutionContextKind.parse("ssh"));
    try testing.expectEqual(ExecutionContextKind.wsl, try ExecutionContextKind.parse("wsl"));

    for ([_][]const u8{ "", "Local", "SSH", "wsl ", " wsl", "ssh://host", "remote" }) |unknown| {
        try testing.expectError(error.UnknownContext, ExecutionContextKind.parse(unknown));
    }

    inline for (@typeInfo(ExecutionContextKind).@"enum".fields) |field| {
        const kind: ExecutionContextKind = @enumFromInt(field.value);
        try testing.expectEqual(kind, try ExecutionContextKind.parse(kind.label()));
        try testing.expect(kind.isRemote() == (kind != .local));
    }
}

test "a borrowed execution context can spawn but cannot own teardown" {
    const testing = std.testing;
    var audit: FakeAudit = .{};
    var owner = try FakeContext.create(testing.allocator, &audit, .wsl);
    const borrowed = owner.borrow();

    try testing.expect(!@hasDecl(ExecutionContext.Ref, "deinit"));
    try testing.expectEqual(ExecutionContextKind.wsl, borrowed.kind());
    const child = try borrowed.spawn(.{
        .argv = &.{"fake-shell"},
        .env = &.{"PATH=/test"},
        .cwd = "/borrowed",
        .size = pty.WindowSize.init(2, 10),
    });
    try child.kill(.hangup);
    child.destroy();
    try testing.expect(!audit.context_destroyed);

    owner.deinit();
    try testing.expect(audit.context_destroyed);
    try testing.expect(!audit.context_destroyed_with_live_children);
}

test "workspace init consumes and destroys its context on validation failure" {
    const testing = std.testing;
    const size = try term.GridSize.init(10, 2);
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(testing.allocator, &audit, .local);

    try testing.expectError(
        error.EmptyName,
        Workspace.init(testing.io, testing.allocator, " \t ", "/tmp", context, size),
    );
    try testing.expect(audit.context_destroyed);
    try testing.expect(!audit.context_destroyed_with_live_children);
}

test "workspace copies identity and routes every spawn with its cwd through the context" {
    const testing = std.testing;
    const size = try term.GridSize.init(20, 4);
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(testing.allocator, &audit, .ssh);
    var name = [_]u8{ ' ', 'd', 'e', 'm', 'o', ' ' };
    var cwd = [_]u8{ '/', 'w', 'o', 'r', 'k' };
    var workspace = try Workspace.init(testing.io, testing.allocator, &name, &cwd, context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});

    try testing.expectEqualStrings("demo", workspace.name());
    try testing.expectEqualStrings("/work", workspace.workingDirectory());
    try testing.expectEqual(ExecutionContextKind.ssh, workspace.contextKind());
    try testing.expectEqual(@as(usize, 0), audit.spawn_count);

    name[1] = 'X';
    cwd[1] = 'X';
    const human = try workspace.createSession(.human_terminal, size);
    const request = try workspace.spawnRequest(human, testProcess());
    const child = try workspace.contextRef().spawn(request);
    try workspace.attachChild(human, child);
    try testing.expectEqualStrings("demo", workspace.name());
    try testing.expectEqualStrings("/work", workspace.workingDirectory());
    try testing.expectEqualStrings("/work", audit.last_cwd[0..audit.last_cwd_len]);
    try testing.expectEqual(@as(usize, 1), audit.spawn_count);
}

test "session kinds have stable non-reused ids and exactly one scratchpad" {
    const testing = std.testing;
    const size = try term.GridSize.init(24, 6);
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "kinds", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});

    const scratchpad = workspace.scratchpadId();
    try testing.expectEqual(session.SessionId.first, scratchpad);
    try testing.expectEqual(session.Session.Kind.scratchpad, workspace.sessionKind(scratchpad).?);
    try testing.expectEqual(session.Lifecycle.starting, workspace.sessionLifecycle(scratchpad).?);
    try testing.expect(workspace.sessionById(scratchpad).?.child() == null);
    try testing.expectError(error.ScratchpadAlreadyExists, workspace.createSession(.scratchpad, size));
    try testing.expectError(error.ScratchpadCannotClose, workspace.closeSession(scratchpad));

    const human = try workspace.createSession(.human_terminal, size);
    const stable_human = workspace.sessionById(human).?;
    const agent = try workspace.createSession(.agent_terminal, size);
    try testing.expect(stable_human == workspace.sessionById(human).?);
    try testing.expectEqual(session.Session.Kind.human_terminal, workspace.sessionKind(human).?);
    try testing.expectEqual(session.Session.Kind.agent_terminal, workspace.sessionKind(agent).?);
    try testing.expectEqual(session.Lifecycle.starting, workspace.sessionLifecycle(human).?);
    try testing.expectEqual(session.Lifecycle.starting, workspace.sessionLifecycle(agent).?);

    try spawnAndAttach(&workspace, human);
    try spawnAndAttach(&workspace, agent);
    try spawnAndAttach(&workspace, scratchpad);
    try testing.expectEqual(session.Lifecycle.running, workspace.sessionLifecycle(scratchpad).?);
    try testing.expectError(error.SessionAlreadyStarted, workspace.spawnRequest(scratchpad, testProcess()));
    try testing.expectEqual(@as(usize, 3), audit.spawn_count);

    try workspace.closeSession(human);
    try testing.expect(workspace.sessionById(human) == null);
    try testing.expectEqual(session.Lifecycle.exited, workspace.sessionLifecycle(human).?);
    const replacement = try workspace.createSession(.human_terminal, size);
    try testing.expect(replacement != human);
    try testing.expectEqual(@as(u32, 3), replacement.ordinal());
    try testing.expectEqual(@as(usize, 3), workspace.sessionCount());
    try testing.expectEqual(@as(usize, 4), workspace.registeredSessionCount());
}

test "scratchpad starts through its context and pumps output without a view" {
    const testing = std.testing;
    const size = try term.GridSize.init(24, 6);
    var audit: FakeAudit = .{};
    audit.outputs[0] = "HIDDEN-SCRATCHPAD";

    {
        const context = try FakeContext.create(testing.allocator, &audit, .local);
        var workspace = try Workspace.init(
            testing.io,
            testing.allocator,
            "scratchpad-hidden",
            "/tmp",
            context,
            size,
        );
        defer workspace.deinit() catch |err| std.debug.panic(
            "workspace cleanup failed: {s}",
            .{@errorName(err)},
        );

        const scratchpad_id = workspace.scratchpadId();
        try testing.expectError(
            error.ScratchpadNotRunning,
            workspace.scratchpadRestartRequest(testProcess()),
        );
        try spawnAndAttach(&workspace, scratchpad_id);
        try testing.expectEqual(session.Lifecycle.running, workspace.sessionLifecycle(scratchpad_id).?);
        try testing.expectEqual(@as(usize, 0), workspace.tabCount());

        var ignored: IgnoredEvents = .{};
        var io_buffer: [64]u8 = undefined;
        var response_buffer: [64]u8 = undefined;
        const pumped = workspace.pump(&io_buffer, &response_buffer, ignored.sink());
        try testing.expectEqual(@as(usize, 1), pumped.sessions_visited);
        try testing.expectEqual(@as(usize, "HIDDEN-SCRATCHPAD".len), pumped.bytes_drained);

        const scratchpad = workspace.sessionById(scratchpad_id).?;
        try scratchpad.terminal().refresh(testing.allocator);
        try testing.expect(scratchpad.terminalConst().visibleTextContains("HIDDEN-SCRATCHPAD"));
    }

    try testing.expectEqual(@as(usize, 1), audit.spawn_count);
    try testing.expectEqual(@as(usize, 1), audit.kill_count);
    try testing.expectEqual(@as(usize, 1), audit.destroy_count);
    try testing.expect(audit.context_destroyed);
    try testing.expect(!audit.context_destroyed_with_live_children);
}

test "scratchpad restart preserves identity and installs a fresh terminal at current size" {
    const testing = std.testing;
    const initial_size = try term.GridSize.init(24, 6);
    const current_size = try term.GridSize.init(31, 9);
    var audit: FakeAudit = .{};
    audit.outputs[0] = "OLD-SCRATCHPAD";
    audit.outputs[1] = "FRESH-SCRATCHPAD";
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(
        testing.io,
        testing.allocator,
        "scratchpad-restart",
        "/workspace",
        context,
        initial_size,
    );
    defer workspace.deinit() catch |err| std.debug.panic(
        "workspace cleanup failed: {s}",
        .{@errorName(err)},
    );

    const scratchpad_id = workspace.scratchpadId();
    try spawnAndAttach(&workspace, scratchpad_id);
    var ignored: IgnoredEvents = .{};
    var io_buffer: [64]u8 = undefined;
    var response_buffer: [64]u8 = undefined;
    _ = workspace.pump(&io_buffer, &response_buffer, ignored.sink());

    const old_terminal = workspace.sessionById(scratchpad_id).?.terminal();
    try old_terminal.refresh(testing.allocator);
    try testing.expect(old_terminal.visibleTextContains("OLD-SCRATCHPAD"));
    try workspace.sessionById(scratchpad_id).?.resize(current_size);

    const request = try workspace.scratchpadRestartRequest(testProcess());
    try testing.expectEqualStrings("/workspace", request.cwd);
    try testing.expectEqual(current_size.rows, request.size.rows);
    try testing.expectEqual(current_size.cols, request.size.cols);
    const fresh_child = try workspace.contextRef().spawn(request);
    var caller_owns_fresh_child = true;
    defer if (caller_owns_fresh_child) destroyCallerOwnedTestChild(fresh_child);
    const replaced = try workspace.replaceScratchpad(fresh_child);
    caller_owns_fresh_child = false;

    try testing.expect(replaced.old_child_deinit_error == null);
    try testing.expectEqual(session.SessionId.first, workspace.scratchpadId());
    try testing.expectEqual(@as(usize, 1), workspace.registeredSessionCount());
    try testing.expectEqual(session.Lifecycle.running, workspace.sessionLifecycle(scratchpad_id).?);
    try testing.expectEqual(session.Session.Kind.scratchpad, workspace.sessionKind(scratchpad_id).?);
    try testing.expect(workspace.sessionById(scratchpad_id).?.terminal() != old_terminal);
    try testing.expectEqual(current_size, workspace.sessionById(scratchpad_id).?.terminalConst().gridSize());
    try testing.expectEqual(@as(usize, 2), audit.resize_count);
    try testing.expectEqual(current_size.rows, audit.resize_rows[1]);
    try testing.expectEqual(current_size.cols, audit.resize_cols[1]);
    try testing.expectEqual(@as(usize, 1), audit.kill_count);
    try testing.expectEqual(@as(usize, 1), audit.destroy_count);

    const fresh = workspace.sessionById(scratchpad_id).?;
    try fresh.terminal().refresh(testing.allocator);
    try testing.expect(!fresh.terminalConst().visibleTextContains("OLD-SCRATCHPAD"));
    const pumped = workspace.pump(&io_buffer, &response_buffer, ignored.sink());
    try testing.expectEqual(@as(usize, "FRESH-SCRATCHPAD".len), pumped.bytes_drained);
    try fresh.terminal().refresh(testing.allocator);
    try testing.expect(fresh.terminalConst().visibleTextContains("FRESH-SCRATCHPAD"));
    try testing.expect(!fresh.terminalConst().visibleTextContains("OLD-SCRATCHPAD"));
}

test "scratchpad replacement allocation failure keeps old state and caller ownership" {
    const testing = std.testing;
    const size = try term.GridSize.init(24, 6);
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(failing.allocator(), &audit, .local);
    var workspace = try Workspace.init(
        testing.io,
        failing.allocator(),
        "scratchpad-allocation",
        "/tmp",
        context,
        size,
    );
    defer workspace.deinit() catch |err| std.debug.panic(
        "workspace cleanup failed: {s}",
        .{@errorName(err)},
    );

    const scratchpad_id = workspace.scratchpadId();
    try spawnAndAttach(&workspace, scratchpad_id);
    const old_session = workspace.sessionById(scratchpad_id).?;
    const old_terminal = old_session.terminal();
    const old_child = old_session.child().?;
    const request = try workspace.scratchpadRestartRequest(testProcess());
    const caller_child = try workspace.contextRef().spawn(request);
    var caller_owns_child = true;
    defer if (caller_owns_child) destroyCallerOwnedTestChild(caller_child);

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try testing.expectError(error.OutOfMemory, workspace.replaceScratchpad(caller_child));
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);

    try testing.expect(workspace.sessionById(scratchpad_id).? == old_session);
    try testing.expect(workspace.sessionById(scratchpad_id).?.terminal() == old_terminal);
    try testing.expect(workspace.sessionById(scratchpad_id).?.child().?.ptr == old_child.ptr);
    try testing.expectEqual(session.Lifecycle.running, workspace.sessionLifecycle(scratchpad_id).?);
    try testing.expectEqual(@as(usize, 0), audit.resize_count);
    try testing.expectEqual(@as(usize, 0), audit.destroy_count);

    destroyCallerOwnedTestChild(caller_child);
    caller_owns_child = false;
    try testing.expectEqual(@as(usize, 1), audit.destroy_count);
}

test "scratchpad replacement resize failure leaves the child with its caller" {
    const testing = std.testing;
    const size = try term.GridSize.init(24, 6);
    var audit: FakeAudit = .{};
    audit.fail_resize[1] = true;
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(
        testing.io,
        testing.allocator,
        "scratchpad-resize",
        "/tmp",
        context,
        size,
    );
    defer workspace.deinit() catch |err| std.debug.panic(
        "workspace cleanup failed: {s}",
        .{@errorName(err)},
    );

    const scratchpad_id = workspace.scratchpadId();
    try spawnAndAttach(&workspace, scratchpad_id);
    const old_session = workspace.sessionById(scratchpad_id).?;
    const old_child = old_session.child().?;
    const request = try workspace.scratchpadRestartRequest(testProcess());
    const caller_child = try workspace.contextRef().spawn(request);
    var caller_owns_child = true;
    defer if (caller_owns_child) destroyCallerOwnedTestChild(caller_child);

    try testing.expectError(error.SystemError, workspace.replaceScratchpad(caller_child));
    try testing.expect(workspace.sessionById(scratchpad_id).? == old_session);
    try testing.expect(workspace.sessionById(scratchpad_id).?.child().?.ptr == old_child.ptr);
    try testing.expectEqual(session.Lifecycle.running, workspace.sessionLifecycle(scratchpad_id).?);
    try testing.expectEqual(@as(usize, 1), audit.resize_count);
    try testing.expectEqual(@as(usize, 0), audit.destroy_count);

    destroyCallerOwnedTestChild(caller_child);
    caller_owns_child = false;
    try testing.expectEqual(@as(usize, 1), audit.destroy_count);
}

test "scratchpad replacement reports old hangup failure after committing new ownership" {
    const testing = std.testing;
    const size = try term.GridSize.init(24, 6);
    var audit: FakeAudit = .{};
    audit.fail_hangup[0] = true;
    audit.outputs[1] = "REPLACEMENT-RUNNING";

    {
        const context = try FakeContext.create(testing.allocator, &audit, .local);
        var workspace = try Workspace.init(
            testing.io,
            testing.allocator,
            "scratchpad-cleanup-error",
            "/tmp",
            context,
            size,
        );
        defer workspace.deinit() catch |err| std.debug.panic(
            "workspace cleanup failed: {s}",
            .{@errorName(err)},
        );

        const scratchpad_id = workspace.scratchpadId();
        try spawnAndAttach(&workspace, scratchpad_id);
        const request = try workspace.scratchpadRestartRequest(testProcess());
        const fresh_child = try workspace.contextRef().spawn(request);
        var caller_owns_fresh_child = true;
        defer if (caller_owns_fresh_child) destroyCallerOwnedTestChild(fresh_child);
        const fresh_child_ptr = fresh_child.ptr;
        const replaced = try workspace.replaceScratchpad(fresh_child);
        caller_owns_fresh_child = false;

        try testing.expect(replaced.old_child_deinit_error.? == error.SystemError);
        try testing.expectEqual(session.Lifecycle.running, workspace.sessionLifecycle(scratchpad_id).?);
        try testing.expect(workspace.sessionById(scratchpad_id).?.child().?.ptr == fresh_child_ptr);
        try testing.expectEqual(@as(usize, 1), audit.kill_count);
        try testing.expectEqual(@as(usize, 1), audit.destroy_count);

        var ignored: IgnoredEvents = .{};
        var io_buffer: [64]u8 = undefined;
        var response_buffer: [64]u8 = undefined;
        const pumped = workspace.pump(&io_buffer, &response_buffer, ignored.sink());
        try testing.expectEqual(@as(usize, "REPLACEMENT-RUNNING".len), pumped.bytes_drained);
        const fresh = workspace.sessionById(scratchpad_id).?;
        try fresh.terminal().refresh(testing.allocator);
        try testing.expect(fresh.terminalConst().visibleTextContains("REPLACEMENT-RUNNING"));
    }

    try testing.expectEqual(@as(usize, 2), audit.kill_count);
    try testing.expectEqual(@as(usize, 2), audit.destroy_count);
    try testing.expect(audit.context_destroyed);
    try testing.expect(!audit.context_destroyed_with_live_children);
}

test "tabs copy labels retain stable ids and order and select an active session" {
    const testing = std.testing;
    const size = try term.GridSize.init(24, 6);
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "tabs", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});
    try testing.expectEqual(@as(usize, 0), workspace.tabCount());
    try testing.expect(workspace.activeTabId() == null);
    try testing.expect(workspace.activeSessionId() == null);

    const first_session = try workspace.createSession(.human_terminal, size);
    const second_session = try workspace.createSession(.agent_terminal, size);
    var first_label = [_]u8{ 's', 'h', 'e', 'l', 'l' };
    const first_id = try workspace.registerTab(&first_label, first_session);
    const stable_first = workspace.tab(first_id).?;
    const stable_semantic_ptr = stable_first.semanticId().ptr;
    first_label[0] = 'X';
    const second_id = try workspace.registerTab("agent", second_session);

    try testing.expectEqual(TabId.first, first_id);
    try testing.expectEqual(@as(u32, 0), first_id.ordinal());
    try testing.expectEqual(@as(u32, 1), second_id.ordinal());
    try testing.expectEqual(@as(usize, 2), workspace.tabCount());
    try testing.expect(stable_first == workspace.tab(first_id).?);
    try testing.expect(stable_semantic_ptr == workspace.tab(first_id).?.semanticId().ptr);
    try testing.expectEqualStrings("shell", workspace.tabAt(0).?.name());
    try testing.expectEqualStrings("agent", workspace.tabAt(1).?.name());
    try testing.expectEqualStrings("  shell", workspace.tabAt(0).?.displayLabel());
    try testing.expectEqual(TabAttention.none, workspace.tabAt(0).?.attention());
    try testing.expectEqualStrings("tab.1", workspace.tabAt(0).?.semanticId());
    try testing.expectEqualStrings("tab.2", workspace.tabAt(1).?.semanticId());
    try testing.expectEqual(first_id, workspace.tabAt(0).?.id());
    try testing.expectEqual(second_session, workspace.tabAt(1).?.sessionId());
    try testing.expect(workspace.tabAt(2) == null);
    try testing.expectEqual(first_id, workspace.activeTabId().?);
    try testing.expectEqual(first_session, workspace.activeSessionId().?);

    try workspace.activateTab(second_id);
    try testing.expectEqual(second_id, workspace.activeTabId().?);
    try testing.expectEqual(second_session, workspace.activeSessionId().?);
    try testing.expectError(error.UnknownTab, workspace.activateTab(TabId.fromOrdinal(20)));
    try testing.expectEqual(second_id, workspace.activeTabId().?);
}

test "tab registration rejects unknown exited scratchpad and duplicate sessions" {
    const testing = std.testing;
    const size = try term.GridSize.init(16, 4);
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "tab-errors", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});

    try testing.expectError(
        error.UnknownSession,
        workspace.registerTab("unknown", session.SessionId.fromOrdinal(100)),
    );
    try testing.expectError(
        error.ScratchpadSession,
        workspace.registerTab("scratchpad", workspace.scratchpadId()),
    );

    const live = try workspace.createSession(.human_terminal, size);
    _ = try workspace.registerTab("live", live);
    try testing.expectError(error.SessionAlreadyRegistered, workspace.registerTab("again", live));

    const exited = try workspace.createSession(.agent_terminal, size);
    try workspace.closeSession(exited);
    try testing.expectError(error.SessionExited, workspace.registerTab("exited", exited));
    try testing.expectEqual(@as(usize, 1), workspace.tabCount());
}

test "tab lifecycle preserves retained records and repairs active selection" {
    const testing = std.testing;
    const size = try term.GridSize.init(24, 6);
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "lifecycle", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});

    const first = try workspace.createTab("one", size);
    const stable_first = workspace.tab(first.tab_id).?;
    const stable_semantic = stable_first.semanticId().ptr;
    var replacement_name = [_]u8{ 'r', 'e', 'n', 'a', 'm', 'e', 'd' };
    try workspace.renameTab(first.tab_id, &replacement_name);
    replacement_name[0] = 'X';
    try testing.expect(stable_first == workspace.tab(first.tab_id).?);
    try testing.expect(stable_semantic == stable_first.semanticId().ptr);
    try testing.expectEqualStrings("renamed", stable_first.name());
    try testing.expectEqualStrings("  renamed", stable_first.displayLabel());

    const second = try workspace.createTab("two", size);
    const third = try workspace.createTab("three", size);
    try testing.expectEqual(third.tab_id, workspace.activeTabId().?);
    try testing.expectEqual(@as(?usize, 0), workspace.tabIndex(first.tab_id));
    try testing.expectEqual(@as(?usize, 1), workspace.tabIndex(second.tab_id));
    try testing.expectEqual(@as(?usize, 2), workspace.tabIndex(third.tab_id));

    try workspace.moveTab(third.tab_id, 0);
    try testing.expectEqual(third.tab_id, workspace.tabAt(0).?.id());
    try testing.expectEqual(first.tab_id, workspace.tabAt(1).?.id());
    try testing.expectEqual(second.tab_id, workspace.tabAt(2).?.id());
    try testing.expect(stable_first == workspace.tabAt(1).?);
    try testing.expectEqual(third.tab_id, workspace.activeTabId().?);
    try workspace.moveTab(first.tab_id, 1);
    try testing.expectError(error.InvalidIndex, workspace.moveTab(first.tab_id, 3));
    try testing.expectError(error.UnknownTab, workspace.moveTab(TabId.fromOrdinal(99), 0));
    try testing.expectError(error.UnknownTab, workspace.renameTab(TabId.fromOrdinal(99), "missing"));

    try workspace.activateTab(first.tab_id);
    try workspace.closeTab(first.tab_id);
    try testing.expectEqual(second.tab_id, workspace.activeTabId().?);
    try testing.expect(workspace.tab(first.tab_id) == null);
    try testing.expect(workspace.sessionById(first.session_id) == null);
    try testing.expectEqual(session.Lifecycle.exited, workspace.sessionLifecycle(first.session_id).?);

    try workspace.closeTab(second.tab_id);
    try testing.expectEqual(third.tab_id, workspace.activeTabId().?);
    try workspace.closeTab(third.tab_id);
    try testing.expect(workspace.activeTabId() == null);
    try testing.expect(workspace.activeSessionId() == null);
    try testing.expectEqual(@as(usize, 0), workspace.tabCount());

    const replacement = try workspace.createTab("replacement", size);
    try testing.expect(replacement.tab_id != first.tab_id);
    try testing.expect(replacement.tab_id != second.tab_id);
    try testing.expect(replacement.tab_id != third.tab_id);
    try testing.expect(replacement.session_id != first.session_id);
    try testing.expectEqual(@as(u32, 3), replacement.tab_id.ordinal());
    try testing.expectEqual(@as(u32, 4), replacement.session_id.ordinal());
}

test "failed tab creation leaves registries ids and selection untouched" {
    const testing = std.testing;
    const size = try term.GridSize.init(24, 6);
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(failing.allocator(), &audit, .local);
    var workspace = try Workspace.init(testing.io, failing.allocator(), "atomic", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try testing.expectError(error.OutOfMemory, workspace.createTab("not-created", size));
    try testing.expectEqual(@as(usize, 0), workspace.tabCount());
    try testing.expectEqual(@as(usize, 1), workspace.registeredSessionCount());
    try testing.expect(workspace.activeTabId() == null);

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    const created = try workspace.createTab("first", size);
    try testing.expectEqual(TabId.first, created.tab_id);
    try testing.expectEqual(@as(u32, 1), created.session_id.ordinal());
}

test "background tab attention has bell precedence and clears on activation" {
    const testing = std.testing;
    const size = try term.GridSize.init(24, 6);
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "attention", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});

    const first = try workspace.createTab("one", size);
    const second = try workspace.createTab("two", size);
    try workspace.activateTab(first.tab_id);
    const hidden = workspace.tab(second.tab_id).?;

    try testing.expect(!workspace.noteBackgroundActivity(first.session_id, false));
    try testing.expect(!workspace.noteBackgroundActivity(session.SessionId.fromOrdinal(99), true));
    try testing.expect(workspace.noteBackgroundActivity(second.session_id, false));
    try testing.expectEqual(TabAttention.activity, hidden.attention());
    try testing.expectEqualStrings("* two", hidden.displayLabel());
    try testing.expect(!workspace.noteBackgroundActivity(second.session_id, false));
    try testing.expect(workspace.noteBackgroundActivity(second.session_id, true));
    try testing.expectEqual(TabAttention.bell, hidden.attention());
    try testing.expectEqualStrings("! two", hidden.displayLabel());
    try testing.expect(!workspace.noteBackgroundActivity(second.session_id, false));

    try workspace.renameTab(second.tab_id, "renamed");
    try testing.expectEqualStrings("! renamed", hidden.displayLabel());
    try workspace.activateTab(second.tab_id);
    try testing.expectEqual(TabAttention.none, hidden.attention());
    try testing.expectEqualStrings("  renamed", hidden.displayLabel());
}

test "closing a tab remains consistent when signalling its child fails" {
    const testing = std.testing;
    const size = try term.GridSize.init(24, 6);
    var audit: FakeAudit = .{};
    audit.fail_hangup[0] = true;
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "close-failure", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});

    const created = try workspace.createTab("running", size);
    try spawnAndAttach(&workspace, created.session_id);
    try testing.expectError(error.SystemError, workspace.closeTab(created.tab_id));
    try testing.expectEqual(@as(usize, 0), workspace.tabCount());
    try testing.expect(workspace.activeTabId() == null);
    try testing.expect(workspace.sessionById(created.session_id) == null);
    try testing.expectEqual(session.Lifecycle.exited, workspace.sessionLifecycle(created.session_id).?);
    try testing.expectEqual(@as(usize, 1), audit.kill_count);
    try testing.expectEqual(@as(usize, 1), audit.destroy_count);
}

test "a bounded pump updates a hidden session and delivers borrowed events immediately" {
    const testing = std.testing;
    const size = try term.GridSize.init(20, 4);
    var audit: FakeAudit = .{};
    audit.outputs[0] = "\x1b]2;hidden-title\x07HIDDEN";
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "pump", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});
    const hidden = try workspace.createSession(.human_terminal, size);
    try spawnAndAttach(&workspace, hidden);

    var events: CapturedEvents = .{};
    var io_buffer: [64]u8 = undefined;
    var response_buffer: [64]u8 = undefined;
    try testing.expect(workspace.hasAttachedChild());
    try testing.expect(workspace.needsPump());
    const result = workspace.pump(&io_buffer, &response_buffer, events.sink());
    try testing.expectEqual(@as(usize, 2), result.sessions_visited);
    try testing.expectEqual(audit.outputs[0].len, result.bytes_drained);
    try testing.expectEqual(@as(usize, 0), result.response_bytes_written);
    try testing.expectEqual(@as(usize, 0), result.response_bytes_pending);
    try testing.expect(result.first_error == null);
    try testing.expectEqual(@as(usize, 1), events.calls);
    try testing.expectEqual(hidden, events.session_id.?);
    try testing.expectEqualStrings("hidden-title", events.title[0..events.title_len]);

    const live = workspace.sessionById(hidden).?;
    try live.terminal().refresh(testing.allocator);
    for ("HIDDEN", 0..) |expected, col| {
        try testing.expectEqual(@as(u21, expected), live.terminalConst().cell(.{
            .col = @intCast(col),
            .row = 0,
        }).?.codepoint);
    }
    try testing.expect(!workspace.needsPump());
    try testing.expectEqual(
        @as(usize, 0),
        workspace.pump(&io_buffer, &response_buffer, events.sink()).bytes_drained,
    );
}

test "pump flushes responses before events and retries a retained short write" {
    const testing = std.testing;
    const size = try term.GridSize.init(20, 4);
    const limits = [_]usize{ 3, primary_device_attributes.len };
    var audit: FakeAudit = .{};
    audit.outputs[0] = "\x1b[c\x1b]2;response-event\x07";
    audit.write_limits[0] = &limits;
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "responses", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});
    const hidden = try workspace.createSession(.human_terminal, size);
    try spawnAndAttach(&workspace, hidden);

    var events: CapturedEvents = .{ .audit = &audit };
    var io_buffer: [64]u8 = undefined;
    var response_buffer: [64]u8 = undefined;
    const first = workspace.pump(&io_buffer, &response_buffer, events.sink());
    try testing.expectEqual(@as(usize, 3), first.response_bytes_written);
    try testing.expectEqual(primary_device_attributes.len - 3, first.response_bytes_pending);
    try testing.expect(first.hasPendingResponses());
    try testing.expect(first.first_error == null);
    try testing.expectEqual(@as(usize, 1), events.write_count_during_callback);
    try testing.expectEqualStrings("response-event", events.title[0..events.title_len]);
    try testing.expect(workspace.needsPump());

    const second = workspace.pump(&io_buffer, &response_buffer, events.sink());
    try testing.expectEqual(primary_device_attributes.len - 3, second.response_bytes_written);
    try testing.expectEqual(@as(usize, 0), second.response_bytes_pending);
    try testing.expect(!second.hasPendingResponses());
    try testing.expectEqualStrings(primary_device_attributes, audit.accepted());
    try testing.expect(!workspace.needsPump());
}

test "pump retains the first response error and services later sessions" {
    const testing = std.testing;
    const size = try term.GridSize.init(20, 4);
    var audit: FakeAudit = .{};
    audit.outputs[0] = "\x1b[c";
    audit.outputs[1] = "\x1b[c";
    audit.fail_write[0] = true;
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "response-error", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});
    const first_id = try workspace.createSession(.human_terminal, size);
    const second_id = try workspace.createSession(.agent_terminal, size);
    try spawnAndAttach(&workspace, first_id);
    try spawnAndAttach(&workspace, second_id);

    var ignored: IgnoredEvents = .{};
    var io_buffer: [64]u8 = undefined;
    var response_buffer: [64]u8 = undefined;
    const result = workspace.pump(&io_buffer, &response_buffer, ignored.sink());
    try testing.expectEqual(@as(usize, 3), result.sessions_visited);
    try testing.expect(result.first_error.? == error.SystemError);
    try testing.expectEqual(primary_device_attributes.len, result.response_bytes_written);
    try testing.expectEqual(primary_device_attributes.len, result.response_bytes_pending);
    try testing.expectEqualStrings(primary_device_attributes, audit.accepted());
}

test "pump is safe when an event callback creates and closes its current session" {
    const testing = std.testing;
    const size = try term.GridSize.init(20, 4);
    var audit: FakeAudit = .{};
    audit.outputs[0] = "\x1b]2;first\x07A";
    audit.outputs[1] = "\x1b]2;second\x07B";
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "mutation", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});
    const first_id = try workspace.createSession(.human_terminal, size);
    const second_id = try workspace.createSession(.agent_terminal, size);
    try spawnAndAttach(&workspace, first_id);
    try spawnAndAttach(&workspace, second_id);

    var mutations: MutatingEvents = .{
        .workspace = &workspace,
        .size = size,
        .mutate_id = first_id,
    };
    var io_buffer: [64]u8 = undefined;
    var response_buffer: [64]u8 = undefined;
    const result = workspace.pump(&io_buffer, &response_buffer, mutations.sink());
    try testing.expectEqual(@as(usize, 3), result.sessions_visited);
    try testing.expectEqual(@as(usize, 2), mutations.calls);
    try testing.expect(!mutations.failed);
    try testing.expect(mutations.closed_current);
    try testing.expect(mutations.created != null);
    try testing.expectEqual(session.Lifecycle.exited, workspace.sessionLifecycle(first_id).?);
    try testing.expectEqual(session.Lifecycle.running, workspace.sessionLifecycle(second_id).?);
    try testing.expectEqual(session.Lifecycle.starting, workspace.sessionLifecycle(mutations.created.?).?);
    try testing.expectEqual(@as(usize, 4), workspace.registeredSessionCount());
}

test "pumpExcept leaves the active session untouched while servicing hidden sessions" {
    const testing = std.testing;
    const size = try term.GridSize.init(20, 4);
    var audit: FakeAudit = .{};
    audit.outputs[0] = "ACTIVE";
    audit.outputs[1] = "HIDDEN";
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "skip", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});
    const active = try workspace.createSession(.human_terminal, size);
    const hidden = try workspace.createSession(.agent_terminal, size);
    try spawnAndAttach(&workspace, active);
    try spawnAndAttach(&workspace, hidden);

    var ignored: IgnoredEvents = .{};
    var io_buffer: [64]u8 = undefined;
    var response_buffer: [64]u8 = undefined;
    const hidden_result = workspace.pumpExcept(active, &io_buffer, &response_buffer, ignored.sink());
    try testing.expectEqual(@as(usize, 2), hidden_result.sessions_visited);
    try testing.expectEqual(@as(usize, "HIDDEN".len), hidden_result.bytes_drained);
    try testing.expect(workspace.needsPump());

    const active_result = workspace.pump(&io_buffer, &response_buffer, ignored.sink());
    try testing.expectEqual(@as(usize, "ACTIVE".len), active_result.bytes_drained);
    try testing.expect(!workspace.needsPump());
}

test "a local hidden session reaches terminal state through only the workspace pump" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const size = try term.GridSize.init(40, 4);
    var workspace = try Workspace.initLocal(testing.io, testing.allocator, "local-pump", "/tmp", size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});
    const hidden = try workspace.createSession(.human_terminal, size);
    const request = try workspace.spawnRequest(hidden, .{
        .argv = &.{ "/bin/sh", "-c", "printf WORKSPACE_HIDDEN" },
        .env = &.{ "PATH=/usr/bin:/bin", "TERM=xterm-256color" },
    });
    const child = try workspace.contextRef().spawn(request);
    try workspace.attachChild(hidden, child);

    var ignored: IgnoredEvents = .{};
    var io_buffer: [1024]u8 = undefined;
    var response_buffer: [term.response_capacity]u8 = undefined;
    const deadline = std.Io.Clock.real.now(testing.io).nanoseconds + 5 * std.time.ns_per_s;
    var found = false;
    while (std.Io.Clock.real.now(testing.io).nanoseconds < deadline) {
        if (workspace.needsPump()) {
            const result = workspace.pump(&io_buffer, &response_buffer, ignored.sink());
            if (result.first_error) |err| return err;
            const live = workspace.sessionById(hidden) orelse return error.SessionNotFound;
            try live.terminal().refresh(testing.allocator);
            if (live.terminalConst().visibleTextContains("WORKSPACE_HIDDEN")) {
                found = true;
                break;
            }
        } else {
            const live = workspace.sessionById(hidden) orelse return error.SessionNotFound;
            _ = live.child().?.waitReadable(25);
        }
    }
    try testing.expect(found);

    const quiescence_deadline = std.Io.Clock.real.now(testing.io).nanoseconds + 5 * std.time.ns_per_s;
    var exited = false;
    while (std.Io.Clock.real.now(testing.io).nanoseconds < quiescence_deadline) {
        const live = workspace.sessionById(hidden) orelse return error.SessionNotFound;
        const attached = live.child().?;
        exited = attached.state() == .exited;
        const needs_service = workspace.needsPump();
        if (exited and !needs_service) break;
        if (needs_service) {
            const result = workspace.pump(&io_buffer, &response_buffer, ignored.sink());
            if (result.first_error) |err| return err;
        } else {
            _ = attached.waitReadable(25);
        }
    }
    try testing.expect(exited);
    try testing.expect(!workspace.needsPump());
}

test "close and teardown release all ownership before returning the first hangup failure" {
    const testing = std.testing;
    const size = try term.GridSize.init(10, 2);
    var audit: FakeAudit = .{};
    audit.fail_hangup[0] = true;
    audit.fail_hangup[1] = true;
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "cleanup", "/tmp", context, size);

    const first = try workspace.createSession(.human_terminal, size);
    const second = try workspace.createSession(.agent_terminal, size);
    try spawnAndAttach(&workspace, first);
    try spawnAndAttach(&workspace, second);
    _ = try workspace.registerTab("owned through teardown", second);
    try testing.expectError(error.SystemError, workspace.closeSession(first));
    try testing.expectEqual(session.Lifecycle.exited, workspace.sessionLifecycle(first).?);
    try testing.expectEqual(@as(usize, 1), audit.destroy_count);

    try testing.expectError(error.SystemError, workspace.deinit());
    try testing.expectEqual(@as(usize, 2), audit.kill_count);
    try testing.expectEqual(@as(usize, 2), audit.destroy_count);
    try testing.expect(audit.context_destroyed);
    try testing.expect(!audit.context_destroyed_with_live_children);
}

test "pane trees split right and down to arbitrary depth without allocating during layout" {
    const testing = std.testing;
    const size = try term.GridSize.init(40, 16);
    const bounds = try CellRect.init(3, 2, 31, 17);
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "pane-tree", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});

    const root_session = try workspace.createSession(.human_terminal, size);
    const tab_id = try workspace.registerTab("tree", root_session);
    const root_pane = workspace.focusedPaneId(tab_id).?;
    const right_session = try workspace.createSession(.human_terminal, size);
    const right = try workspace.splitPane(tab_id, root_pane, right_session, .right, bounds);
    const lower_left_session = try workspace.createSession(.human_terminal, size);
    const lower_left = try workspace.splitPane(tab_id, root_pane, lower_left_session, .down, bounds);
    const lower_right_session = try workspace.createSession(.human_terminal, size);
    const lower_right = try workspace.splitPane(tab_id, right, lower_right_session, .down, bounds);

    try testing.expectEqual(@as(usize, 4), workspace.tab(tab_id).?.paneCount());
    var panes: [4]PaneLayout = undefined;
    try testing.expectEqual(@as(usize, 4), try workspace.layoutPanes(tab_id, bounds, &panes));
    for (panes) |layout| {
        try testing.expect(layout.rect.cols >= min_pane_cols);
        try testing.expect(layout.rect.rows >= min_pane_rows);
    }
    try testing.expectEqual(root_session, workspace.paneSessionId(tab_id, root_pane).?);
    try testing.expectEqual(right_session, workspace.paneSessionId(tab_id, right).?);
    try testing.expectEqual(lower_left_session, workspace.paneSessionId(tab_id, lower_left).?);
    try testing.expectEqual(lower_right_session, workspace.paneSessionId(tab_id, lower_right).?);

    var dividers: [3]DividerLayout = undefined;
    try testing.expectEqual(@as(usize, 3), try workspace.layoutDividers(tab_id, bounds, &dividers));
    try testing.expectEqual(PaneSplit.right, dividers[0].split);
    try testing.expectEqual(@as(u16, 1), dividers[0].rect.cols);
    try testing.expectEqual(PaneSplit.down, dividers[1].split);
    try testing.expectEqual(@as(u16, 1), dividers[1].rect.rows);
    try testing.expectEqual(PaneSplit.down, dividers[2].split);
    try testing.expectError(error.BufferTooSmall, workspace.layoutPanes(tab_id, bounds, panes[0..3]));
    try testing.expectError(error.BufferTooSmall, workspace.layoutDividers(tab_id, bounds, dividers[0..2]));
}

test "pane divider resize clamps every descendant to two cells" {
    const testing = std.testing;
    const size = try term.GridSize.init(20, 8);
    const bounds = try CellRect.init(0, 0, 11, 7);
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "pane-clamp", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});

    const first_session = try workspace.createSession(.human_terminal, size);
    const tab_id = try workspace.registerTab("clamp", first_session);
    const first = workspace.focusedPaneId(tab_id).?;
    const second_session = try workspace.createSession(.human_terminal, size);
    const second = try workspace.splitPane(tab_id, first, second_session, .right, bounds);
    var dividers: [1]DividerLayout = undefined;
    _ = try workspace.layoutDividers(tab_id, bounds, &dividers);

    try testing.expect(try workspace.resizeDivider(tab_id, dividers[0].divider_id, -100, bounds));
    var panes: [2]PaneLayout = undefined;
    _ = try workspace.layoutPanes(tab_id, bounds, &panes);
    try testing.expectEqual(@as(u16, 2), panes[0].rect.cols);
    try testing.expectEqual(@as(u16, 8), panes[1].rect.cols);
    try testing.expect(!try workspace.resizeDivider(tab_id, dividers[0].divider_id, -1, bounds));

    try testing.expect(try workspace.resizePaneEdge(tab_id, first, .right, 100, bounds));
    _ = try workspace.layoutPanes(tab_id, bounds, &panes);
    try testing.expectEqual(@as(u16, 8), panes[0].rect.cols);
    try testing.expectEqual(@as(u16, 2), panes[1].rect.cols);
    try testing.expectError(
        error.InvalidGeometry,
        workspace.splitPane(
            tab_id,
            second,
            try workspace.createSession(.human_terminal, size),
            .right,
            bounds,
        ),
    );
    try testing.expectError(
        error.InvalidGeometry,
        workspace.layoutPanes(tab_id, try CellRect.init(0, 0, 4, 2), &panes),
    );
}

test "directional pane focus follows the two-dimensional layout" {
    const testing = std.testing;
    const size = try term.GridSize.init(24, 12);
    const bounds = try CellRect.init(0, 0, 25, 13);
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "pane-focus", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});

    const first_session = try workspace.createSession(.human_terminal, size);
    const tab_id = try workspace.registerTab("focus", first_session);
    const upper_left = workspace.focusedPaneId(tab_id).?;
    const upper_right = try workspace.splitPane(
        tab_id,
        upper_left,
        try workspace.createSession(.human_terminal, size),
        .right,
        bounds,
    );
    const lower_left = try workspace.splitPane(
        tab_id,
        upper_left,
        try workspace.createSession(.human_terminal, size),
        .down,
        bounds,
    );
    const lower_right = try workspace.splitPane(
        tab_id,
        upper_right,
        try workspace.createSession(.human_terminal, size),
        .down,
        bounds,
    );

    try workspace.focusPane(tab_id, upper_left);
    try testing.expect(try workspace.focusPaneDirection(tab_id, .right, bounds));
    try testing.expectEqual(upper_right, workspace.focusedPaneId(tab_id).?);
    try testing.expect(try workspace.focusPaneDirection(tab_id, .down, bounds));
    try testing.expectEqual(lower_right, workspace.focusedPaneId(tab_id).?);
    try testing.expect(try workspace.focusPaneDirection(tab_id, .left, bounds));
    try testing.expectEqual(lower_left, workspace.focusedPaneId(tab_id).?);
    try testing.expect(try workspace.focusPaneDirection(tab_id, .up, bounds));
    try testing.expectEqual(upper_left, workspace.focusedPaneId(tab_id).?);
    try testing.expect(!try workspace.focusPaneDirection(tab_id, .up, bounds));
}

test "pane zoom preserves sessions ids dividers and restored geometry" {
    const testing = std.testing;
    const size = try term.GridSize.init(30, 10);
    const bounds = try CellRect.init(2, 1, 21, 9);
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "pane-zoom", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});

    const first_session = try workspace.createSession(.human_terminal, size);
    const tab_id = try workspace.registerTab("zoom", first_session);
    const first = workspace.focusedPaneId(tab_id).?;
    const second_session = try workspace.createSession(.human_terminal, size);
    const second = try workspace.splitPane(tab_id, first, second_session, .right, bounds);
    const first_ptr = workspace.sessionById(first_session).?;
    const second_ptr = workspace.sessionById(second_session).?;
    var before: [2]PaneLayout = undefined;
    _ = try workspace.layoutPanes(tab_id, bounds, &before);
    var divider_before: [1]DividerLayout = undefined;
    _ = try workspace.layoutDividers(tab_id, bounds, &divider_before);

    try testing.expect(try workspace.togglePaneZoom(tab_id));
    try testing.expectEqual(second, workspace.tab(tab_id).?.zoomedPaneId().?);
    var zoomed: [2]PaneLayout = undefined;
    try testing.expectEqual(@as(usize, 1), try workspace.layoutPanes(tab_id, bounds, &zoomed));
    try testing.expectEqual(second, zoomed[0].pane_id);
    try testing.expectEqual(bounds, zoomed[0].rect);
    var hidden_divider: [1]DividerLayout = undefined;
    try testing.expectEqual(@as(usize, 0), try workspace.layoutDividers(tab_id, bounds, &hidden_divider));
    try testing.expect(!try workspace.focusPaneDirection(tab_id, .left, bounds));

    try testing.expect(!try workspace.togglePaneZoom(tab_id));
    var after: [2]PaneLayout = undefined;
    _ = try workspace.layoutPanes(tab_id, bounds, &after);
    var divider_after: [1]DividerLayout = undefined;
    _ = try workspace.layoutDividers(tab_id, bounds, &divider_after);
    try testing.expectEqualDeep(before, after);
    try testing.expectEqualDeep(divider_before, divider_after);
    try testing.expect(first_ptr == workspace.sessionById(first_session).?);
    try testing.expect(second_ptr == workspace.sessionById(second_session).?);
}

test "closing panes rebalances siblings and final pane delegates tab close" {
    const testing = std.testing;
    const size = try term.GridSize.init(30, 10);
    const bounds = try CellRect.init(0, 0, 21, 9);
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "pane-close", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});

    const first_session = try workspace.createSession(.human_terminal, size);
    const tab_id = try workspace.registerTab("close", first_session);
    const first = workspace.focusedPaneId(tab_id).?;
    const second_session = try workspace.createSession(.human_terminal, size);
    const second = try workspace.splitPane(tab_id, first, second_session, .right, bounds);
    const third_session = try workspace.createSession(.human_terminal, size);
    const third = try workspace.splitPane(tab_id, first, third_session, .down, bounds);

    try workspace.focusPane(tab_id, third);
    try testing.expectEqual(ClosePaneResult.pane_closed, try workspace.closePane(tab_id, third));
    try testing.expectEqual(first, workspace.focusedPaneId(tab_id).?);
    try testing.expect(workspace.sessionById(third_session) == null);
    try testing.expectEqual(@as(usize, 2), workspace.tab(tab_id).?.paneCount());
    var panes: [2]PaneLayout = undefined;
    try testing.expectEqual(@as(usize, 2), try workspace.layoutPanes(tab_id, bounds, &panes));

    try testing.expectEqual(ClosePaneResult.pane_closed, try workspace.closePane(tab_id, second));
    try testing.expectEqual(@as(usize, 1), workspace.tab(tab_id).?.paneCount());
    try testing.expectEqual(ClosePaneResult.close_tab, try workspace.closePane(tab_id, first));
    try testing.expect(workspace.sessionById(first_session) != null);
    try testing.expectEqual(@as(usize, 1), workspace.tabCount());
    try workspace.closeTab(tab_id);
    try testing.expect(workspace.sessionById(first_session) == null);
}

test "pane ids and divider ids remain monotonic after close and session lookup follows leaves" {
    const testing = std.testing;
    const size = try term.GridSize.init(30, 10);
    const bounds = try CellRect.init(0, 0, 21, 9);
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "pane-ids", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});

    const first_session = try workspace.createSession(.human_terminal, size);
    const tab_id = try workspace.registerTab("ids", first_session);
    const first = workspace.focusedPaneId(tab_id).?;
    const second_session = try workspace.createSession(.human_terminal, size);
    const second = try workspace.splitPane(tab_id, first, second_session, .right, bounds);
    var initial_divider: [1]DividerLayout = undefined;
    _ = try workspace.layoutDividers(tab_id, bounds, &initial_divider);
    try testing.expectEqual(PaneId.fromOrdinal(1), second);
    try testing.expectEqual(DividerId.first, initial_divider[0].divider_id);
    try testing.expectEqual(
        PaneLocation{ .tab_id = tab_id, .pane_id = second },
        workspace.paneForSession(second_session).?,
    );

    try testing.expectEqual(ClosePaneResult.pane_closed, try workspace.closePane(tab_id, second));
    try testing.expect(workspace.paneForSession(second_session) == null);
    const third_session = try workspace.createSession(.human_terminal, size);
    const third = try workspace.splitPane(tab_id, first, third_session, .down, bounds);
    var replacement_divider: [1]DividerLayout = undefined;
    _ = try workspace.layoutDividers(tab_id, bounds, &replacement_divider);
    try testing.expectEqual(PaneId.fromOrdinal(2), third);
    try testing.expectEqual(DividerId.fromOrdinal(1), replacement_divider[0].divider_id);
    try testing.expectEqual(third_session, workspace.focusedPaneSessionId(tab_id).?);
}

test "impossible pane session creation preserves all state and next identities" {
    const testing = std.testing;
    const size = try term.GridSize.init(30, 10);
    const refused_bounds = try CellRect.init(0, 0, 4, 9);
    const valid_bounds = try CellRect.init(0, 0, 21, 9);
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "pane-refuse", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});

    const root_session = try workspace.createSession(.human_terminal, size);
    const tab_id = try workspace.registerTab("refuse", root_session);
    const root_pane = workspace.focusedPaneId(tab_id).?;
    try testing.expect(try workspace.togglePaneZoom(tab_id));

    const registered_before = workspace.registeredSessionCount();
    const live_before = workspace.sessionCount();
    var layout_before: [1]PaneLayout = undefined;
    try testing.expectEqual(
        @as(usize, 1),
        try workspace.layoutPanes(tab_id, refused_bounds, &layout_before),
    );

    for (0..3) |_| {
        try testing.expectError(
            error.InvalidGeometry,
            workspace.createPaneSession(
                tab_id,
                root_pane,
                .human_terminal,
                size,
                .right,
                refused_bounds,
            ),
        );
        try testing.expectEqual(@as(usize, 1), workspace.tab(tab_id).?.paneCount());
        try testing.expectEqual(registered_before, workspace.registeredSessionCount());
        try testing.expectEqual(live_before, workspace.sessionCount());
        try testing.expectEqual(root_pane, workspace.focusedPaneId(tab_id).?);
        try testing.expectEqual(root_pane, workspace.tab(tab_id).?.zoomedPaneId().?);

        var layout_after: [1]PaneLayout = undefined;
        try testing.expectEqual(
            @as(usize, 1),
            try workspace.layoutPanes(tab_id, refused_bounds, &layout_after),
        );
        try testing.expectEqualDeep(layout_before, layout_after);
        var dividers: [1]DividerLayout = undefined;
        try testing.expectEqual(
            @as(usize, 0),
            try workspace.layoutDividers(tab_id, refused_bounds, &dividers),
        );
    }

    const created = try workspace.createPaneSession(
        tab_id,
        root_pane,
        .human_terminal,
        size,
        .right,
        valid_bounds,
    );
    try testing.expectEqual(session.SessionId.fromOrdinal(2), created.session_id);
    try testing.expectEqual(PaneId.fromOrdinal(1), created.pane_id);
    try testing.expectEqual(created.pane_id, workspace.focusedPaneId(tab_id).?);
    try testing.expect(workspace.tab(tab_id).?.zoomedPaneId() == null);
    var dividers: [1]DividerLayout = undefined;
    _ = try workspace.layoutDividers(tab_id, valid_bounds, &dividers);
    try testing.expectEqual(DividerId.first, dividers[0].divider_id);

    try testing.expectEqual(ClosePaneResult.pane_closed, try workspace.closePane(tab_id, created.pane_id));
    const replacement = try workspace.createPaneSession(
        tab_id,
        root_pane,
        .agent_terminal,
        size,
        .down,
        valid_bounds,
    );
    try testing.expectEqual(session.SessionId.fromOrdinal(3), replacement.session_id);
    try testing.expectEqual(PaneId.fromOrdinal(2), replacement.pane_id);
    _ = try workspace.layoutDividers(tab_id, valid_bounds, &dividers);
    try testing.expectEqual(DividerId.fromOrdinal(1), dividers[0].divider_id);
}

test "failed pane session allocation leaves registry tree and ids untouched" {
    const testing = std.testing;
    const size = try term.GridSize.init(30, 10);
    const bounds = try CellRect.init(0, 0, 21, 9);
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(failing.allocator(), &audit, .local);
    var workspace = try Workspace.init(testing.io, failing.allocator(), "pane-session-atomic", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});

    const root_session = try workspace.createSession(.human_terminal, size);
    const tab_id = try workspace.registerTab("atomic", root_session);
    const root_pane = workspace.focusedPaneId(tab_id).?;
    try testing.expect(try workspace.togglePaneZoom(tab_id));
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try testing.expectError(
        error.OutOfMemory,
        workspace.createPaneSession(
            tab_id,
            root_pane,
            .human_terminal,
            size,
            .right,
            bounds,
        ),
    );
    try testing.expectEqual(@as(usize, 2), workspace.registeredSessionCount());
    try testing.expectEqual(@as(usize, 1), workspace.tab(tab_id).?.paneCount());
    try testing.expectEqual(root_pane, workspace.focusedPaneId(tab_id).?);
    try testing.expectEqual(root_pane, workspace.tab(tab_id).?.zoomedPaneId().?);

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    const created = try workspace.createPaneSession(
        tab_id,
        root_pane,
        .human_terminal,
        size,
        .right,
        bounds,
    );
    try testing.expectEqual(session.SessionId.fromOrdinal(2), created.session_id);
    try testing.expectEqual(PaneId.fromOrdinal(1), created.pane_id);
    var dividers: [1]DividerLayout = undefined;
    _ = try workspace.layoutDividers(tab_id, bounds, &dividers);
    try testing.expectEqual(DividerId.first, dividers[0].divider_id);
}

test "failed pane split leaves the tree focus and monotonic ids untouched" {
    const testing = std.testing;
    const size = try term.GridSize.init(30, 10);
    const bounds = try CellRect.init(0, 0, 21, 9);
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(failing.allocator(), &audit, .local);
    var workspace = try Workspace.init(testing.io, failing.allocator(), "pane-atomic", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});

    const first_session = try workspace.createSession(.human_terminal, size);
    const tab_id = try workspace.registerTab("atomic", first_session);
    const first = workspace.focusedPaneId(tab_id).?;
    const second_session = try workspace.createSession(.human_terminal, size);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try testing.expectError(
        error.OutOfMemory,
        workspace.splitPane(tab_id, first, second_session, .right, bounds),
    );
    try testing.expectEqual(@as(usize, 1), workspace.tab(tab_id).?.paneCount());
    try testing.expectEqual(first, workspace.focusedPaneId(tab_id).?);
    try testing.expect(workspace.paneForSession(second_session) == null);

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    const second = try workspace.splitPane(tab_id, first, second_session, .right, bounds);
    try testing.expectEqual(PaneId.fromOrdinal(1), second);
    var dividers: [1]DividerLayout = undefined;
    _ = try workspace.layoutDividers(tab_id, bounds, &dividers);
    try testing.expectEqual(DividerId.first, dividers[0].divider_id);
}

test "the drain budget stops on an empty pass, the byte cap and the time slice" {
    const testing = std.testing;
    const budget: DrainBudget = .{ .max_bytes = 100, .max_ns = 50 };
    try testing.expect(budget.allowsAnotherPass(1, 0, 0));
    try testing.expect(budget.allowsAnotherPass(10, 99, 49));
    try testing.expect(!budget.allowsAnotherPass(0, 0, 0));
    try testing.expect(!budget.allowsAnotherPass(10, 100, 0));
    try testing.expect(!budget.allowsAnotherPass(10, 200, 0));
    try testing.expect(!budget.allowsAnotherPass(10, 0, 50));
    try testing.expect(!budget.allowsAnotherPass(10, 0, std.math.maxInt(u64)));
    try testing.expect(DrainBudget.per_wake.max_bytes >= 1024 * 1024);
    try testing.expect(DrainBudget.per_wake.max_ns <= 16 * std.time.ns_per_ms);
}

/// Drain one wake's worth of output the way the event loop does, with a fixed
/// elapsed time so the byte cap and the empty pass are what end it.
fn drainOneWake(
    workspace: *Workspace,
    budget: DrainBudget,
    io_buffer: []u8,
    response_buffer: []u8,
    sink: EventSink,
    passes: *usize,
) !usize {
    var total: usize = 0;
    while (true) {
        const result = workspace.pump(io_buffer, response_buffer, sink);
        if (result.first_error) |err| return err;
        passes.* += 1;
        total += result.bytes_drained;
        if (!budget.allowsAnotherPass(result.bytes_drained, total, 0)) return total;
    }
}

test "a multi-megabyte flood reaches the terminal in a bounded number of wakes" {
    const testing = std.testing;
    const size = try term.GridSize.init(40, 4);
    // Records that overwrite one row with a carriage return rather than
    // scroll: the test is about how the drain is bounded, not how fast the
    // engine scrolls, and a Debug engine verifies its whole page list on
    // every scroll. Every byte is still parsed by the real terminal.
    const record = "0123456789abcdef0123456789abcdef\r";
    const record_count = 160 * 1024;
    const marker = "FLOOD-END";
    const flood = try testing.allocator.alloc(u8, record.len * record_count + marker.len);
    defer testing.allocator.free(flood);
    for (0..record_count) |index| @memcpy(flood[index * record.len ..][0..record.len], record);
    @memcpy(flood[record.len * record_count ..], marker);
    try testing.expect(flood.len > 5 * 1024 * 1024);

    var audit: FakeAudit = .{};
    audit.outputs[0] = flood;
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "flood", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});
    const id = try workspace.createSession(.human_terminal, size);
    try spawnAndAttach(&workspace, id);

    var ignored: IgnoredEvents = .{};
    var io_buffer: [64 * 1024]u8 = undefined;
    var response_buffer: [term.response_capacity]u8 = undefined;
    const budget = DrainBudget.per_wake;
    var wakes: usize = 0;
    var passes: usize = 0;
    var total: usize = 0;
    while (workspace.needsPump()) {
        const drained = try drainOneWake(&workspace, budget, &io_buffer, &response_buffer, ignored.sink(), &passes);
        wakes += 1;
        total += drained;
        // No wake overshoots the byte cap by more than one pass.
        try testing.expect(drained <= budget.max_bytes + io_buffer.len);
        try testing.expect(wakes <= flood.len);
    }

    // Every byte reached the terminal, and the wake count is set by the byte
    // budget rather than by how many reads the flood took.
    try testing.expectEqual(flood.len, total);
    const expected_wakes = (flood.len + budget.max_bytes - 1) / budget.max_bytes;
    try testing.expectEqual(@as(usize, 2), expected_wakes);
    try testing.expect(wakes <= expected_wakes);
    try testing.expect(passes >= flood.len / io_buffer.len);
    const live = workspace.sessionById(id) orelse return error.SessionNotFound;
    try live.terminal().refresh(testing.allocator);
    try testing.expect(live.terminalConst().visibleTextContains(marker));
}

test "a real 4 MiB PTY flood is fully consumed within the per-wake budget in bounded time" {
    // Carriage returns rather than newlines, for the same reason as the fake
    // flood above: this proves the drain keeps up with a real reader thread.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const size = try term.GridSize.init(80, 24);
    var workspace = try Workspace.initLocal(testing.io, testing.allocator, "real-flood", "/tmp", size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});
    const id = try workspace.createSession(.human_terminal, size);
    const request = try workspace.spawnRequest(id, .{
        .argv = &.{ "/bin/sh", "-c", "yes 0123456789abcdef | tr '\\n' '\\r' | head -c 4194304" },
        .env = &.{ "PATH=/usr/bin:/bin", "TERM=xterm-256color" },
    });
    try workspace.attachChild(id, try workspace.contextRef().spawn(request));

    var ignored: IgnoredEvents = .{};
    var io_buffer: [64 * 1024]u8 = undefined;
    var response_buffer: [term.response_capacity]u8 = undefined;
    const budget = DrainBudget.per_wake;
    const started = std.Io.Clock.awake.now(testing.io).nanoseconds;
    const deadline = started + 10 * std.time.ns_per_s;
    var total: usize = 0;
    while (std.Io.Clock.awake.now(testing.io).nanoseconds < deadline) {
        const live = workspace.sessionById(id) orelse return error.SessionNotFound;
        const attached = live.child().?;
        if (attached.state() == .exited and !workspace.needsPump()) break;
        if (!workspace.needsPump()) {
            _ = attached.waitReadable(25);
            continue;
        }
        const wake_started = std.Io.Clock.awake.now(testing.io).nanoseconds;
        var wake_total: usize = 0;
        while (true) {
            const result = workspace.pump(&io_buffer, &response_buffer, ignored.sink());
            if (result.first_error) |err| return err;
            wake_total += result.bytes_drained;
            const elapsed: u64 = @intCast(std.Io.Clock.awake.now(testing.io).nanoseconds - wake_started);
            if (!budget.allowsAnotherPass(result.bytes_drained, wake_total, elapsed)) break;
        }
        try testing.expect(wake_total <= budget.max_bytes + io_buffer.len);
        total += wake_total;
    }
    try testing.expectEqual(@as(usize, 4194304), total);
    try testing.expect(!workspace.needsPump());
}

fn contextTmpPath(tmp: *std.testing.TmpDir, buffer: []u8, name: []const u8) ![]const u8 {
    if (name.len == 0) return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path[0..], name });
}

test "a context without file or command capabilities reports them unsupported" {
    const testing = std.testing;
    var audit: FakeAudit = .{};
    var owner = try FakeContext.create(testing.allocator, &audit, .ssh);
    defer owner.deinit();
    const borrowed = owner.borrow();
    var buffer: [8]u8 = undefined;

    try testing.expectError(error.Unsupported, borrowed.readFile(testing.io, "/x", &buffer));
    try testing.expectError(error.Unsupported, borrowed.statPath(testing.io, "/x"));
    try testing.expectError(error.Unsupported, borrowed.watch(testing.allocator, testing.io, "/x"));
    try testing.expectError(error.Unsupported, borrowed.run(testing.allocator, testing.io, .{
        .argv = &.{"true"},
        .cwd = "/",
    }));
}

test "the local context reads bounded files, lists and stats directories" {
    const testing = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "small.md", .data = "hello" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "large.md", .data = "0123456789" });
    try tmp.dir.createDir(testing.io, "nested", .default_dir);

    var context = try ExecutionContext.local(testing.allocator);
    defer context.deinit();
    const local_ref = context.borrow();
    var path_buffer: [256]u8 = undefined;

    var buffer: [8]u8 = undefined;
    const small = try local_ref.readFile(testing.io, try contextTmpPath(&tmp, &path_buffer, "small.md"), &buffer);
    try testing.expectEqualStrings("hello", small);
    try testing.expectError(error.TooLarge, local_ref.readFile(testing.io, try contextTmpPath(&tmp, &path_buffer, "large.md"), &buffer));
    try testing.expectError(error.NotFound, local_ref.readFile(testing.io, try contextTmpPath(&tmp, &path_buffer, "absent.md"), &buffer));
    try testing.expectError(error.IsADirectory, local_ref.readFile(testing.io, try contextTmpPath(&tmp, &path_buffer, "nested"), &buffer));

    // Exactly the buffer size is not too large.
    var exact: [10]u8 = undefined;
    try testing.expectEqualStrings("0123456789", try local_ref.readFile(testing.io, try contextTmpPath(&tmp, &path_buffer, "large.md"), &exact));

    const stat = try local_ref.statPath(testing.io, try contextTmpPath(&tmp, &path_buffer, "small.md"));
    try testing.expectEqual(PathKind.file, stat.kind);
    try testing.expectEqual(@as(u64, 5), stat.size);
    try testing.expectEqual(PathKind.directory, (try local_ref.statPath(testing.io, try contextTmpPath(&tmp, &path_buffer, "nested"))).kind);
    try testing.expectError(error.NotFound, local_ref.statPath(testing.io, try contextTmpPath(&tmp, &path_buffer, "absent")));

    const Collect = struct {
        files: usize = 0,
        dirs: usize = 0,
        visits: usize = 0,
        stop_after: usize = std.math.maxInt(usize),

        fn visit(ptr: *anyopaque, entry: DirEntry) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.visits += 1;
            switch (entry.kind) {
                .file => self.files += 1,
                .directory => self.dirs += 1,
                .other => {},
            }
            return self.visits < self.stop_after;
        }
    };
    var all: Collect = .{};
    try local_ref.listDir(testing.io, try contextTmpPath(&tmp, &path_buffer, ""), .{ .context = &all, .visit_fn = Collect.visit });
    try testing.expectEqual(@as(usize, 2), all.files);
    try testing.expectEqual(@as(usize, 1), all.dirs);

    // Returning false stops the listing: the caller's bound.
    var bounded: Collect = .{ .stop_after = 1 };
    try local_ref.listDir(testing.io, try contextTmpPath(&tmp, &path_buffer, ""), .{ .context = &bounded, .visit_fn = Collect.visit });
    try testing.expectEqual(@as(usize, 1), bounded.visits);

    try testing.expectError(error.NotFound, local_ref.listDir(testing.io, try contextTmpPath(&tmp, &path_buffer, "absent"), .{ .context = &all, .visit_fn = Collect.visit }));
    try testing.expectError(error.NotADirectory, local_ref.listDir(testing.io, try contextTmpPath(&tmp, &path_buffer, "small.md"), .{ .context = &all, .visit_fn = Collect.visit }));
}

test "a local watch flags creation, modification, removal and a late directory without a thread" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var context = try ExecutionContext.local(testing.allocator);
    defer context.deinit();
    var path_buffer: [256]u8 = undefined;

    var handle = try context.borrow().watch(testing.allocator, testing.io, try contextTmpPath(&tmp, &path_buffer, ""));
    defer handle.deinit();
    try testing.expect(!handle.pollChanges());

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.md", .data = "one" });
    try testing.expect(handle.pollChanges());
    // A poll consumes what it reported.
    try testing.expect(!handle.pollChanges());

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.md", .data = "two two" });
    try testing.expect(handle.pollChanges());
    try tmp.dir.deleteFile(testing.io, "a.md");
    try testing.expect(handle.pollChanges());
    try testing.expect(!handle.pollChanges());

    // A directory that does not exist yet is watched from the moment it appears.
    var late = try context.borrow().watch(testing.allocator, testing.io, try contextTmpPath(&tmp, &path_buffer, "late"));
    defer late.deinit();
    try testing.expect(!late.pollChanges());
    try tmp.dir.createDir(testing.io, "late", .default_dir);
    try testing.expect(late.pollChanges());
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "late/b.md", .data = "x" });
    try testing.expect(late.pollChanges());
}

test "the local context runs a bounded command and reports its exit, output and timeout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    var context = try ExecutionContext.local(testing.allocator);
    defer context.deinit();
    const local_ref = context.borrow();

    var ok = try local_ref.run(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "echo ok" },
        .cwd = "/",
        .timeout_ms = 5000,
    });
    defer ok.deinit(testing.allocator);
    try testing.expect(ok.succeeded());
    try testing.expectEqualStrings("ok\n", ok.stdout);
    try testing.expectEqualStrings("", ok.stderr);

    var failed = try local_ref.run(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'bad thing' >&2; exit 3" },
        .cwd = "/",
    });
    defer failed.deinit(testing.allocator);
    try testing.expect(!failed.succeeded());
    try testing.expectEqual(@as(?u8, 3), failed.exit_code);
    try testing.expectEqualStrings("bad thing", failed.stderr);

    var piped = try local_ref.run(testing.allocator, testing.io, .{
        .argv = &.{"cat"},
        .cwd = "/",
        .stdin = "through stdin",
    });
    defer piped.deinit(testing.allocator);
    try testing.expectEqualStrings("through stdin", piped.stdout);

    var cwd = try local_ref.run(testing.allocator, testing.io, .{ .argv = &.{"pwd"}, .cwd = "/tmp" });
    defer cwd.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp\n", cwd.stdout);

    try testing.expectError(error.Timeout, local_ref.run(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 5" },
        .cwd = "/",
        .timeout_ms = 100,
    }));
    try testing.expectError(error.OutputTooLarge, local_ref.run(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "head -c 100000 /dev/zero" },
        .cwd = "/",
        .max_output = 1024,
    }));
    try testing.expectError(error.CommandNotFound, local_ref.run(testing.allocator, testing.io, .{
        .argv = &.{"conduit-no-such-command-62"},
        .cwd = "/",
    }));
    try testing.expectError(error.InvalidRequest, local_ref.run(testing.allocator, testing.io, .{
        .argv = &.{},
        .cwd = "/",
    }));
}

fn reportTestCwd(workspace: *Workspace, id: session.SessionId, cwd: []const u8) !void {
    var buffer: [256]u8 = undefined;
    const osc = try std.fmt.bufPrint(&buffer, "\x1b]7;file://localhost{s}\x07", .{cwd});
    workspace.sessionById(id).?.terminal().feed(osc);
}

/// The registry the TASK-65 tests capture: two local workspaces, the first
/// with a renamed, split, resized, zoomed tab beside a plain one, the second
/// active with one tab whose shell reported a directory of its own.
fn buildPersistenceFixture(
    registry: *WorkspaceRegistry,
    audit: *FakeAudit,
    size: term.GridSize,
    bounds: CellRect,
) !void {
    const testing = std.testing;
    const main_key = try insertFakeWorkspace(registry, testing.io, testing.allocator, audit, "main", "/home/u", size);
    const side_key = try insertFakeWorkspace(registry, testing.io, testing.allocator, audit, "side", "/srv", size);
    const main = registry.byKey(main_key).?;

    const build = try main.createTab("Terminal 1", size);
    const root_pane = main.focusedPaneId(build.tab_id).?;
    const right = try main.createPaneSession(build.tab_id, root_pane, .human_terminal, size, .right, bounds);
    const lower = try main.createPaneSession(build.tab_id, root_pane, .human_terminal, size, .down, bounds);
    // The outer divider starts at 15 of 30 cells; five more make it 20/30.
    try testing.expect(try main.resizePaneEdge(build.tab_id, root_pane, .right, 5, bounds));
    try main.renameTab(build.tab_id, "build");
    try reportTestCwd(main, right.session_id, "/home/u/right");
    try main.focusPane(build.tab_id, lower.pane_id);
    try testing.expect(try main.togglePaneZoom(build.tab_id));
    _ = try main.createTab("Terminal 2", size);
    try main.activateTab(build.tab_id);
    const side = registry.byKey(side_key).?;
    const side_tab = try side.createTab("Terminal 1", size);
    try reportTestCwd(side, side_tab.session_id, "/srv/www");
    try registry.activate(side_key);
}

const persistence_root_leaf: persistence.PaneNode = .{ .leaf = .{ .cwd = "/home/u" } };
const persistence_lower_leaf: persistence.PaneNode = .{ .leaf = .{ .cwd = "/home/u" } };
const persistence_right_leaf: persistence.PaneNode = .{ .leaf = .{ .cwd = "/home/u/right" } };
const persistence_left_column: persistence.PaneNode = .{ .split = .{
    .direction = .down,
    .ratio = 0.5,
    .first = &persistence_root_leaf,
    .second = &persistence_lower_leaf,
} };
const persistence_main_tabs = [_]persistence.TabState{
    .{
        .name = "build",
        .panes = .{ .split = .{
            .direction = .right,
            .ratio = 20.0 / 30.0,
            .first = &persistence_left_column,
            .second = &persistence_right_leaf,
        } },
        .focused_leaf = 1,
        .zoomed = true,
    },
    .{ .panes = .{ .leaf = .{ .cwd = "/home/u" } } },
};
const persistence_side_tabs = [_]persistence.TabState{.{ .panes = .{ .leaf = .{ .cwd = "/srv/www" } } }};
const persistence_workspaces = [_]persistence.WorkspaceState{
    .{ .name = "main", .cwd = "/home/u", .active_tab = 0, .tabs = &persistence_main_tabs },
    .{ .name = "side", .cwd = "/srv", .active_tab = 0, .tabs = &persistence_side_tabs },
};
const persistence_expected: persistence.Snapshot = .{
    .active_workspace = 1,
    .workspaces = &persistence_workspaces,
};

/// Execute a restore plan the way the app does, over fake contexts. Each
/// started shell then reports the directory it was started in.
fn applyTestRestorePlan(
    registry: *WorkspaceRegistry,
    audit: *FakeAudit,
    plan: persistence.RestorePlan,
    size: term.GridSize,
    bounds: CellRect,
) !void {
    const testing = std.testing;
    var keys: [4]WorkspaceKey = undefined;
    var tab_ids: [4][4]TabId = undefined;
    var leaf_panes: [8]PaneId = undefined;
    for (plan.steps) |step| switch (step) {
        .create_workspace => |s| {
            keys[s.workspace] = try insertFakeWorkspace(registry, testing.io, testing.allocator, audit, s.name, s.cwd, size);
        },
        .create_tab => |s| {
            const workspace = registry.byKey(keys[s.workspace]).?;
            const created = try workspace.createTab(s.name orelse "Terminal", size);
            if (s.name) |name| try workspace.renameTab(created.tab_id, name);
            tab_ids[s.workspace][s.tab] = created.tab_id;
            leaf_panes[0] = workspace.focusedPaneId(created.tab_id).?;
            try reportTestCwd(workspace, created.session_id, s.cwd);
        },
        .split_pane => |s| {
            const workspace = registry.byKey(keys[s.workspace]).?;
            const tab_id = tab_ids[s.workspace][s.tab];
            const split: PaneSplit = switch (s.direction) {
                .right => .right,
                .down => .down,
            };
            const created = try workspace.createPaneSession(tab_id, leaf_panes[s.leaf], .human_terminal, size, split, bounds);
            try workspace.setPaneSplitRatio(tab_id, created.pane_id, s.ratio);
            leaf_panes[s.new_leaf] = created.pane_id;
            try reportTestCwd(workspace, created.session_id, s.cwd);
        },
        .focus_pane => |s| try registry.byKey(keys[s.workspace]).?.focusPane(tab_ids[s.workspace][s.tab], leaf_panes[s.leaf]),
        .zoom_pane => |s| _ = try registry.byKey(keys[s.workspace]).?.togglePaneZoom(tab_ids[s.workspace][s.tab]),
        .select_tab => |s| try registry.byKey(keys[s.workspace]).?.activateTab(tab_ids[s.workspace][s.tab]),
        .select_workspace => |s| try registry.activate(keys[s.workspace]),
    };
}

test "a registry snapshot captures workspaces, tabs, pane trees, cwd, focus, zoom and selection" {
    const testing = std.testing;
    const size = try term.GridSize.init(40, 16);
    const bounds = try CellRect.init(0, 0, 31, 17);
    var audit: FakeAudit = .{};
    var registry = WorkspaceRegistry.init(testing.allocator);
    defer registry.deinit() catch |err| std.debug.panic("registry cleanup failed: {s}", .{@errorName(err)});
    try buildPersistenceFixture(&registry, &audit, size, bounds);

    var owned = try registry.snapshot(testing.allocator);
    defer owned.deinit();
    try persistence.expectSameSnapshot(&persistence_expected, &owned.snapshot);
    // Only a renamed tab carries its name; a derived one is assigned again.
    try testing.expect(registry.at(0).?.tabAt(0).?.userNamed());
    try testing.expect(!registry.at(0).?.tabAt(1).?.userNamed());

    // The app's own values join the snapshot through its arena, and the
    // result survives the file format unchanged.
    owned.snapshot.theme = try owned.allocator().dupe(u8, "Gruvbox Dark");
    owned.snapshot.window = .{ .width = 1280, .height = 800 };
    var diagnostic: persistence.Diagnostic = .{};
    const bytes = try persistence.encode(testing.allocator, &owned.snapshot, &diagnostic);
    defer testing.allocator.free(bytes);
    var decoded = try persistence.decode(testing.allocator, bytes, &diagnostic);
    defer decoded.deinit();
    try persistence.expectSameSnapshot(&owned.snapshot, &decoded.snapshot);
}

test "executing a restore plan rebuilds the same workspaces, layout and cwd" {
    const testing = std.testing;
    const size = try term.GridSize.init(40, 16);
    const bounds = try CellRect.init(0, 0, 31, 17);

    var original_audit: FakeAudit = .{};
    var original = WorkspaceRegistry.init(testing.allocator);
    defer original.deinit() catch |err| std.debug.panic("registry cleanup failed: {s}", .{@errorName(err)});
    try buildPersistenceFixture(&original, &original_audit, size, bounds);
    var saved = try original.snapshot(testing.allocator);
    defer saved.deinit();
    var diagnostic: persistence.Diagnostic = .{};
    const bytes = try persistence.encode(testing.allocator, &saved.snapshot, &diagnostic);
    defer testing.allocator.free(bytes);

    // A relaunch: decode the file, plan, and replay through the normal
    // workspace, tab and pane operations.
    var loaded = try persistence.decode(testing.allocator, bytes, &diagnostic);
    defer loaded.deinit();
    var plan = try persistence.planRestore(testing.allocator, &loaded.snapshot);
    defer plan.deinit(testing.allocator);
    var restored_audit: FakeAudit = .{};
    var restored = WorkspaceRegistry.init(testing.allocator);
    defer restored.deinit() catch |err| std.debug.panic("registry cleanup failed: {s}", .{@errorName(err)});
    try applyTestRestorePlan(&restored, &restored_audit, plan, size, bounds);

    var again = try restored.snapshot(testing.allocator);
    defer again.deinit();
    try persistence.expectSameSnapshot(&persistence_expected, &again.snapshot);

    // The restored divider lays out where the saved one did.
    var saved_dividers: [2]DividerLayout = undefined;
    var restored_dividers: [2]DividerLayout = undefined;
    const original_main = original.at(0).?;
    const restored_main = restored.at(0).?;
    _ = try original_main.togglePaneZoom(original_main.tabAt(0).?.id());
    _ = try restored_main.togglePaneZoom(restored_main.tabAt(0).?.id());
    try testing.expectEqual(@as(usize, 2), try original_main.layoutDividers(original_main.tabAt(0).?.id(), bounds, &saved_dividers));
    try testing.expectEqual(@as(usize, 2), try restored_main.layoutDividers(restored_main.tabAt(0).?.id(), bounds, &restored_dividers));
    for (saved_dividers, restored_dividers) |saved_divider, restored_divider| {
        try testing.expectEqual(saved_divider.split, restored_divider.split);
        try testing.expectEqual(saved_divider.rect, restored_divider.rect);
    }
}

test "a split ratio is set only on a divider, within bounds" {
    const testing = std.testing;
    const size = try term.GridSize.init(40, 16);
    const bounds = try CellRect.init(0, 0, 31, 17);
    var audit: FakeAudit = .{};
    const context = try FakeContext.create(testing.allocator, &audit, .local);
    var workspace = try Workspace.init(testing.io, testing.allocator, "ratio", "/tmp", context, size);
    defer workspace.deinit() catch |err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(err)});

    const created = try workspace.createTab("t", size);
    const root = workspace.focusedPaneId(created.tab_id).?;
    try testing.expectError(error.NotSplit, workspace.setPaneSplitRatio(created.tab_id, root, 0.5));
    const right = try workspace.createPaneSession(created.tab_id, root, .human_terminal, size, .right, bounds);
    try testing.expectError(error.InvalidRatio, workspace.setPaneSplitRatio(created.tab_id, right.pane_id, 0));
    try testing.expectError(error.InvalidRatio, workspace.setPaneSplitRatio(created.tab_id, right.pane_id, 1));
    try testing.expectError(error.InvalidRatio, workspace.setPaneSplitRatio(created.tab_id, right.pane_id, std.math.nan(f32)));
    try testing.expectError(error.UnknownPane, workspace.setPaneSplitRatio(created.tab_id, PaneId.fromOrdinal(99), 0.5));
    try testing.expectError(error.UnknownTab, workspace.setPaneSplitRatio(TabId.fromOrdinal(99), right.pane_id, 0.5));

    // A quarter of the 30 cells beside the divider, from either child.
    try workspace.setPaneSplitRatio(created.tab_id, root, 0.25);
    var panes: [2]PaneLayout = undefined;
    try testing.expectEqual(@as(usize, 2), try workspace.layoutPanes(created.tab_id, bounds, &panes));
    try testing.expectEqual(@as(u16, 8), panes[0].rect.cols);
    // An extreme ratio still leaves each pane its minimum.
    try workspace.setPaneSplitRatio(created.tab_id, right.pane_id, persistence.max_ratio);
    _ = try workspace.layoutPanes(created.tab_id, bounds, &panes);
    try testing.expectEqual(min_pane_cols, panes[1].rect.cols);
}

test "an ssh workspace snapshot keeps its target but never its test-only config file" {
    const testing = std.testing;
    if (!ssh.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var relative: [128]u8 = undefined;
    // A relative runtime directory keeps the control socket path short; no
    // master is started, so it is never bound.
    const runtime_dir = try std.fmt.bufPrint(&relative, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});

    const size = try term.GridSize.init(40, 16);
    const options = [_][]const u8{"ServerAliveInterval=30"};
    // Creating the context validates and prepares its control directory but
    // starts no process; nothing connects in this test.
    const context = ssh.SshContext.create(testing.allocator, testing.io, .{
        .target = .{ .destination = "deploy@prod", .port = 2222, .config_file = "/dev/null", .options = &options },
        .local_env = &.{},
        .runtime_dir = runtime_dir,
    }) catch |err| switch (err) {
        // A deep worktree path can exceed sockaddr_un; that is not this test.
        error.ControlPathTooLong => return error.SkipZigTest,
        else => return err,
    };
    var candidate = try Workspace.init(testing.io, testing.allocator, "prod", "/home/deploy", context, size);
    var registry = WorkspaceRegistry.init(testing.allocator);
    defer registry.deinit() catch |err| std.debug.panic("registry cleanup failed: {s}", .{@errorName(err)});
    _ = registry.insert(&candidate) catch |err| {
        candidate.deinit() catch |cleanup_err| std.debug.panic("workspace cleanup failed: {s}", .{@errorName(cleanup_err)});
        return err;
    };

    var owned = try registry.snapshot(testing.allocator);
    defer owned.deinit();
    const captured = owned.snapshot.workspaces[0];
    try testing.expectEqual(persistence.ContextKind.ssh, captured.kind);
    try testing.expectEqualStrings("deploy@prod", captured.ssh.?.destination);
    try testing.expectEqual(@as(?u16, 2222), captured.ssh.?.port);
    try testing.expectEqual(@as(usize, 1), captured.ssh.?.options.len);
    try testing.expectEqualStrings("ServerAliveInterval=30", captured.ssh.?.options[0]);

    var diagnostic: persistence.Diagnostic = .{};
    const bytes = try persistence.encode(testing.allocator, &owned.snapshot, &diagnostic);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "/dev/null") == null);
    var plan = try persistence.planRestore(testing.allocator, &owned.snapshot);
    defer plan.deinit(testing.allocator);
    try testing.expect(plan.steps[0].create_workspace.needs_reconnect);
    try testing.expectEqualStrings("deploy@prod", plan.steps[0].create_workspace.ssh.?.destination);
}

test {
    // The SSH context's unit and sshd-container integration tests.
    _ = ssh;
}
