//! The PTY abstraction: one live terminal, and the backends that give it one.
//!
//! **Owns** spawning a process under a pseudo-terminal, the terminal's size in character cells,
//! moving bytes in both directions, and reporting how the child ended. **Never** parses the bytes
//! it moves — VT parsing and terminal state belong to `term` — and never assumes the machine is
//! local: a session spawned through an SSH ExecutionContext uses this same interface with another
//! backend (P7, `docs/architecture.md` §2).
//! **May depend on** `std` and the OS, and on no other Conduit module.
//!
//! ## The interface
//!
//! `Pty` is a handle and a vtable, and every type in it is Zig's own: `SpawnRequest`,
//! `WindowSize`, `Signal`, `ExitStatus`, `ChildState`. No `pid_t`, no file descriptor, no
//! `struct winsize`, no `HANDLE` and no OS error union appears anywhere in that surface, which is
//! what lets two backends implement it without changing a caller: `PosixPty` with `sys` on Linux
//! and macOS, `ConPty` with `win` on Windows. Each pair is private to this file.
//!
//! ## Threads
//!
//! Three owners, no shared mutable state, no lock (`AGENTS.md`, `docs/architecture.md` §5):
//!
//! | State | Owner | How it crosses |
//! |---|---|---|
//! | `write`, `resize`, `kill`, `takeBytes`, `state`, `waitReadable`, `destroy` | the calling thread, normally the render/UI thread | direct calls |
//! | the read side of the terminal, the wait that collects the child | one read thread per pty, started by `spawn` | bytes through the byte ring, the child's end through one atomic word |
//! | the byte ring and the wakeup channels | both threads | atomics, and one pipe per direction on POSIX (each drained by exactly one thread) or events on Windows |
//!
//! The render/UI thread never blocks on IO: `takeBytes` and `state` are plain reads that cannot
//! wait, and `waitReadable` blocks only until the owner gives it a deadline, which is what lets an
//! idle event loop sleep instead of spinning. The read thread is the only thread that ever blocks
//! on the pty, and the only one that ever waits for the child.
//!
//! A `write` is bounded the way any terminal write is — by the terminal's own input buffer — so a
//! paste larger than that buffer is delivered as the child accepts it rather than all at once.
//! Nothing here waits on a child, a file or the network.
//!
//! ## How a child's end is reported
//!
//! The read thread owns the wait. It is the only thread that blocks on the terminal, so it is the
//! one that notices the hangup, and the one that collects the child. It publishes the outcome as
//! a single atomic word the owner reads without waiting (`state`), and signals the owner's wakeup
//! channel so an owner asleep in `waitReadable` is told at once. A completion rather than a callback
//! or a pollable descriptor, because: exactly one thread can ever reap a given child, the owner
//! never has to hold a lock to ask, and the status can never arrive before the last byte that child
//! wrote.
//!
//! ## Memory
//!
//! `spawn` takes the allocator explicitly and everything it allocates for one terminal is
//! owned by the `Pty` it returns: the handle itself and one fixed-size byte ring. Nothing is
//! allocated after the pty exists — the read thread copies into the ring and the owner copies out
//! of it — so neither a busy terminal nor a slow frame allocates. `destroy` joins the read thread,
//! closes every descriptor or handle and frees it. What a spawn builds before the child exists is
//! freed by the spawn itself: the argv/envp buffers a forked child needs, because a forked child
//! of a threaded process must not touch the allocator, and the UTF-16 command line, environment
//! block and attribute list `CreateProcessW` needs, because it copies all three before it returns.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

/// The log scope for PTY failures. TASK-6 replaces this with the project's diagnostics
/// infrastructure.
pub const log = std.log.scoped(.pty);

/// Everything the interface can report, on every platform.
///
/// An OS error never escapes: `pty` maps each one onto this set, logs what it was, and hands the
/// caller a value it can branch on (`AGENTS.md`: errors are returned, never swallowed, and never
/// asserted on).
pub const Error = error{
    /// The request named no program to run.
    EmptyArgv,
    /// A string in the request contained a NUL byte, which `execve` would silently truncate at.
    EmbeddedNul,
    /// A string in the request was not valid UTF-8. Only the Windows backend can report it: it
    /// converts every string to UTF-16 to hand it to `CreateProcessW`, and a program started with a
    /// mangled argument is worse than a spawn that did not happen.
    InvalidUtf8,
    /// An environment entry was not `KEY=VALUE`.
    InvalidEnvironmentEntry,
    /// `argv[0]` named no executable on the PATH the request carries.
    ProgramNotFound,
    /// The OS would not give Conduit a pseudo-terminal.
    PtyUnavailable,
    /// The child could not be started: the fork failed, or the program could not be executed.
    SpawnFailed,
    /// The allocator would not provide what a terminal needs.
    OutOfMemory,
    /// The terminal is gone — its child exited and the pty hung up. Nothing more can be written.
    Closed,
    /// An OS call failed in a way this interface does not model. The reason is logged.
    SystemError,
    /// This build has no backend for this platform.
    UnsupportedPlatform,
};

/// The signals Conduit sends to a child.
///
/// Deliberately not the OS's whole signal vocabulary: a terminal hangs up, interrupts and stops,
/// and that is all it needs to express. A backend maps whatever its platform calls those onto
/// these, so a caller never sees a `SIG*` constant or a raw signal number.
pub const Signal = enum {
    /// The terminal went away: the child should end its session. SIGHUP on POSIX.
    hangup,
    /// Interrupt, as Ctrl+C does. SIGINT on POSIX.
    interrupt,
    /// Ask the program to stop. SIGTERM on POSIX.
    terminate,
    /// Stop now, with no chance to clean up. SIGKILL on POSIX.
    kill,
};

/// How a child ended.
pub const ExitStatus = union(enum) {
    /// The child exited on its own with this code.
    code: u32,
    /// The child was ended by a signal Conduit names.
    signal: Signal,
    /// The child ended in a way this backend does not model — a signal outside `Signal`, or an end
    /// it could not collect. Reported rather than dropped, so a session's end is never silent.
    unknown,
};

/// What a terminal knows about its child right now. A value, not an event: reading it cannot block.
pub const ChildState = union(enum) {
    running,
    exited: ExitStatus,
};

/// One spawn, in Zig's own types. The caller owns `argv`, `env` and `cwd` for the duration of the
/// `spawnPosix` call only; the pty keeps copies of what the child needs.
pub const SpawnRequest = struct {
    /// `argv[0]` is the program. A name with no `/` is looked up on `PATH` — the `PATH` from `env`,
    /// because the environment a workspace was given is the environment its shell runs in (P7).
    argv: []const []const u8,
    /// The child's whole environment, one `KEY=VALUE` entry each. Conduit never inherits the
    /// process's own environment: a spawn belongs to an ExecutionContext (P7).
    env: []const []const u8,
    /// The child's working directory. Empty means "the process's own directory".
    cwd: []const u8,
    /// The size the terminal starts at, applied before the child exists.
    size: WindowSize,
};

/// A live terminal, seen from outside.
///
/// A value of this type is a handle plus a vtable: it owns whatever its backend allocated, and
/// `destroy` releases all of it. The methods below are the whole surface a session may use; each
/// forwards to the backend, so the concrete terminal, its descriptors and its process are never in
/// reach of a caller.
pub const Pty = struct {
    /// The backend's own state, never dereferenced by anything but the backend.
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Write bytes to the terminal's input, as though they were typed. Returns how many were
    /// taken: a short write is normal, and the caller retries the rest.
    pub const WriteFn = *const fn (ptr: *anyopaque, bytes: []const u8) Error!usize;

    /// Tell the terminal its size changed. The OS turns this into the resize a program sees, and
    /// into `SIGWINCH` for whatever is in the foreground.
    pub const ResizeFn = *const fn (ptr: *anyopaque, size: WindowSize) Error!void;

    /// Send a signal to the child. `error.Closed` once the child has been collected: Conduit never
    /// signals a process id the OS may already have handed to somebody else.
    pub const KillFn = *const fn (ptr: *anyopaque, signal: Signal) Error!void;

    /// Copy out what the read thread has collected, into a buffer the caller already owns.
    /// Returns the number of bytes copied; `0` means nothing has arrived. Never blocks, never
    /// allocates, and never drops what it has not handed over yet.
    pub const TakeBytesFn = *const fn (ptr: *anyopaque, dest: []u8) usize;

    /// The child's state right now. Never blocks.
    pub const StateFn = *const fn (ptr: *anyopaque) ChildState;

    /// Wait until bytes or an exit are pending, or until `timeout_ms` elapses; returns whether
    /// something became available. This is the terminal's answer to "is there a window event?": it
    /// lets an idle event loop sleep with a deadline instead of spinning.
    pub const WaitReadableFn = *const fn (ptr: *anyopaque, timeout_ms: u32) bool;

    /// Release everything: join the read thread, close every descriptor, free the handle. The
    /// `Pty` value is dead afterwards and must not be used again.
    pub const DestroyFn = *const fn (ptr: *anyopaque) void;

    pub const VTable = struct {
        write: WriteFn,
        resize: ResizeFn,
        kill: KillFn,
        takeBytes: TakeBytesFn,
        state: StateFn,
        waitReadable: WaitReadableFn,
        destroy: DestroyFn,
    };

    pub fn write(self: Pty, bytes: []const u8) Error!usize {
        return self.vtable.write(self.ptr, bytes);
    }

    pub fn resize(self: Pty, size: WindowSize) Error!void {
        return self.vtable.resize(self.ptr, size);
    }

    pub fn kill(self: Pty, signal: Signal) Error!void {
        return self.vtable.kill(self.ptr, signal);
    }

    pub fn takeBytes(self: Pty, dest: []u8) usize {
        return self.vtable.takeBytes(self.ptr, dest);
    }

    pub fn state(self: Pty) ChildState {
        return self.vtable.state(self.ptr);
    }

    pub fn waitReadable(self: Pty, timeout_ms: u32) bool {
        return self.vtable.waitReadable(self.ptr, timeout_ms);
    }

    pub fn destroy(self: Pty) void {
        self.vtable.destroy(self.ptr);
    }
};

/// Start a terminal on whichever backend this build has: ConPTY on Windows, the POSIX backend on
/// Linux and macOS.
///
/// The one place that chooses a backend, so nothing above `pty` needs an OS conditional
/// (`AGENTS.md`, invariant 10). Both branches are chosen at compile time, so a build never
/// contains the other platform's code at all.
pub fn spawn(gpa: Allocator, request: SpawnRequest) Error!Pty {
    if (comptime builtin.os.tag == .windows) return spawnConPty(gpa, request);
    if (comptime has_posix_backend) return spawnPosix(gpa, request);
    return sys.unsupported();
}

/// Whether this build has a POSIX PTY backend. False only on platforms no backend covers, where
/// `spawn` reports `error.UnsupportedPlatform` and the integration tests skip.
const has_posix_backend = builtin.os.tag == .linux or builtin.os.tag == .macos;

/// Whether this build has a Windows PTY backend. True only on Windows, where `spawn` attaches a
/// child to a pseudoconsole rather than opening `/dev/ptmx`.
const has_conpty_backend = builtin.os.tag == .windows;

/// The size of a terminal in character cells, as the OS is told about it.
///
/// Invariant: both dimensions are at least one cell. A zero-row terminal has no lines to write, and
/// the shells and TUIs Conduit runs treat it as a broken pty rather than a small one.
pub const WindowSize = struct {
    rows: u16,
    cols: u16,

    /// The smallest terminal that exists. Anything smaller is clamped up to it.
    pub const min_dimension: u16 = 1;

    /// Build a window size, clamping each dimension up to `min_dimension`.
    ///
    /// Clamping rather than failing is deliberate: a window that is resized to nothing while the
    /// user drags a divider past the edge must keep a working shell, not lose it.
    pub fn init(rows: u32, cols: u32) WindowSize {
        return .{
            .rows = clampDimension(rows),
            .cols = clampDimension(cols),
        };
    }

    /// The number of cells in the grid this size describes.
    pub fn cells(self: WindowSize) u32 {
        return @as(u32, self.rows) * @as(u32, self.cols);
    }

    /// Encode a resize request as four little-endian `u16` fields — rows, cols, then the pixel
    /// dimensions, which Conduit leaves at zero because it has no reason to lie about a cell's
    /// pixel size.
    ///
    /// This is the portable wire form, for a resize that crosses a boundary the OS is not part of
    /// (an SSH ExecutionContext, TASK-43). A local backend does not use it: it hands the OS a
    /// `struct winsize` in the machine's own byte order, which is what the kernel reads.
    ///
    /// Returns a fixed eight-byte buffer, so a caller never allocates to resize a terminal.
    pub fn encode(self: WindowSize) [8]u8 {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u16, bytes[0..2], self.rows, .little);
        std.mem.writeInt(u16, bytes[2..4], self.cols, .little);
        std.mem.writeInt(u16, bytes[4..6], 0, .little);
        std.mem.writeInt(u16, bytes[6..8], 0, .little);
        return bytes;
    }

    /// Decode a resize request produced by `encode`.
    pub fn decode(bytes: [8]u8) WindowSize {
        return .{
            .rows = std.mem.readInt(u16, bytes[0..2], .little),
            .cols = std.mem.readInt(u16, bytes[2..4], .little),
        };
    }
};

fn clampDimension(value: u32) u16 {
    const clamped: u32 = @max(value, WindowSize.min_dimension);
    return @intCast(@min(clamped, std.math.maxInt(u16)));
}

// ---------------------------------------------------------------------------
// The POSIX backend
// ---------------------------------------------------------------------------

/// Start a terminal on this machine: one child process under a pseudo-terminal.
///
/// Ownership transfers to the returned `Pty`: the caller gives up nothing but its copy of
/// `request`, and `destroy` releases the handle, the read thread and every descriptor.
pub fn spawnPosix(gpa: Allocator, request: SpawnRequest) Error!Pty {
    try validate(request);

    // Opening the terminal first, and the child second, means a program that cannot be executed is
    // never reported as a running shell.
    const pair = try sys.openPty();
    errdefer sys.close(pair.master);
    // The parent holds the slave only until the child exists. Holding it afterwards would keep the
    // pty alive for as long as Conduit runs, and the child's hangup would never arrive.
    var slave_held = true;
    errdefer if (slave_held) sys.close(pair.slave);

    try sys.setWindowSize(pair.slave, request.size);

    // Two pipes, both close-on-exec. The first reports why a forked child could not become its
    // program: the write end closes by itself when the exec succeeds, so the read ends there, and a
    // byte on it means the child is telling the parent what went wrong.
    const status = try sys.pipe();
    var status_held = true;
    errdefer if (status_held) {
        sys.close(status[0]);
        sys.close(status[1]);
    };

    // Then the two wakeup channels between this thread and the read thread, one per direction.
    // Neither ever blocks, and a byte on either only ever means "look again".
    const owner_wake = try sys.wakePipe();
    errdefer sys.close(owner_wake[0]);
    errdefer sys.close(owner_wake[1]);
    const reader_wake = try sys.wakePipe();
    errdefer sys.close(reader_wake[0]);
    errdefer sys.close(reader_wake[1]);

    // Everything the child needs from execve is allocated now: after the fork it may not take a
    // lock or call into the allocator.
    var prepared = try Prepared.init(gpa, request);
    defer prepared.deinit(gpa);

    const child = try sys.fork();
    if (child == 0) childMain(pair, status[1], prepared);

    sys.close(pair.slave);
    slave_held = false;

    // The parent's copy of the write end goes before the read: the read ends when every copy of
    // that end is closed, and holding one here would wait for a child that already exec'd.
    sys.close(status[1]);
    const exec_failure = sys.readExecStatus(status[0]);
    sys.close(status[0]);
    status_held = false;
    if (exec_failure) |why| {
        if (why.errno) |errno| {
            log.err("cannot start {s}: {s} (errno {d})", .{
                prepared.program,
                describeChildFailure(why.reason),
                errno,
            });
        } else {
            log.err("cannot start {s}: {s}", .{
                prepared.program,
                describeChildFailure(why.reason),
            });
        }
        // The child is on its way out, so collect it: a failed spawn must not leave a process
        // behind. If the collection itself fails there is nothing to tell the caller that is not
        // already in the line above, and the reason goes to the log.
        abandonChild(child);
        return error.SpawnFailed;
    }
    const pty = gpa.create(PosixPty) catch |err| return err;
    errdefer gpa.destroy(pty);

    pty.* = .{
        .gpa = gpa,
        .master = pair.master,
        .child = child,
        .reader = null,
        .queue = undefined,
        .owner_wake = owner_wake,
        .reader_wake = reader_wake,
        .stopping = .init(false),
        .end = .init(EndWord.running),
    };

    pty.queue = ByteRing.create(gpa, PosixPty.queue_capacity) catch |err| return err;
    errdefer pty.queue.destroy(gpa);

    pty.reader = std.Thread.spawn(.{}, PosixPty.readThread, .{pty}) catch |err| {
        log.err("cannot start the read thread: {s}", .{@errorName(err)});
        // A terminal with no reader would be a terminal nobody can read, so stop the child rather
        // than hand back a handle that cannot work.
        abandonChild(child);
        return error.SpawnFailed;
    };

    log.debug("terminal started: pid {d}, {d}x{d}", .{
        @as(u32, @intCast(child)),
        request.size.rows,
        request.size.cols,
    });
    return .{ .ptr = pty, .vtable = &PosixPty.vtable };
}

/// Reject a request the OS would only fail on later, before anything is created.
fn validate(request: SpawnRequest) Error!void {
    if (request.argv.len == 0 or request.argv[0].len == 0) return error.EmptyArgv;
    for (request.argv) |arg| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.EmbeddedNul;
    }
    for (request.env) |entry| {
        if (std.mem.indexOfScalar(u8, entry, 0) != null) return error.EmbeddedNul;
        if (std.mem.indexOfScalar(u8, entry, '=') == null) return error.InvalidEnvironmentEntry;
    }
    if (std.mem.indexOfScalar(u8, request.cwd, 0) != null) return error.EmbeddedNul;
}

/// Stop and collect a child whose terminal is never going to exist. Only a spawn that has already
/// failed gets here, and the caller is about to return that failure, so the collection's own
/// outcome changes nothing — it goes to the log.
fn abandonChild(child: sys.pid_t) void {
    sys.signal(child, .kill) catch |err| log.warn(
        "cannot stop the child {d}: {s}",
        .{ @as(u32, @intCast(child)), @errorName(err) },
    );
    _ = sys.waitpid(child, false) catch |err| log.warn(
        "cannot collect the child {d}: {s}",
        .{ @as(u32, @intCast(child)), @errorName(err) },
    );
}

/// One live terminal on a POSIX machine: descriptors, a child, a byte ring and a read thread.
const PosixPty = struct {
    /// Bytes the read thread may hold for the owner. A full ring stops the reader, which lets the
    /// pty buffer fill and the child block — the backpressure a terminal applies when it cannot
    /// keep up. Bytes are never dropped.
    const queue_capacity = 64 * 1024;

    /// How long the read thread waits between looks for a child that closed its terminal without
    /// exiting. Short, so a stop request is noticed; long enough to cost nothing.
    const reap_interval_ms = 20;

    /// How many descriptors a live terminal holds: the master, and both ends of both wake pipes.
    const descriptor_count = 5;

    gpa: Allocator,
    master: sys.fd_t,
    child: sys.pid_t,
    reader: ?std.Thread,
    queue: ByteRing,
    /// Reader to owner: the read thread writes it when it has queued bytes or published the
    /// child's end, and only the owner drains it, in `waitUntilPending`.
    ///
    /// Each direction has its own pipe, with exactly one thread that ever drains it, because a
    /// single pipe shared by both directions loses wakeups. With one pipe the reader, finding the
    /// ring full, could be overtaken before it waited: the owner took every byte and wrote "room",
    /// then found the ring empty and, waiting for output, drained that very byte. The reader then
    /// waited on a pipe nobody would write again — the owner only signals after taking something,
    /// and the end is published by the stalled reader itself — and the session froze. With one
    /// consumer per channel a byte written after that consumer's last drain stays there until it
    /// looks, and every consumer re-checks its predicate after draining, so a hint can be early
    /// or redundant but never lost.
    owner_wake: [2]sys.fd_t,
    /// Owner to reader: the owner writes it when `takeBytes` made room and when `destroy` asks the
    /// read thread to stop, and only the read thread drains it.
    reader_wake: [2]sys.fd_t,
    stopping: std.atomic.Value(bool),
    /// The child's end. Written once, by the read thread, and read by everybody.
    end: std.atomic.Value(EndWord),
    /// Test-only: holds the read thread between finding the ring full and waiting for room, so a
    /// test can run the owner through exactly the interleaving that once lost a wakeup. Absent
    /// from every non-test build.
    park: if (builtin.is_test) ReaderPark else void = if (builtin.is_test) .{} else {},

    const vtable: Pty.VTable = .{
        .write = writeTerminal,
        .resize = resizeTerminal,
        .kill = signalChild,
        .takeBytes = takeBytes,
        .state = childState,
        .waitReadable = waitReadable,
        .destroy = destroy,
    };

    /// The body of the read thread, and the only place a terminal blocks on IO.
    fn readThread(self: *PosixPty) void {
        var buffer: [4096]u8 = undefined;
        self.pump(&buffer);
        self.publishEnd();
    }

    /// Read until the child hangs up or the owner asks to stop.
    fn pump(self: *PosixPty, buffer: []u8) void {
        while (!self.stopping.load(.acquire)) {
            var fds = [_]sys.pollfd{
                .{ .fd = self.master, .events = sys.poll_in, .revents = 0 },
                .{ .fd = self.reader_wake[0], .events = sys.poll_in, .revents = 0 },
            };
            sys.poll(&fds, -1) catch |err| {
                log.err("cannot wait on the terminal: {s}", .{@errorName(err)});
                return;
            };
            if (fds[1].revents & (sys.poll_in | sys.poll_hup) != 0) drainWake(self.reader_wake);
            if (fds[0].revents & (sys.poll_in | sys.poll_hup) == 0) continue;

            // The master reported readable, so this read returns immediately.
            const count = sys.read(self.master, buffer) catch |err| {
                if (err != error.Closed) {
                    log.err("cannot read from the terminal: {s}", .{@errorName(err)});
                }
                return;
            };
            if (count == 0) return; // The child hung up: this terminal will never produce bytes.
            self.enqueue(buffer[0..count]);
        }
    }

    /// Hand bytes to the owner, waiting for room rather than losing them.
    fn enqueue(self: *PosixPty, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            rest = rest[self.queue.append(rest)..];
            if (rest.len == 0) break;
            if (self.stopping.load(.acquire)) return;
            if (comptime builtin.is_test) self.park.hold(&self.stopping);
            // The owner is not keeping up. Stop reading until it has made room.
            // Room made after the failed append above left a byte on the reader's own channel,
            // which nobody else drains, so this wait cannot miss it.
            sys.pollOne(self.reader_wake[0], -1) catch |err| {
                log.err("cannot wait for the owner to drain the terminal: {s}", .{@errorName(err)});
                return;
            };
            drainWake(self.reader_wake);
        }
        // Notify on every chunk rather than only on the empty-to-non-empty edge: without a lock
        // that edge is a race, and one byte per read is cheaper than getting it wrong. A pipe that
        // is already full is already readable, so a dropped byte here loses no wakeup.
        notify(self.owner_wake);
    }

    /// Wait until the child is over, and publish how it ended.
    fn publishEnd(self: *PosixPty) void {
        while (true) {
            const status = sys.waitpid(self.child, true) catch |err| {
                // A child Conduit cannot wait for is still a child that ended: report the end as
                // unknown rather than leaving a session's end unreported.
                log.err("cannot collect the exit status of the child: {s}", .{@errorName(err)});
                self.end.store(.unknown, .release);
                notify(self.owner_wake);
                return;
            };
            if (status) |raw| {
                self.end.store(EndWord.fromStatus(raw), .release);
                notify(self.owner_wake);
                return;
            }
            // The child closed its terminal without exiting. Look again in short steps, so a stop
            // request is answered — a terminal being destroyed is one nobody looks at again, and
            // needs no end — instead of blocking on a process that may never end.
            if (self.stopping.load(.acquire)) return;
            sys.pollOne(self.reader_wake[0], reap_interval_ms) catch |err| {
                log.err("cannot wait for the child to end: {s}", .{@errorName(err)});
                return;
            };
            drainWake(self.reader_wake);
        }
    }

    fn waitUntilPending(self: *PosixPty, timeout_ms: u32) bool {
        const deadline = sys.monotonicMillis() + timeout_ms;
        while (true) {
            if (self.hasPending()) return true;
            if (self.stopping.load(.acquire)) return false;
            const now = sys.monotonicMillis();
            if (now >= deadline) return false;
            // A bounded step, so a stop request or an exit is answered promptly even when the
            // timeout is long.
            const step = @min(deadline - now, @as(u64, 50));
            sys.pollOne(self.owner_wake[0], @intCast(step)) catch |err| {
                log.err("cannot wait on the terminal: {s}", .{@errorName(err)});
                return false;
            };
            drainWake(self.owner_wake);
        }
    }

    /// Whether the owner has something to look at: bytes, or the child's end.
    fn hasPending(self: *PosixPty) bool {
        return self.queue.len() != 0 or self.finished();
    }

    fn finished(self: *const PosixPty) bool {
        return self.end.load(.acquire).kind != .running;
    }

    /// Wake the one thread that drains `channel`.
    fn notify(channel: [2]sys.fd_t) void {
        sys.notify(channel[1]);
    }

    /// Take whatever wakeup bytes are waiting on `channel`. Only that channel's one consumer calls
    /// this: a byte is a hint, and the predicate the consumer re-checks afterwards is the truth.
    fn drainWake(channel: [2]sys.fd_t) void {
        var scratch: [64]u8 = undefined;
        while (sys.readAvailable(channel[0], &scratch) catch null) |count| {
            if (count == 0) break;
        }
    }
};

fn writeTerminal(ptr: *anyopaque, bytes: []const u8) Error!usize {
    const self: *PosixPty = @ptrCast(@alignCast(ptr));
    return sys.write(self.master, bytes);
}

fn resizeTerminal(ptr: *anyopaque, size: WindowSize) Error!void {
    const self: *PosixPty = @ptrCast(@alignCast(ptr));
    return sys.setWindowSize(self.master, size);
}

fn signalChild(ptr: *anyopaque, signal: Signal) Error!void {
    const self: *PosixPty = @ptrCast(@alignCast(ptr));
    // Conduit never signals a process id the read thread has already collected: the OS may have
    // handed that number to somebody else. The end word is published the moment it is reaped.
    if (self.finished()) return error.Closed;
    return sys.signal(self.child, signal);
}

fn takeBytes(ptr: *anyopaque, dest: []u8) usize {
    const self: *PosixPty = @ptrCast(@alignCast(ptr));
    const taken = self.queue.take(dest);
    // Draining may have made room where there was none, and the read thread is waiting for exactly
    // that when the queue was full. A byte on the reader's channel costs one syscall per frame and
    // cannot be lost, since only the reader drains it; leaving the reader asleep there would stall
    // the terminal instead.
    if (taken != 0) PosixPty.notify(self.reader_wake);
    return taken;
}

fn childState(ptr: *anyopaque) ChildState {
    const self: *PosixPty = @ptrCast(@alignCast(ptr));
    return self.end.load(.acquire).toChildState();
}

fn waitReadable(ptr: *anyopaque, timeout_ms: u32) bool {
    const self: *PosixPty = @ptrCast(@alignCast(ptr));
    return self.waitUntilPending(timeout_ms);
}

fn destroy(ptr: *anyopaque) void {
    const self: *PosixPty = @ptrCast(@alignCast(ptr));
    self.stopping.store(true, .release);
    // Wake the read thread wherever it is waiting, so joining it is a deadline, not a hope. Every
    // place it waits watches its own channel.
    PosixPty.notify(self.reader_wake);
    if (self.reader) |thread| thread.join();
    // Closing the master is the hangup: the OS ends the child's terminal when the last one goes.
    sys.close(self.master);
    sys.close(self.owner_wake[0]);
    sys.close(self.owner_wake[1]);
    sys.close(self.reader_wake[0]);
    sys.close(self.reader_wake[1]);
    self.queue.destroy(self.gpa);
    self.gpa.destroy(self);
}

/// Test-only gate a `PosixPty` read thread passes between finding the ring full and waiting for
/// room. Armed by a test; the read thread then reports that it is parked and waits for release.
const ReaderPark = struct {
    const disarmed = 0;
    const armed = 1;
    const parked = 2;
    const released = 3;

    word: std.atomic.Value(u8) = .init(disarmed),

    fn hold(self: *ReaderPark, stopping: *const std.atomic.Value(bool)) void {
        if (self.word.cmpxchgStrong(armed, parked, .acq_rel, .acquire) != null) return;
        while (self.word.load(.acquire) == parked and !stopping.load(.acquire)) std.Thread.yield() catch {
            // Yielding is only courtesy while spinning; failing to yield still spins correctly.
        };
        self.word.store(disarmed, .release);
    }
};

/// A single-producer, single-consumer byte ring: the read thread appends, the owner drains.
///
/// Lock-free, so neither thread can block inside the allocator, and fixed-size, so the read thread
/// never allocates at all. Counters are monotonic rather than indices, so the number of bytes held
/// is a subtraction and no wrap-around bookkeeping is needed.
const ByteRing = struct {
    buffer: []u8,
    written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    taken: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn create(gpa: Allocator, capacity: usize) Allocator.Error!ByteRing {
        return .{ .buffer = try gpa.alloc(u8, capacity) };
    }

    fn destroy(self: *ByteRing, gpa: Allocator) void {
        gpa.free(self.buffer);
        self.* = undefined;
    }

    /// Bytes waiting for the owner. Either thread may ask; the answer only has to be close enough
    /// to decide whether to sleep.
    fn len(self: *const ByteRing) usize {
        return @intCast(self.written.load(.acquire) - self.taken.load(.monotonic));
    }

    /// Append as much of `bytes` as fits, and report how much that was. Producer side only.
    fn append(self: *ByteRing, bytes: []const u8) usize {
        const written = self.written.load(.monotonic);
        const room = self.buffer.len - @as(usize, @intCast(written - self.taken.load(.acquire)));
        const count = @min(bytes.len, room);
        if (count == 0) return 0;

        const capacity = self.buffer.len;
        const start: usize = @intCast(written % @as(u64, @intCast(capacity)));
        const first = @min(count, capacity - start);
        @memcpy(self.buffer[start..][0..first], bytes[0..first]);
        if (count > first) @memcpy(self.buffer[0 .. count - first], bytes[first..count]);

        self.written.store(written + count, .release);
        return count;
    }

    /// Copy out up to `dest.len` bytes and report how many. Consumer side only.
    fn take(self: *ByteRing, dest: []u8) usize {
        const taken = self.taken.load(.monotonic);
        const count = @min(dest.len, @as(usize, @intCast(self.written.load(.acquire) - taken)));
        if (count == 0) return 0;

        const capacity = self.buffer.len;
        const start: usize = @intCast(taken % @as(u64, @intCast(capacity)));
        const first = @min(count, capacity - start);
        @memcpy(dest[0..first], self.buffer[start..][0..first]);
        if (count > first) @memcpy(dest[first..count], self.buffer[0 .. count - first]);

        self.taken.store(taken + count, .release);
        return count;
    }
};

/// How a child ended, as one atomic word, so publishing it and reading it need no lock.
const EndWord = packed struct(u64) {
    const running: EndWord = .{ .kind = .running, .value = 0 };
    const unknown: EndWord = .{ .kind = .unknown, .value = 0 };

    kind: enum(u3) { running, code, signal, unknown },
    value: u61,

    fn fromStatus(raw: u32) EndWord {
        return switch (decodeExitStatus(raw)) {
            .code => |code| .{ .kind = .code, .value = code },
            .signal => |signal| .{ .kind = .signal, .value = @intFromEnum(signal) },
            .unknown => .unknown,
        };
    }

    /// A child's end as Windows reports it: a number, never a signal. Windows has no wait status
    /// to decode, so the code goes in as it stands rather than through `decodeExitStatus`, which
    /// would read a POSIX wait status that was never produced.
    fn fromExitCode(code: u32) EndWord {
        return .{ .kind = .code, .value = code };
    }

    fn toChildState(self: EndWord) ChildState {
        return switch (self.kind) {
            .running => .running,
            .code => .{ .exited = .{ .code = @intCast(self.value) } },
            .signal => .{ .exited = .{ .signal = @enumFromInt(self.value) } },
            .unknown => .{ .exited = .unknown },
        };
    }
};

/// Decode a POSIX wait status. The encoding is fixed by POSIX, so this one decoder serves every
/// POSIX backend: bits 0-6 are the signal, `0x7f` alone means stopped, and otherwise bits 8-15 are
/// the exit code.
fn decodeExitStatus(raw: u32) ExitStatus {
    const low = raw & 0xff;
    if (low == 0) return .{ .code = (raw >> 8) & 0xff };
    if (low == 0x7f) return .unknown; // stopped; Conduit never asks to be told about this
    return switch (low & 0x7f) {
        1 => .{ .signal = .hangup }, // SIGHUP
        2 => .{ .signal = .interrupt }, // SIGINT
        9 => .{ .signal = .kill }, // SIGKILL
        15 => .{ .signal = .terminate }, // SIGTERM
        else => .unknown,
    };
}

/// Everything a forked child needs from `execve`, built before the fork so that the child itself
/// only ever makes syscalls.
const Prepared = struct {
    program: [:0]const u8,
    argv: []?[*:0]const u8,
    envp: []?[*:0]const u8,
    cwd: [:0]const u8,
    /// Every copied string, and every pointer vector, so deinit frees exactly what init allocated.
    strings: std.ArrayList([]u8),
    vectors: std.ArrayList([]?[*:0]const u8),

    fn init(gpa: Allocator, request: SpawnRequest) !Prepared {
        var prepared: Prepared = .{
            .program = undefined,
            .argv = undefined,
            .envp = undefined,
            .cwd = undefined,
            .strings = .empty,
            .vectors = .empty,
        };
        errdefer prepared.deinit(gpa);

        const resolved = try resolveProgram(gpa, request.argv[0], envValue(request.env, "PATH"));
        defer gpa.free(resolved);
        prepared.program = try prepared.copy(gpa, resolved);
        prepared.argv = try prepared.vector(gpa, request.argv);
        prepared.envp = try prepared.vector(gpa, request.env);
        prepared.cwd = if (request.cwd.len == 0) "" else try prepared.copy(gpa, request.cwd);
        return prepared;
    }

    fn deinit(self: *Prepared, gpa: Allocator) void {
        for (self.strings.items) |bytes| gpa.free(bytes);
        self.strings.deinit(gpa);
        for (self.vectors.items) |pointers| gpa.free(pointers);
        self.vectors.deinit(gpa);
    }

    /// Copy a string, keeping the whole allocation. `deinit` frees what was allocated, so the slice
    /// that gets freed has to be the whole one: freeing only the text would hand the allocator a
    /// size it never gave out.
    fn copy(self: *Prepared, gpa: Allocator, bytes: []const u8) Allocator.Error![:0]const u8 {
        const owned = try duplicate(gpa, bytes);
        errdefer gpa.free(owned);
        try self.strings.append(gpa, owned);
        return owned[0..bytes.len :0];
    }

    fn vector(self: *Prepared, gpa: Allocator, items: []const []const u8) ![]?[*:0]const u8 {
        const pointers = try gpa.alloc(?[*:0]const u8, items.len + 1);
        errdefer gpa.free(pointers);
        for (items, 0..) |item, index| pointers[index] = (try self.copy(gpa, item)).ptr;
        pointers[items.len] = null;
        try self.vectors.append(gpa, pointers);
        return pointers;
    }
};

/// The value of `KEY` in a `KEY=VALUE` list, or null when the list does not carry it.
fn envValue(env: []const []const u8, key: []const u8) ?[]const u8 {
    for (env) |entry| {
        const split = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (!std.mem.eql(u8, entry[0..split], key)) continue;
        return entry[split + 1 ..];
    }
    return null;
}

/// POSIX's minimum maximum path length. Used to build a candidate path without allocating, on the
/// stack, in a function that must not.
const path_max = 4096;

/// Find the program `argv[0]` names: as given when it is already a path, otherwise on `PATH`.
///
/// This runs in the parent, before the fork, so a program that does not exist is an error the
/// caller sees instead of a child that dies at status 127 with nothing to explain it. The search
/// uses the *child's* PATH rather than Conduit's own, because the environment a workspace was given
/// is the environment its shell runs in (P7).
fn resolveProgram(gpa: Allocator, program: []const u8, path_value: ?[]const u8) Error![]u8 {
    if (std.mem.indexOfScalar(u8, program, '/') != null) return duplicate(gpa, program);

    var buffer: [path_max]u8 = undefined;
    var directories = std.mem.splitScalar(u8, path_value orelse "", ':');
    while (directories.next()) |directory| {
        // An empty entry means the current directory, as every other PATH search does.
        const root = if (directory.len == 0) "." else directory;
        const candidate = std.fmt.bufPrintZ(&buffer, "{s}/{s}", .{ root, program }) catch
            continue; // too long to be a path: not this one
        if (!sys.isExecutable(candidate)) continue;
        return duplicate(gpa, candidate);
    }
    return error.ProgramNotFound;
}

/// A NUL-terminated copy of `bytes`, returned whole: the caller frees the whole slice, so handing
/// back only the text would free a size the allocator never gave out.
fn duplicate(gpa: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    const owned = try gpa.alloc(u8, bytes.len + 1);
    @memcpy(owned[0..bytes.len], bytes);
    owned[bytes.len] = 0;
    return owned;
}

/// Everything a forked child does, in order, with nothing but syscalls.
///
/// After a fork in a threaded process a child may not allocate, take a lock or call anything that
/// is not async-signal-safe. Every descriptor is close-on-exec, so the only descriptors this has to
/// arrange are the three standard ones; the rest disappear at `execve`.
fn childMain(pair: sys.PtyPair, status: sys.fd_t, prepared: Prepared) noreturn {
    for ([_]sys.fd_t{ 0, 1, 2 }) |target| {
        sys.dup2(pair.slave, target) catch childFail(status, .terminal, null);
    }
    sys.setsid() catch childFail(status, .session, null);
    sys.acquireControllingTerminal(0) catch childFail(status, .terminal, null);
    if (prepared.cwd.len != 0) sys.chdir(prepared.cwd) catch childFail(status, .working_directory, null);
    // A shell may start Conduit as an asynchronous job with terminal signals ignored, and `execve`
    // deliberately preserves ignored dispositions. Restore the child's terminal semantics only
    // after its setup is complete, leaving the smallest possible interval before `execve` in which
    // one of those signals can end the not-yet-executed child.
    sys.resetChildSignalState() catch childFail(status, .signal_state, null);
    // `execve` only returns when it failed, and the parent is waiting to hear why.
    return sys.execve(prepared.program, prepared.argv, prepared.envp) catch
        childFail(status, .exec_failed, null);
}

/// Signals whose inherited state would change how a program attached to a terminal behaves.
///
/// The shell-started-background-job bug is specifically `interrupt`, but the other terminal and
/// lifecycle signals have the same inheritance rule: `execve` resets caught handlers but preserves
/// ignored ones. The child therefore restores and unblocks the complete small set together.
const ChildSignal = enum {
    hangup,
    interrupt,
    quit,
    terminate,
    terminal_stop,
    background_read,
    background_write,
    window_change,
};

const child_signals = [_]ChildSignal{
    .hangup,
    .interrupt,
    .quit,
    .terminate,
    .terminal_stop,
    .background_read,
    .background_write,
    .window_change,
};

/// Failures from the post-fork signal setup. Kept separate from `Error` because this path reports
/// through the child's status pipe rather than returning through Conduit's normal, logging seam.
const ChildSignalError = error{
    SignalDispositionFailed,
    SignalMaskFailed,
};

/// Why a forked child could not become the program the caller asked for.
const ChildFailure = enum(u8) {
    terminal = 1,
    session = 2,
    working_directory = 3,
    exec_failed = 4,
    signal_state = 5,

    fn describe(self: ChildFailure) []const u8 {
        return switch (self) {
            .terminal => "the terminal could not be attached",
            .session => "a new session could not be started",
            .working_directory => "the working directory could not be entered",
            .exec_failed => "the program could not be executed",
            .signal_state => "the child's terminal signal state could not be restored",
        };
    }
};

/// Tell the parent what went wrong, then leave. There is nowhere else to report it: the only
/// thread left in this process is the parent, and it is waiting on exactly this.
fn childFail(status: sys.fd_t, reason: ChildFailure, detail: ?u8) noreturn {
    sys.report(status, &[_]u8{@intFromEnum(reason)});
    if (detail) |errno| sys.report(status, &[_]u8{errno});
    sys.exitProcess(sys.exec_failure_status);
}

fn describeChildFailure(reason: u8) []const u8 {
    const failure: ChildFailure = @enumFromInt(reason);
    return failure.describe();
}

// ---------------------------------------------------------------------------
// The system calls this backend is written against
// ---------------------------------------------------------------------------

/// One function per OS call, each resolved for the target at compile time.
///
/// This is the only part of the file that knows what a file descriptor is. `std.posix` is not used
/// here because its Windows paths are `@compileError` and the interface must still compile where no
/// backend exists yet; Linux is reached through raw syscalls so a Linux build needs no libc, and
/// macOS through libc, which is where its pseudo-terminal calls live.
const sys = struct {
    /// A descriptor, and a process id. Both are `c_int`-shaped here, and nowhere else in the file:
    /// the interface above cannot see either.
    pub const fd_t = i32;
    pub const pid_t = i32;

    /// POSIX `struct pollfd`, which Linux and macOS share.
    pub const pollfd = extern struct {
        fd: fd_t,
        events: i16,
        revents: i16,
    };

    pub const poll_in: i16 = 0x001;
    pub const poll_hup: i16 = 0x010;

    /// POSIX `struct winsize`: four fields, in the order the kernel reads them.
    const winsize = extern struct {
        rows: u16,
        cols: u16,
        x_pixel: u16,
        y_pixel: u16,
    };

    /// The two sides of a pseudo-terminal: the master Conduit holds, the slave the child gets.
    pub const PtyPair = struct { master: fd_t, slave: fd_t };

    /// What a forked child reports when it could not become the program the caller asked for: a
    /// `ChildFailure` code, and for a failed `execve` the errno that explains it.
    pub const ExecFailure = struct { reason: u8, errno: ?u8 };

    /// POSIX fixes these, and both targets agree on them.
    const f_getfd: c_int = 1;
    const f_setfd: c_int = 2;
    const f_setfl: c_int = 4;
    const fd_cloexec: c_int = 1;
    /// `O_NONBLOCK` as darwin's sys/fcntl.h numbers it. Only the macOS branch uses it; Linux's
    /// value (0x800) is a different flag there and would leave the wakeup pipe blocking.
    const o_nonblock: c_int = 0x0004;
    const x_ok: c_int = 1;
    /// `WNOHANG`, which POSIX fixes at 1.
    const w_no_hang: c_int = 1;
    /// The status a child that could not be started exits with.
    const exec_failure_status: u8 = 127;
    /// TIOCSCTTY as darwin's sys/ttycom.h numbers it: _IO('t', 97), where darwin's sys/ioccom.h
    /// has IOC_VOID = 0x20000000, so 0x20007461.
    const tioc_sctty: c_ulong = 0x20007461;
    /// TIOCSWINSZ as darwin's sys/ttycom.h numbers it: _IOW('t', 103, struct winsize), where
    /// IOC_IN = 0x80000000 and the 8-byte size sits in bits 16..28, so 0x80087467. (0x40087467,
    /// with IOC_OUT, is not a darwin request at all and fails with ENOTTY.)
    const tioc_swinwsz: c_ulong = 0x80087467;

    /// How many descriptors `countOpenDescriptors` probes. Conduit opens tens, not thousands.
    const descriptor_probe_limit = 1024;

    /// The libc calls macOS needs that `std.c` does not export. Declared here so they are referenced
    /// only from the macOS branch, which no other target ever analyzes.
    const darwin = struct {
        extern "c" fn posix_openpt(flags: c_int) c_int;
        extern "c" fn grantpt(fd: c_int) c_int;
        extern "c" fn unlockpt(fd: c_int) c_int;
        extern "c" fn ptsname(fd: c_int) [*:0]const u8;
        /// Darwin declares the request `unsigned long`; a `c_int` would sign-extend IOC_IN requests.
        extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    };

    fn unsupported() Error {
        log.warn("no PTY backend on {s}: Conduit on Windows is TASK-16", .{@tagName(builtin.os.tag)});
        return error.UnsupportedPlatform;
    }

    fn failure(context: []const u8, detail: []const u8) Error {
        log.err("{s} failed: {s}", .{ context, detail });
        return error.SystemError;
    }

    /// Report a libc failure with the errno that caused it.
    fn errnoFailure(context: []const u8, call: []const u8) Error {
        if (comptime builtin.os.tag != .macos) return failure(context, "no PTY backend");
        const c = @import("std").c;
        log.err("{s} failed: {s} (errno {d})", .{ context, call, c._errno().* });
        return error.SystemError;
    }

    /// Check a raw syscall result, so a failure is never mistaken for a value.
    fn check(rc: usize, context: []const u8) Error!void {
        if (comptime builtin.os.tag != .linux) return failure(context, "no PTY backend");
        const linux = @import("std").os.linux;
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            else => |errno| return failure(context, @tagName(errno)),
        }
    }

    /// Open a pseudo-terminal pair: the master Conduit reads and writes, the slave the child gets.
    fn openPty() Error!PtyPair {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            const master = open("/dev/ptmx") catch return error.PtyUnavailable;
            errdefer close(master);

            // /dev/ptmx hands out a locked pty; unlocking it is what makes the slave usable.
            var unlocked: i32 = 0;
            check(linux.ioctl(master, linux.IOCTL.IOW('T', 0x31, i32), @intFromPtr(&unlocked)), "unlock the pseudo-terminal") catch
                return error.PtyUnavailable;

            // The slave is named after the pty's number, under /dev/pts.
            var number: u32 = 0;
            check(linux.ioctl(master, linux.IOCTL.IOR('T', 0x30, u32), @intFromPtr(&number)), "read the pseudo-terminal number") catch
                return error.PtyUnavailable;
            var name: [32]u8 = undefined;
            const path = std.fmt.bufPrintZ(&name, "/dev/pts/{d}", .{number}) catch
                return error.PtyUnavailable;

            const slave = open(path) catch return error.PtyUnavailable;
            return .{ .master = master, .slave = slave };
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            // macOS has no /dev/ptmx: the pty multiplexer is reached through libc.
            const flags: c.O = .{ .ACCMODE = .RDWR, .NOCTTY = true };
            const master = darwin.posix_openpt(@bitCast(flags));
            if (master < 0) return errnoFailure("open a pseudo-terminal", "posix_openpt");
            errdefer close(master);
            if (darwin.grantpt(master) < 0) return errnoFailure("grant the pseudo-terminal", "grantpt");
            if (darwin.unlockpt(master) < 0) return errnoFailure("unlock the pseudo-terminal", "unlockpt");
            const name = darwin.ptsname(master);
            const slave = open(name[0..std.mem.len(name) :0]) catch return error.PtyUnavailable;
            return .{ .master = master, .slave = slave };
        } else {
            return unsupported();
        }
    }

    /// Open a path for reading and writing, never as the controlling terminal, and close-on-exec so
    /// no descriptor Conduit holds is inherited by anything it starts.
    fn open(path: [:0]const u8) Error!fd_t {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            const flags: linux.O = .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true };
            const rc = linux.open(path.ptr, flags, 0);
            try check(rc, "open a pseudo-terminal side");
            return @intCast(rc);
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            const fd = c.open(path.ptr, c.O{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, @as(c_uint, 0));
            if (fd < 0) return errnoFailure("open a pseudo-terminal side", "open");
            return fd;
        } else {
            return unsupported();
        }
    }

    /// Close a descriptor. Errors are not worth reporting: a descriptor Conduit is closing on the
    /// way out has nothing left to do.
    fn close(fd: fd_t) void {
        if (comptime builtin.os.tag == .linux) {
            _ = @import("std").os.linux.close(fd);
        } else if (comptime builtin.os.tag == .macos) {
            _ = @import("std").c.close(fd);
        }
    }

    /// Tell the OS how large the terminal is.
    ///
    /// The master is the right descriptor: this is where a resize arrives from, and it is what the
    /// OS turns into a `SIGWINCH` for whatever is in the terminal's foreground process group.
    fn setWindowSize(fd: fd_t, size: WindowSize) Error!void {
        const value: winsize = .{
            .rows = size.rows,
            .cols = size.cols,
            .x_pixel = 0,
            .y_pixel = 0,
        };
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            // TIOCSWINSZ, as linux's own uapi header numbers it: _IO('T', 20).
            try check(linux.ioctl(fd, linux.IOCTL.IO('T', 20), @intFromPtr(&value)), "resize the terminal");
        } else if (comptime builtin.os.tag == .macos) {
            if (darwin.ioctl(fd, tioc_swinwsz, &value) < 0) {
                return errnoFailure("resize the terminal", "ioctl(TIOCSWINSZ)");
            }
        } else {
            return unsupported();
        }
    }

    /// Make this descriptor the process's controlling terminal. Only the child calls this, straight
    /// after it has started a session of its own.
    fn acquireControllingTerminal(fd: fd_t) Error!void {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            // TIOCSCTTY, as linux's own uapi header numbers it: _IO('T', 14).
            try check(linux.ioctl(fd, linux.IOCTL.IO('T', 14), 0), "attach the controlling terminal");
        } else if (comptime builtin.os.tag == .macos) {
            // TIOCSCTTY, from darwin's sys/ttycom.h: _IO('t', 97).
            if (darwin.ioctl(fd, tioc_sctty, @as(?*anyopaque, null)) < 0) {
                return errnoFailure("attach the controlling terminal", "ioctl(TIOCSCTTY)");
            }
        } else {
            return unsupported();
        }
    }

    /// Read from a descriptor. `error.Closed` means the far end hung up: on Linux a pty master
    /// whose last slave has gone reports that as `EIO` rather than as end-of-file.
    fn read(fd: fd_t, buffer: []u8) Error!usize {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            while (true) {
                const rc = linux.read(fd, buffer.ptr, buffer.len);
                switch (linux.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    .IO => return error.Closed,
                    else => |errno| return failure("read from the terminal", @tagName(errno)),
                }
            }
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            while (true) {
                const rc = c.read(fd, buffer.ptr, buffer.len);
                switch (c.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    else => |errno| return failure("read from the terminal", @tagName(errno)),
                }
            }
        } else {
            return unsupported();
        }
    }

    /// Read what is already there, without waiting. `null` means nothing was waiting.
    fn readAvailable(fd: fd_t, buffer: []u8) Error!?usize {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            while (true) {
                const rc = linux.read(fd, buffer.ptr, buffer.len);
                switch (linux.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    .AGAIN => return null,
                    else => |errno| return failure("drain the wakeup pipe", @tagName(errno)),
                }
            }
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            while (true) {
                const rc = c.read(fd, buffer.ptr, buffer.len);
                switch (c.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    .AGAIN => return null,
                    else => |errno| return failure("drain the wakeup pipe", @tagName(errno)),
                }
            }
        } else {
            return unsupported();
        }
    }

    /// Write bytes to a descriptor. `error.Closed` means the reader is gone.
    fn write(fd: fd_t, bytes: []const u8) Error!usize {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            while (true) {
                const rc = linux.write(fd, bytes.ptr, bytes.len);
                switch (linux.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    .PIPE, .IO => return error.Closed,
                    else => |errno| return failure("write to the terminal", @tagName(errno)),
                }
            }
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            while (true) {
                const rc = c.write(fd, bytes.ptr, bytes.len);
                switch (c.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    .PIPE, .IO => return error.Closed,
                    else => |errno| return failure("write to the terminal", @tagName(errno)),
                }
            }
        } else {
            return unsupported();
        }
    }

    /// A close-on-exec pipe that blocks: the read end waits for a child to become its program, or
    /// for that child to say it cannot.
    fn pipe() Error![2]fd_t {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            var fds: [2]fd_t = undefined;
            try check(linux.pipe2(&fds, .{ .CLOEXEC = true }), "create a pipe");
            return fds;
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            var fds: [2]fd_t = undefined;
            if (c.pipe(&fds) < 0) return errnoFailure("create a pipe", "pipe");
            setCloseOnExec(fds[0]);
            setCloseOnExec(fds[1]);
            return fds;
        } else {
            return unsupported();
        }
    }

    /// A close-on-exec pipe that never blocks: the read thread and the owner both wait on it, so a
    /// read that finds nothing must return rather than sleep.
    fn wakePipe() Error![2]fd_t {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            var fds: [2]fd_t = undefined;
            try check(linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true }), "create the wakeup pipe");
            return fds;
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            var fds: [2]fd_t = undefined;
            if (c.pipe(&fds) < 0) return errnoFailure("create the wakeup pipe", "pipe");
            setCloseOnExec(fds[0]);
            setCloseOnExec(fds[1]);
            setNonBlocking(fds[0]);
            setNonBlocking(fds[1]);
            return fds;
        } else {
            return unsupported();
        }
    }

    fn setCloseOnExec(fd: fd_t) void {
        if (comptime builtin.os.tag != .macos) return;
        const c = @import("std").c;
        _ = c.fcntl(fd, f_setfd, fd_cloexec);
    }

    fn setNonBlocking(fd: fd_t) void {
        if (comptime builtin.os.tag != .macos) return;
        const c = @import("std").c;
        _ = c.fcntl(fd, f_setfl, o_nonblock);
    }

    /// Wait until one of `fds` reports an event, or `timeout_ms` milliseconds pass. A negative
    /// timeout waits indefinitely. The caller reads `revents`; an interrupted wait is not a failure,
    /// because the caller checks its own condition and waits again.
    fn poll(fds: []pollfd, timeout_ms: i32) Error!void {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            const rc = linux.poll(@ptrCast(fds.ptr), fds.len, timeout_ms);
            switch (linux.errno(rc)) {
                .SUCCESS, .INTR => return,
                else => |errno| return failure("wait for the terminal", @tagName(errno)),
            }
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            const rc = c.poll(@ptrCast(fds.ptr), @intCast(fds.len), timeout_ms);
            switch (c.errno(rc)) {
                .SUCCESS, .INTR => return,
                else => |errno| return failure("wait for the terminal", @tagName(errno)),
            }
        } else {
            return unsupported();
        }
    }

    /// `poll` for one descriptor.
    fn pollOne(fd: fd_t, timeout_ms: i32) Error!void {
        var fds = [_]pollfd{.{ .fd = fd, .events = poll_in, .revents = 0 }};
        return poll(&fds, timeout_ms);
    }

    /// Wake whoever is waiting on the other end of a wake pipe.
    ///
    /// A byte here is a hint, never the fact: the woken thread re-checks what it was waiting for,
    /// so a pipe that is already full — and therefore already readable — costs nothing.
    fn notify(fd: fd_t) void {
        const byte = [_]u8{1};
        _ = write(fd, &byte) catch {
            // A full wake pipe is already readable, and a wake pipe that is gone belongs to a
            // terminal being destroyed. Either way there is nothing to wake.
        };
    }

    /// Write without caring whether it worked. Only a forked child uses this: there is no thread
    /// left in that process to report an error to.
    fn report(fd: fd_t, bytes: []const u8) void {
        if (comptime builtin.os.tag == .linux) {
            _ = @import("std").os.linux.write(fd, bytes.ptr, bytes.len);
        } else if (comptime builtin.os.tag == .macos) {
            _ = @import("std").c.write(fd, bytes.ptr, bytes.len);
        }
    }

    fn dup2(old: fd_t, new: fd_t) Error!void {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            try check(linux.dup2(old, new), "attach the terminal to a standard stream");
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            if (c.dup2(old, new) < 0) return errnoFailure("attach the terminal to a standard stream", "dup2");
        } else {
            return unsupported();
        }
    }

    /// Start a child. Returns `0` in the child, which must then only make syscalls.
    fn fork() Error!pid_t {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            const rc = linux.fork();
            try check(rc, "fork");
            return @intCast(rc);
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            const rc = c.fork();
            if (rc < 0) return errnoFailure("fork", "fork");
            return rc;
        } else {
            return unsupported();
        }
    }

    fn setsid() Error!void {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            try check(linux.setsid(), "start the child's session");
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            if (c.setsid() < 0) return errnoFailure("start the child's session", "setsid");
        } else {
            return unsupported();
        }
    }

    fn chdir(path: [:0]const u8) Error!void {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            try check(linux.chdir(path.ptr), "enter the child's working directory");
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            if (c.chdir(path.ptr) < 0) return errnoFailure("enter the child's working directory", "chdir");
        } else {
            return unsupported();
        }
    }

    /// Give a terminal child normal signal semantics before it becomes the requested program.
    ///
    /// Only async-signal-safe operations are used: raw Linux signal syscalls, or POSIX
    /// `sigemptyset`, `sigaddset`, `sigaction` and `sigprocmask` on macOS. This function runs after
    /// `fork` in a process that was already threaded, so it must never allocate, log or take a lock.
    fn resetChildSignalState() ChildSignalError!void {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            const action = linux.Sigaction{
                .handler = .{ .handler = linux.SIG.DFL },
                .mask = linux.sigemptyset(),
                .flags = 0,
            };
            var unblocked = linux.sigemptyset();
            for (child_signals) |kind| {
                const signal_number = linuxChildSignal(kind);
                if (linux.errno(linux.sigaction(signal_number, &action, null)) != .SUCCESS) {
                    return error.SignalDispositionFailed;
                }
                linux.sigaddset(&unblocked, signal_number);
            }
            if (linux.errno(linux.sigprocmask(linux.SIG.UNBLOCK, &unblocked, null)) != .SUCCESS) {
                return error.SignalMaskFailed;
            }
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            var empty: c.sigset_t = undefined;
            if (c.sigemptyset(&empty) != 0) return error.SignalDispositionFailed;
            const action = c.Sigaction{
                .handler = .{ .handler = c.SIG.DFL },
                .mask = empty,
                .flags = 0,
            };
            var unblocked = empty;
            for (child_signals) |kind| {
                const signal_number = darwinChildSignal(kind);
                if (c.sigaction(signal_number, &action, null) != 0) return error.SignalDispositionFailed;
                if (c.sigaddset(&unblocked, signal_number) != 0) return error.SignalMaskFailed;
            }
            if (c.sigprocmask(c.SIG.UNBLOCK, &unblocked, null) != 0) {
                return error.SignalMaskFailed;
            }
        } else {
            return error.SignalDispositionFailed;
        }
    }

    fn linuxChildSignal(kind: ChildSignal) @import("std").os.linux.SIG {
        const linux = @import("std").os.linux;
        return switch (kind) {
            .hangup => linux.SIG.HUP,
            .interrupt => linux.SIG.INT,
            .quit => linux.SIG.QUIT,
            .terminate => linux.SIG.TERM,
            .terminal_stop => linux.SIG.TSTP,
            .background_read => linux.SIG.TTIN,
            .background_write => linux.SIG.TTOU,
            .window_change => linux.SIG.WINCH,
        };
    }

    fn darwinChildSignal(kind: ChildSignal) @import("std").c.SIG {
        const c = @import("std").c;
        return switch (kind) {
            .hangup => c.SIG.HUP,
            .interrupt => c.SIG.INT,
            .quit => c.SIG.QUIT,
            .terminate => c.SIG.TERM,
            .terminal_stop => c.SIG.TSTP,
            .background_read => c.SIG.TTIN,
            .background_write => c.SIG.TTOU,
            .window_change => c.SIG.WINCH,
        };
    }

    /// Replace this process with a program. Returns only when that failed.
    fn execve(
        path: [:0]const u8,
        argv: []const ?[*:0]const u8,
        envp: []const ?[*:0]const u8,
    ) error{ExecFailed}!noreturn {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            const rc = linux.execve(path.ptr, @ptrCast(argv.ptr), @ptrCast(envp.ptr));
            log.err("cannot execute {s}: {s}", .{ path, @tagName(linux.errno(rc)) });
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            if (c.execve(path.ptr, @ptrCast(argv.ptr), @ptrCast(envp.ptr)) < 0) {
                log.err("cannot execute {s}: {s}", .{ path, @tagName(c.errno(-1)) });
            }
        }
        return error.ExecFailed;
    }

    /// Leave, without unwinding anything: a forked child has no stack to unwind and no buffers to
    /// flush, and flushing them would write this process's output twice.
    fn exitProcess(code: u8) noreturn {
        if (comptime builtin.os.tag == .linux) {
            @import("std").os.linux.exit_group(code);
        } else if (comptime builtin.os.tag == .macos) {
            @import("std").c._exit(code);
        }
        std.process.exit(code);
    }

    /// Collect a child. `null` means it has not ended yet, which only `no_hang` can report.
    fn waitpid(pid: pid_t, no_hang: bool) Error!?u32 {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            var status: u32 = 0;
            const rc = linux.waitpid(pid, &status, if (no_hang) linux.W.NOHANG else 0);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                // The child is not this process's to wait for: somebody else already collected it.
                .CHILD => return error.Closed,
                else => |errno| return failure("wait for the child", @tagName(errno)),
            }
            const reaped: isize = @bitCast(rc);
            if (reaped == 0) return null;
            return status;
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            var status: c_int = 0;
            const rc = c.waitpid(pid, &status, if (no_hang) w_no_hang else 0);
            if (rc < 0) {
                if (c.errno(-1) == .INTR) return waitpid(pid, no_hang);
                return errnoFailure("wait for the child", "waitpid");
            }
            if (rc == 0) return null;
            return @bitCast(status);
        } else {
            return unsupported();
        }
    }

    /// Send a signal. POSIX fixes the numbers, so both targets agree on them.
    fn signal(pid: pid_t, which: Signal) Error!void {
        const number: u8 = switch (which) {
            .hangup => 1, // SIGHUP
            .interrupt => 2, // SIGINT
            .terminate => 15, // SIGTERM
            .kill => 9, // SIGKILL
        };
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            try check(linux.kill(pid, @enumFromInt(number)), "signal the child");
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            const sig: c.SIG = @enumFromInt(number);
            if (c.kill(pid, sig) < 0) return errnoFailure("signal the child", "kill");
        } else {
            return unsupported();
        }
    }

    /// Whether a path names something this process may execute.
    fn isExecutable(path: [:0]const u8) bool {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            return linux.errno(linux.access(path.ptr, x_ok)) == .SUCCESS;
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            return c.access(path.ptr, x_ok) == 0;
        } else {
            return false;
        }
    }

    /// Wait for a forked child to say whether it became the program, or for it to become that
    /// program — which closes the write end and ends the read. `null` means it became the program.
    ///
    /// This blocks, but only for as long as one `execve` takes: the read ends at the same instant
    /// the child stops being the fork.
    fn readExecStatus(fd: fd_t) ?ExecFailure {
        var buffer: [2]u8 = undefined;
        const count = read(fd, &buffer) catch return null;
        if (count == 0) return null; // The write end closed: the program is running.
        return .{
            .reason = buffer[0],
            .errno = if (count > 1) buffer[1] else null,
        };
    }

    /// Milliseconds from a monotonic clock. Only differences are ever taken, so the origin does not
    /// matter; a clock that jumped backwards would only make a wait end sooner than asked.
    fn monotonicMillis() u64 {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            var ts: linux.timespec = undefined;
            if (linux.errno(linux.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return 0;
            return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s +
                @as(u64, @intCast(@divTrunc(ts.nsec, std.time.ns_per_ms)));
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            var ts: c.timespec = undefined;
            if (c.clock_gettime(c.CLOCK.MONOTONIC_RAW, &ts) != 0) return 0;
            return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s +
                @as(u64, @intCast(@divTrunc(ts.nsec, std.time.ns_per_ms)));
        } else {
            return 0;
        }
    }

    /// Count the descriptors this process holds, by asking the OS about every one it could have.
    /// This is how the descriptor-leak test measures rather than assumes.
    fn countOpenDescriptors() Error!usize {
        var count: usize = 0;
        var fd: fd_t = 0;
        while (fd < descriptor_probe_limit) : (fd += 1) {
            if (isOpen(fd)) count += 1;
        }
        return count;
    }

    fn isOpen(fd: fd_t) bool {
        if (comptime builtin.os.tag == .linux) {
            const linux = @import("std").os.linux;
            return linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)) == .SUCCESS;
        } else if (comptime builtin.os.tag == .macos) {
            const c = @import("std").c;
            return c.fcntl(fd, f_getfd, @as(c_int, 0)) >= 0;
        } else {
            return false;
        }
    }
};
// ---------------------------------------------------------------------------
// The Windows ConPTY backend
// ---------------------------------------------------------------------------

/// The clock both backends' waits are measured on, in milliseconds from an arbitrary origin.
///
/// Only differences are ever taken, so the origin does not matter. POSIX reads its own monotonic
/// clock; Windows has no equivalent it exposes as a call this file makes, so it uses
/// `GetTickCount64`, which counts up since boot and cannot be set backwards.
fn monotonicMillis() u64 {
    if (comptime builtin.os.tag == .windows) return win.monotonicMillis();
    return sys.monotonicMillis();
}

/// Start a terminal on Windows: one child process attached to a pseudoconsole.
///
/// Ownership transfers to the returned `Pty` exactly as `spawnPosix` does: the caller keeps
/// nothing but its copy of `request`, and `destroy` joins the read thread, closes the
/// pseudoconsole and every handle, and frees the handle. Nothing is allocated once this returns.
///
/// The thread contract is the POSIX backend's, unchanged: one read thread owns the only blocking
/// read and the only observation of the child's end, bytes cross through the same fixed-size ring,
/// the child's end is published as one atomic word rather than handed to a caller, and the owner
/// thread's `write` is the only thing that touches the input side.
pub fn spawnConPty(gpa: Allocator, request: SpawnRequest) Error!Pty {
    try validate(request);

    // Everything `CreateProcessW` needs, built before the child exists. Windows has no fork step
    // that reports a failure afterwards: the program either starts or the call fails on the spot,
    // so a program that cannot be run is an error the caller sees rather than a child that dies at
    // status 127 with nothing to explain it.
    var prepared = try WindowsRequest.init(gpa, request);
    defer prepared.deinit(gpa);

    // The pseudoconsole reads the input pipe Conduit writes and writes the output pipe Conduit
    // reads. Only the output side is overlapped: a blocking read on it has to be something the
    // read thread can be woken out of, and an OVERLAPPED is the only such read Windows has, which
    // is also why it is a named pipe (an anonymous pipe is never opened for overlapped IO). A
    // write to the input side is bounded by the terminal's own input buffer, exactly as a write to
    // a POSIX pty master is, so it needs no completion to wait for.
    var output = try win.createOutputPipe();
    errdefer output.close();
    var input = try win.createInputPipe();
    errdefer input.close();

    var console = try win.createPseudoConsole(request.size, input.conpty, output.conpty);
    errdefer win.closePseudoConsole(console);
    // The pseudoconsole holds its own duplicates of its two ends now. Conduit's copies go at
    // once: a held copy of the output pipe's write end is a writer that never leaves, so the
    // pipe could never break when the pseudoconsole exits and the final drain would never end.
    input.closeConPtyEnd();
    output.closeConPtyEnd();

    var child = try win.createProcess(gpa, prepared, console);
    errdefer child.close();

    // Everything from here on is owned by the terminal, so that one place releases it: whether the
    // terminal is destroyed after a thousand frames or abandoned because a spawn failed, it holds
    // the same set and `releaseHandles` closes it the same way.
    const pty = gpa.create(ConPty) catch |err| return err;
    var live = false;
    defer if (!live) {
        releaseHandles(pty);
        gpa.destroy(pty);
    };
    pty.* = .{
        .gpa = gpa,
        .input = invalid_handle,
        .output = invalid_handle,
        .console = null,
        .child = invalid_handle,
        .read_done = invalid_handle,
        .space = invalid_handle,
        .owner_wake = invalid_handle,
        .stop = invalid_handle,
        .reader = null,
        .watcher = null,
        .console_lock = .{},
        .queue = undefined,
        .stopping = .init(false),
        .end = .init(EndWord.running),
    };

    // Ownership moves into the terminal one handle at a time, and a released handle is left as
    // `INVALID_HANDLE_VALUE`, so the `errdefer` above has nothing left to close once it is here.
    pty.input = input.conduit;
    input.conduit = invalid_handle;
    pty.output = output.conduit;
    output.conduit = invalid_handle;
    pty.console = console;
    console = null;
    pty.child = child.handle;
    child.handle = invalid_handle;

    // The handles this terminal waits on: one completion for the read, one for the owner's "there
    // is room", one for the owner's "there is something for you", and one for the owner's "stop".
    // Only `destroy` sets the last, and a manual-reset event is what lets it stay set.
    pty.read_done = try win.createEvent(.manual);
    pty.space = try win.createEvent(.automatic);
    pty.owner_wake = try win.createEvent(.automatic);
    pty.stop = try win.createEvent(.manual);

    var queue = ByteRing.create(gpa, ConPty.queue_capacity) catch |err| return err;
    var queue_live = true;
    defer if (queue_live) queue.destroy(gpa);
    pty.queue = queue;

    pty.reader = std.Thread.spawn(.{}, ConPty.readThread, .{pty}) catch |err| {
        log.err("cannot start the read thread: {s}", .{@errorName(err)});
        pty.abandonChild();
        return error.SpawnFailed;
    };
    pty.watcher = std.Thread.spawn(.{}, ConPty.watchThread, .{pty}) catch |err| {
        log.err("cannot start the exit watcher: {s}", .{@errorName(err)});
        pty.abandonChild();
        pty.stopping.store(true, .release);
        _ = win.setEvent(pty.stop);
        if (pty.reader) |thread| thread.join();
        pty.reader = null;
        return error.SpawnFailed;
    };

    queue_live = false;
    live = true;
    log.debug("terminal started: pid {d}, {d}x{d}", .{
        child.pid,
        request.size.rows,
        request.size.cols,
    });
    return .{ .ptr = pty, .vtable = &ConPty.vtable };
}

/// Close the pseudoconsole and every handle a Windows terminal holds, exactly once.
///
/// One place knows what a terminal holds, so a terminal torn down on a failed spawn and a terminal
/// destroyed after a session ends cannot drift apart. Each handle is invalidated as it is closed,
/// which is what makes a second call harmless rather than a double close of a handle the OS may
/// already have given to somebody else.
fn releaseHandles(self: *ConPty) void {
    // Conduit's end of the output pipe goes first. Before Windows 11 24H2 `ClosePseudoConsole`
    // waits until the pseudoconsole has exited, and a pseudoconsole still writing its last frame
    // into a pipe nobody reads never does; with the pipe broken that write fails at once instead.
    win.closeHandle(self.output);
    win.closeHandle(self.input);
    win.closePseudoConsole(self.console);
    win.closeHandle(self.child);
    win.closeHandle(self.read_done);
    win.closeHandle(self.space);
    win.closeHandle(self.owner_wake);
    win.closeHandle(self.stop);
    self.console = null;
    self.child = invalid_handle;
    self.input = invalid_handle;
    self.output = invalid_handle;
    self.read_done = invalid_handle;
    self.space = invalid_handle;
    self.owner_wake = invalid_handle;
    self.stop = invalid_handle;
}

/// One live terminal on Windows: a pseudoconsole, a child, four events, a byte ring, a read thread
/// and an exit watcher.
const ConPty = struct {
    /// Bytes the read thread may hold for the owner. A full ring stops the reader, which lets the
    /// pseudoconsole's output fill and the child block — the same backpressure, from the same
    /// numbers, as the POSIX backend's ring.
    const queue_capacity = 64 * 1024;

    /// How long the read thread waits between looks at a child that has not ended. Short, so a stop
    /// request is answered; long enough to cost nothing.
    const reap_interval_ms = 20;

    /// How long the read thread keeps reading a terminal whose child has ended without hearing
    /// anything. Closing the pseudoconsole is what normally ends the read, by breaking the pipe
    /// once the pseudoconsole has written its last frame; this only bounds a pseudoconsole that
    /// is kept alive by a process Conduit did not start, so a session's end cannot be held open.
    const final_quiet_ms = 2_000;

    gpa: Allocator,
    /// The end Conduit writes into the pseudoconsole.
    input: win.HANDLE,
    /// The end the pseudoconsole writes its terminal output into.
    output: win.HANDLE,
    /// The pseudoconsole. Only `releaseHandles` closes it, so it is closed exactly once.
    console: win.HPCON,
    /// The child's process object. The read thread is the only thread that waits on it, so it is
    /// the only one that can observe the exit code, and `kill` never reaches a process whose end
    /// has already been published.
    child: win.HANDLE,
    /// Signalled when the output read completes. Manual-reset, because a completion that arrives
    /// between one wait and the next must not be lost.
    read_done: win.HANDLE,
    /// The owner signalling that it has made room in the ring. Automatic, so one signal is one
    /// wakeup rather than a latch that has to be cleared.
    space: win.HANDLE,
    /// The read thread signalling that bytes or an end are waiting for the owner.
    owner_wake: win.HANDLE,
    /// Set once, by `destroy`, to stop the read thread wherever it is waiting.
    stop: win.HANDLE,
    reader: ?std.Thread,
    /// Waits for the child to end and then closes the pseudoconsole, which is what makes the
    /// pseudoconsole flush its last frame and break the output pipe. It is a thread of its own
    /// because the read thread must keep draining while the close runs: before Windows 11 24H2
    /// `ClosePseudoConsole` waits for the pseudoconsole to exit, and Microsoft documents that it
    /// must not be called on the thread reading the output.
    watcher: ?std.Thread,
    /// Guards `console` between the owner's resize and the watcher's close, so a resize never
    /// reaches a pseudoconsole that has been closed under it.
    console_lock: win.SrwLock,
    queue: ByteRing,
    stopping: std.atomic.Value(bool),
    /// The child's end. Written once, by the read thread, and read by everybody.
    end: std.atomic.Value(EndWord),

    const vtable: Pty.VTable = .{
        .write = conWrite,
        .resize = conResize,
        .kill = conKill,
        .takeBytes = conTakeBytes,
        .state = conState,
        .waitReadable = conWaitReadable,
        .destroy = conDestroy,
    };

    /// The body of the read thread, and the only place a terminal blocks on IO.
    fn readThread(self: *ConPty) void {
        var buffer: [4096]u8 = undefined;
        // The OVERLAPPED belongs to this thread for as long as a read is in flight, which is why it
        // is on this thread's stack and why no read is outstanding when this returns.
        var overlapped: win.Overlapped = std.mem.zeroes(win.Overlapped);
        overlapped.event = self.read_done;
        self.pump(&buffer, &overlapped);
        self.publishEnd();
    }

    /// The body of the exit watcher: once the child has ended, close the pseudoconsole so its last
    /// frame is flushed and the output pipe breaks, which is what ends the read thread's drain.
    fn watchThread(self: *ConPty) void {
        var handles = [2]win.HANDLE{ self.child, self.stop };
        if (win.waitOn(&handles, null) != 0) return;
        log.warn("DIAG watcher: child ended, closing the pseudoconsole", .{});
        self.closeConsole();
    }

    /// Close the pseudoconsole once, under the lock the owner's resize takes.
    fn closeConsole(self: *ConPty) void {
        win.acquireLock(&self.console_lock);
        defer win.releaseLock(&self.console_lock);
        win.closePseudoConsole(self.console);
        self.console = null;
    }

    /// End the child of a terminal whose spawn failed after the child started. Closing a process
    /// handle does not end a process, so a failed spawn ends it here and the caller's `defer`
    /// releases the handles afterwards.
    fn abandonChild(self: *ConPty) void {
        if (!win.terminateProcess(self.child, terminationCode(.kill))) {
            log.warn("cannot end the child of a terminal that never started: {s}", .{
                @tagName(win.lastError()),
            });
        }
    }

    /// What one read of the terminal produced.
    const ReadOutcome = enum {
        /// `count` bytes are in `buffer`, and the read is finished with.
        bytes,
        /// The child has ended and nothing was waiting. Output it left behind is still worth
        /// reading, so the read loop goes on in a bounded way rather than stopping here.
        child_ended,
        /// The pseudoconsole hung up, or the terminal has fallen quiet, and no further read is worth
        /// waiting for.
        hung_up,
        /// The owner is destroying this terminal.
        stopping,
    };

    /// Read until the pseudoconsole hangs up or the owner asks to stop.
    fn pump(self: *ConPty, buffer: []u8, overlapped: *win.Overlapped) void {
        // Once the child has been seen to end, every wait is bounded rather than open. The
        // pseudoconsole may still be holding what that child wrote, and a terminal that drops the
        // last line a program printed is a terminal that lies about what happened; so it is read
        // until the terminal falls quiet for one step. A pipe the pseudoconsole never closes can
        // therefore never hold the end of a session, which is what the child's own place in the
        // wait set below is for.
        var child_ended = false;
        while (!self.stopping.load(.acquire)) {
            // Wait for room before asking for more: a terminal the owner cannot keep up with stops
            // reading, which is what lets the pseudoconsole's output fill and the child block.
            if (!self.waitForRoom()) return;

            var count: u32 = 0;
            const diag_outcome = self.readOnce(buffer, overlapped, &count, child_ended);
            log.warn("DIAG read: {s} {d} bytes {f}", .{ @tagName(diag_outcome), count, std.zig.fmtString(buffer[0..@min(count, 200)]) });
            switch (diag_outcome) {
                .bytes => self.enqueue(buffer[0..count]),
                .child_ended => child_ended = true,
                .hung_up, .stopping => return,
            }
        }
    }

    /// Ask for one read of the terminal and wait for it to finish.
    ///
    /// The wait set is the completion, the owner's stop signal and — until the child has been seen
    /// to end — the child itself. `child_ended` drops the child out of it, because a handle that is
    /// already signalled would make every wait return at once.
    fn readOnce(
        self: *ConPty,
        buffer: []u8,
        overlapped: *win.Overlapped,
        count: *u32,
        child_ended: bool,
    ) ReadOutcome {
        _ = win.resetEvent(self.read_done);
        if (win.readFile(self.output, buffer, overlapped)) {
            // A read that completed at once has no completion to wait for, and Windows does not
            // promise its event was signalled. It still reports its size through the OVERLAPPED,
            // which is the only place either kind of completion puts it.
            return self.finishRead(overlapped, count, .bytes);
        }
        const diag_err = win.lastError();
        if (diag_err != .IO_PENDING) log.warn("DIAG ReadFile: {s}", .{@tagName(diag_err)});
        switch (diag_err) {
            // The read is in flight; the wait below is what completes it.
            .IO_PENDING => {},
            // The pseudoconsole hung up: this terminal will never produce bytes again.
            .BROKEN_PIPE, .HANDLE_EOF => return .hung_up,
            else => |err| {
                log.err("cannot read from the terminal: {s}", .{@tagName(err)});
                return .hung_up;
            },
        }

        var handles = [3]win.HANDLE{ self.read_done, self.stop, self.child };
        const waiting = if (child_ended) handles[0..2] else handles[0..3];
        const outcome: ReadOutcome = switch (win.waitOn(waiting, if (child_ended) final_quiet_ms else null)) {
            0 => .bytes,
            1 => .stopping,
            2 => .child_ended,
            // Nothing arrived within one step, or a wait failed and has already been logged.
            else => .hung_up,
        };
        return self.finishRead(overlapped, count, outcome);
    }

    /// Collect the bytes a read delivered, and make sure the OVERLAPPED is finished with before
    /// this thread lets go of it.
    ///
    /// The OVERLAPPED lives on the read thread's stack, so a read still in flight when the thread
    /// returns would leave the I/O manager writing into a frame that is no longer there. Every exit
    /// from a wait therefore cancels the operation and waits for the cancellation itself.
    fn finishRead(self: *ConPty, overlapped: *win.Overlapped, count: *u32, outcome: ReadOutcome) ReadOutcome {
        if (outcome != .bytes) _ = win.cancelIoEx(self.output, overlapped);

        var transferred: u32 = 0;
        if (!win.getOverlappedResult(self.output, overlapped, &transferred)) {
            switch (win.lastError()) {
                // Cancellation is a normal ending, not a failure: the read delivered nothing and
                // nobody will ask about it again.
                .OPERATION_ABORTED => return outcome,
                // The pseudoconsole hung up while the read was in flight.
                .BROKEN_PIPE, .HANDLE_EOF => return if (outcome == .stopping) .stopping else .hung_up,
                else => |err| log.err("cannot collect a read from the terminal: {s}", .{@tagName(err)}),
            }
            return .hung_up;
        }
        // A read that completed before the cancellation reached it still moved bytes, and they are
        // the child's: keep them. A stop is still a stop, and a child that ended is still signalled,
        // so the next wait reports it again.
        if (outcome == .stopping) return outcome;
        if (transferred == 0) {
            // A pipe read that completes with nothing is the far end hanging up.
            return if (outcome == .bytes) .hung_up else outcome;
        }
        count.* = transferred;
        return .bytes;
    }

    /// Wait for room in the ring, or for the owner to stop. `false` means the reader must not
    /// touch the terminal again.
    fn waitForRoom(self: *ConPty) bool {
        while (self.queue.len() == self.queue.buffer.len) {
            var handles = [2]win.HANDLE{ self.space, self.stop };
            switch (win.waitOn(&handles, null)) {
                0 => {},
                // Stopping, or a wait that has already been logged: neither is a reason to spin.
                else => return false,
            }
            if (self.stopping.load(.acquire)) return false;
        }
        return true;
    }

    /// Hand bytes to the owner, waiting for room rather than losing them.
    fn enqueue(self: *ConPty, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len != 0) {
            rest = rest[self.queue.append(rest)..];
            if (rest.len == 0) break;
            if (!self.waitForRoom()) return;
        }
        // The bytes are in the ring before the owner is told, so a wakeup can never arrive before
        // the thing it is a hint for. A signal that arrives with nobody waiting collapses into the
        // wait that comes next, and the owner re-reads the ring either way — which is what makes
        // an automatic-reset event the right kind here.
        _ = win.setEvent(self.owner_wake);
    }

    /// Wait until the child is over, and publish how it ended.
    ///
    /// The only observation of the child's end in this backend, exactly as `waitpid` is the only
    /// one in the POSIX backend: a child is collected once, by the thread that owns it, and the
    /// result is a word everybody else reads without waiting.
    fn publishEnd(self: *ConPty) void {
        while (true) {
            var handles = [2]win.HANDLE{ self.child, self.stop };
            switch (win.waitOn(&handles, reap_interval_ms)) {
                0 => {
                    var code: u32 = 0;
                    if (!win.getExitCodeProcess(self.child, &code)) {
                        // A child Conduit cannot collect is still a child that ended: report the
                        // end as unknown rather than leaving a session's end unreported.
                        log.err("cannot read the exit status of the child: {s}", .{
                            @tagName(win.lastError()),
                        });
                        self.end.store(.unknown, .release);
                        _ = win.setEvent(self.owner_wake);
                        return;
                    }
                    // STILL_ACTIVE is what a process reports while it is still running. The wait
                    // above is what made the code meaningful, and a code that says otherwise is a
                    // process object this thread has not seen the end of yet.
                    if (code == win.still_active) continue;
                    self.end.store(EndWord.fromExitCode(code), .release);
                    _ = win.setEvent(self.owner_wake);
                    return;
                },
                // A terminal being destroyed is one nobody looks at again, and it needs no end:
                // answering the stop request is worth more than blocking on a process.
                else => return,
            }
        }
    }

    fn hasPending(self: *ConPty) bool {
        return self.queue.len() != 0 or self.finished();
    }

    fn finished(self: *const ConPty) bool {
        return self.end.load(.acquire).kind != .running;
    }

    fn waitUntilPending(self: *ConPty, timeout_ms: u32) bool {
        const deadline = win.monotonicMillis() + timeout_ms;
        while (true) {
            if (self.hasPending()) return true;
            if (self.stopping.load(.acquire)) return false;
            const now = win.monotonicMillis();
            if (now >= deadline) return false;
            // A bounded step, so a stop request or an exit is answered promptly even when the
            // timeout is long.
            const step: u32 = @intCast(@min(deadline - now, @as(u64, 50)));
            var handles = [2]win.HANDLE{ self.owner_wake, self.stop };
            _ = win.waitOn(&handles, step);
        }
    }

    /// Write bytes into the terminal's input, as though they were typed.
    ///
    /// The input pipe is not overlapped, so this is the one place a Windows terminal can block on
    /// the owner thread — and it blocks for exactly as long as the terminal's own input buffer
    /// takes to accept the bytes, which is the same bound a write to a POSIX pty master has. The
    /// caller sees it as a short write and retries the rest.
    fn writeBytes(self: *ConPty, bytes: []const u8) Error!usize {
        if (bytes.len == 0) return 0;
        return win.writeFile(self.input, bytes);
    }

    /// Write every byte, looping over the short writes the interface allows. Only an interrupt uses
    /// this, so the owner is not left spinning on a terminal that will not take a byte.
    fn writeAll(self: *ConPty, bytes: []const u8) Error!void {
        var written: usize = 0;
        while (written < bytes.len) {
            written += try self.writeBytes(bytes[written..]);
        }
    }

    /// Tell the pseudoconsole how large the terminal is. This is what a program in the terminal
    /// sees as a resize, and what it is told about as a window size change.
    fn resizeConsole(self: *ConPty, size: WindowSize) Error!void {
        if (self.finished()) return error.Closed;
        win.acquireLock(&self.console_lock);
        defer win.releaseLock(&self.console_lock);
        // The watcher closes the pseudoconsole as soon as the child ends, which can be before the
        // read thread has published that end.
        if (self.console == null) return error.Closed;
        return win.resizePseudoConsole(self.console, size);
    }
};

fn conWrite(ptr: *anyopaque, bytes: []const u8) Error!usize {
    const self: *ConPty = @ptrCast(@alignCast(ptr));
    return self.writeBytes(bytes);
}

fn conResize(ptr: *anyopaque, size: WindowSize) Error!void {
    const self: *ConPty = @ptrCast(@alignCast(ptr));
    return self.resizeConsole(size);
}

fn conKill(ptr: *anyopaque, signal: Signal) Error!void {
    const self: *ConPty = @ptrCast(@alignCast(ptr));
    // Conduit never signals a process whose end the read thread has already published: the exit
    // code is out, so this handle is Conduit's no longer.
    if (self.finished()) return error.Closed;
    switch (signal) {
        // Windows cannot raise an interrupt in another process. `GenerateConsoleCtrlEvent`
        // reaches the console the caller shares with its target, and a child under a
        // pseudoconsole shares none with Conduit. A Ctrl+C is a character on the terminal's input
        // stream, so that is where the character goes.
        .interrupt => return self.writeAll(&[_]u8{0x03}),
        // Windows has no SIGHUP and no SIGTERM: the only way to end a process this thread started
        // is `TerminateProcess`, which reports an exit code rather than a signal.
        .hangup, .terminate, .kill => {
            if (!win.terminateProcess(self.child, terminationCode(signal))) {
                log.err("cannot end the child: {s}", .{@tagName(win.lastError())});
                return error.SystemError;
            }
        },
    }
}

fn conTakeBytes(ptr: *anyopaque, dest: []u8) usize {
    const self: *ConPty = @ptrCast(@alignCast(ptr));
    const taken = self.queue.take(dest);
    // Draining may have made room where there was none, and the read thread is waiting for exactly
    // that when the ring was full. A signal costs nothing and cannot be lost; leaving the reader
    // asleep there would stall the terminal instead.
    if (taken != 0) _ = win.setEvent(self.space);
    return taken;
}

fn conState(ptr: *anyopaque) ChildState {
    const self: *ConPty = @ptrCast(@alignCast(ptr));
    return self.end.load(.acquire).toChildState();
}

fn conWaitReadable(ptr: *anyopaque, timeout_ms: u32) bool {
    const self: *ConPty = @ptrCast(@alignCast(ptr));
    return self.waitUntilPending(timeout_ms);
}

fn conDestroy(ptr: *anyopaque) void {
    const self: *ConPty = @ptrCast(@alignCast(ptr));
    self.stopping.store(true, .release);
    // Wake the read thread wherever it is waiting — a pending read, a wait for room, or the wait
    // for the child — so joining it is a deadline rather than a hope.
    _ = win.setEvent(self.stop);
    if (self.reader) |thread| thread.join();
    if (self.watcher) |thread| thread.join();
    releaseHandles(self);
    self.queue.destroy(self.gpa);
    self.gpa.destroy(self);
}

/// The exit code a Windows child is ended with, for the `Signal` that ended it.
///
/// Windows reports a child's end as a number and never as a signal, so Conduit reports it as one
/// too. The numbers are the 128-plus-signal convention a shell already reads out of `$?`, which
/// keeps `ExitStatus` saying something a program in the terminal understands.
fn terminationCode(signal: Signal) u32 {
    return switch (signal) {
        .hangup => 129, // 128 + SIGHUP
        .interrupt => 130, // 128 + SIGINT
        .terminate => 143, // 128 + SIGTERM
        .kill => 137, // 128 + SIGKILL
    };
}

/// Everything `CreateProcessW` needs from a `SpawnRequest`, built before the child exists.
///
/// `argv` is one string on Windows, not a vector: `CreateProcessW` takes a command line it parses
/// itself, so every argument is quoted here the way `CommandLineToArgvW` reads it back. The
/// program is resolved to a full path first, because a PATH search done by Windows would use
/// Conduit's own environment rather than the one the request carries (P7).
const WindowsRequest = struct {
    /// The program to start, NUL-terminated UTF-16, named by path.
    program: [:0]u16,
    /// The same program as UTF-8, which is what a failed spawn's log line names.
    name: []u8,
    /// The request's `argv`, joined into one NUL-terminated UTF-16 command line.
    command_line: [:0]u16,
    /// The request's environment as one double-NUL-terminated UTF-16 block.
    environment: [:0]u16,
    /// The working directory, or null to keep Conduit's own.
    cwd: ?[:0]u16,
    /// Every allocation made here, so `deinit` frees exactly what `init` allocated.
    owned_bytes: std.ArrayList([]u8) = .empty,
    owned_wide: std.ArrayList([:0]u16) = .empty,

    fn init(gpa: Allocator, request: SpawnRequest) Error!WindowsRequest {
        var prepared: WindowsRequest = .{
            .program = undefined,
            .name = undefined,
            .command_line = undefined,
            .environment = undefined,
            .cwd = null,
        };
        errdefer prepared.deinit(gpa);

        prepared.program = try prepared.keepWide(gpa, try resolveWindowsProgram(
            gpa,
            request.argv[0],
            envValue(request.env, "PATH"),
            envValue(request.env, "PATHEXT"),
        ));
        prepared.name = try prepared.keepBytes(gpa, try duplicate(gpa, request.argv[0]));
        prepared.command_line = try prepared.keepWide(gpa, try buildCommandLine(gpa, request.argv));
        prepared.environment = try prepared.keepWide(gpa, try buildEnvironment(gpa, request.env));
        prepared.cwd = if (request.cwd.len == 0)
            null
        else
            try prepared.keepWide(gpa, try toWide(gpa, request.cwd));
        return prepared;
    }

    fn deinit(self: *WindowsRequest, gpa: Allocator) void {
        for (self.owned_bytes.items) |bytes| gpa.free(bytes);
        self.owned_bytes.deinit(gpa);
        for (self.owned_wide.items) |wide| gpa.free(wide);
        self.owned_wide.deinit(gpa);
    }

    /// Keep an allocation this made, so `deinit` frees it. `wide` is already terminated (see
    /// `ownedTerminator`), and freeing a `[:0]u16` frees its terminator too, which is the whole
    /// allocation.
    fn keepWide(self: *WindowsRequest, gpa: Allocator, wide: [:0]u16) Error![:0]u16 {
        errdefer gpa.free(wide);
        try self.owned_wide.append(gpa, wide);
        return wide;
    }

    fn keepBytes(self: *WindowsRequest, gpa: Allocator, bytes: []u8) Error![]u8 {
        errdefer gpa.free(bytes);
        try self.owned_bytes.append(gpa, bytes);
        return bytes;
    }
};

/// The extensions a bare program name is tried under when the request carries no `PATHEXT`.
///
/// Windows resolves `cmd` to `cmd.exe` through `PATHEXT`, and a request that names no `PATHEXT`
/// gets the set every shell starts with rather than an empty one.
const default_path_extensions = ".COM;.EXE;.BAT;.CMD";

/// Find the program `argv[0]` names, as a full path: as given when it is already a path,
/// otherwise on the `PATH` the request carries. The returned slice is owned by the caller.
///
/// The search uses the *request's* PATH and never Conduit's own, because the environment a
/// workspace was given is the environment its shell runs in (P7). A name with no path in it is
/// also tried with each `PATHEXT` extension, because `cmd` is not a file on disk and `cmd.exe` is.
fn resolveWindowsProgram(
    gpa: Allocator,
    program: []const u8,
    path_value: ?[]const u8,
    extensions: ?[]const u8,
) Error![:0]u16 {
    if (program.len == 0) return error.EmptyArgv;
    // Checked before the search, which would otherwise skip every candidate it cannot convert
    // and report a mangled name as merely missing.
    if (!std.unicode.utf8ValidateSlice(program)) return error.InvalidUtf8;

    // A path is used exactly as it stands: PATH is what a bare name is searched on, and a path
    // that is not there is the caller's error rather than a reason to run something else.
    if (std.mem.indexOfAny(u8, program, "\\/") != null) {
        const wide = try toWide(gpa, program);
        if (win.fileExists(wide)) return wide;
        gpa.free(wide);
        return error.ProgramNotFound;
    }

    var scratch: [win.max_path_chars]u16 = undefined;
    var directories = std.mem.splitScalar(u8, path_value orelse "", ';');
    while (directories.next()) |directory| {
        // An empty entry means the current directory, as every other PATH search does.
        const root = if (directory.len == 0) "." else directory;
        if (findWindowsProgram(&scratch, root, program, "")) |found| return duplicateWide(gpa, found);
        var suffixes = std.mem.splitScalar(u8, extensions orelse default_path_extensions, ';');
        while (suffixes.next()) |suffix| {
            if (suffix.len == 0) continue;
            if (findWindowsProgram(&scratch, root, program, suffix)) |found| return duplicateWide(gpa, found);
        }
    }
    return error.ProgramNotFound;
}

/// Build `root\program<extension>` in `scratch` and report it when Windows has such a file.
fn findWindowsProgram(scratch: []u16, root: []const u8, program: []const u8, extension: []const u8) ?[:0]u16 {
    var length = std.unicode.utf8ToUtf16Le(scratch, root) catch return null;
    if (length + 1 >= scratch.len) return null; // longer than any path Windows takes: not this one
    scratch[length] = '\\';
    length += 1;
    length += std.unicode.utf8ToUtf16Le(scratch[length..], program) catch return null;
    if (length + extension.len >= scratch.len) return null;
    length += std.unicode.utf8ToUtf16Le(scratch[length..], extension) catch return null;
    scratch[length] = 0;
    const candidate = scratch[0..length :0];
    if (!win.fileExists(candidate)) return null;
    return candidate;
}

/// The request's `argv` as the one command line `CreateProcessW` parses.
///
/// Windows has no argv vector: the program and its arguments arrive as a single string, and
/// quoting them is the caller's whole responsibility. Each argument is quoted the way
/// `CommandLineToArgvW` reads it back — a quote doubles the backslashes in front of it and is
/// itself written twice, and a quote closes an even number of backslashes — so an argument with
/// spaces, tabs, quotes or trailing backslashes survives the round trip unchanged.
fn buildCommandLine(gpa: Allocator, argv: []const []const u8) Error![:0]u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(gpa);
    for (argv, 0..) |arg, index| {
        if (index != 0) try out.append(gpa, ' ');
        try appendQuotedArg(gpa, &out, arg);
    }
    try out.append(gpa, 0);
    return ownedTerminator(try out.toOwnedSlice(gpa));
}

fn appendQuotedArg(gpa: Allocator, out: *std.ArrayList(u16), arg: []const u8) Error!void {
    // An argument the parser would not split or unquote is written as it stands, which is what
    // keeps the command line a program's own diagnostics can echo back legibly.
    if (arg.len != 0 and std.mem.indexOfAny(u8, arg, " \t\"") == null) {
        try appendWide(gpa, out, arg);
        return;
    }
    try out.append(gpa, '"');
    var backslashes: usize = 0;
    for (arg) |char| {
        if (char == '\\') {
            // Held back, because how many of them are written depends on what comes next.
            backslashes += 1;
            continue;
        }
        if (char == '"') {
            for (0..2 * backslashes + 1) |_| try out.append(gpa, '\\');
        } else {
            for (0..backslashes) |_| try out.append(gpa, '\\');
        }
        backslashes = 0;
        try out.append(gpa, char);
    }
    // Backslashes at the very end would escape the closing quote.
    for (0..2 * backslashes) |_| try out.append(gpa, '\\');
    try out.append(gpa, '"');
}

/// Append UTF-8 text as UTF-16. At most one UTF-16 unit per UTF-8 byte, so the reservation is an
/// upper bound and never short.
fn appendWide(gpa: Allocator, out: *std.ArrayList(u16), text: []const u8) Error!void {
    try out.ensureUnusedCapacity(gpa, text.len);
    const written = try std.unicode.utf8ToUtf16Le(out.unusedCapacitySlice(), text);
    out.items.len += written;
}

/// The request's environment as the one block `CreateProcessW` takes: `KEY=VALUE` entries, each
/// NUL-terminated, and the whole block NUL-terminated again so the last entry is delimited.
///
/// Entries are written in the order the request gives them, because the block is the child's
/// environment exactly as the request described it and Conduit merges nothing of its own into a
/// spawn (P7). A request with no entries yields an empty block — a child with no environment at
/// all, never Conduit's.
fn buildEnvironment(gpa: Allocator, env: []const []const u8) Error![:0]u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(gpa);
    for (env) |entry| {
        try appendWide(gpa, &out, entry);
        try out.append(gpa, 0);
    }
    // The block's own terminator, which is what delimits the last entry. With no entries at all
    // this is the whole block, and Windows reads it as a child with no environment of its own.
    try out.append(gpa, 0);
    return ownedTerminator(try out.toOwnedSlice(gpa));
}

/// Convert one request string into the UTF-16 Windows expects.
///
/// A string that is not valid UTF-8 is refused rather than replaced: a shell started with a mangled
/// argument is a worse outcome than a spawn that did not happen.
fn toWide(gpa: Allocator, text: []const u8) Error![:0]u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(gpa);
    try appendWide(gpa, &out, text);
    try out.append(gpa, 0);
    return ownedTerminator(try out.toOwnedSlice(gpa));
}

/// An allocation this backend owns, seen as the NUL-terminated string it is.
///
/// The terminator is inside the slice on purpose: every one of these allocations is freed by the
/// slice it was handed out as, and a shorter slice would ask the allocator to free a size it never
/// gave.
fn ownedTerminator(owned: []u16) [:0]u16 {
    // The last element is the terminator, so the text ends one before it; freeing the `[:0]`
    // slice frees `len + 1` elements, which is the whole allocation again.
    return owned[0 .. owned.len - 1 :0];
}

/// A NUL-terminated copy of `wide`, returned whole: the caller frees the whole slice, so handing
/// back only the text would free a size the allocator never gave out.
fn duplicateWide(gpa: Allocator, wide: []const u16) Allocator.Error![:0]u16 {
    const owned = try gpa.alloc(u16, wide.len + 1);
    @memcpy(owned[0..wide.len], wide);
    owned[wide.len] = 0;
    return ownedTerminator(owned);
}

/// One pipe and its two ends.
///
/// `conduit` is the end this backend uses and `conpty` the end `CreatePseudoConsole` is given.
/// Closing a handle leaves `INVALID_HANDLE_VALUE` behind, so `close` on a pipe whose end has
/// already moved into a terminal does nothing for that end — which is what lets ownership be
/// transferred without a second path that forgets to disarm an `errdefer`.
const WindowsPipe = struct {
    conduit: win.HANDLE = invalid_handle,
    conpty: win.HANDLE = invalid_handle,

    fn close(self: *WindowsPipe) void {
        win.closeHandle(self.conduit);
        self.conduit = invalid_handle;
        self.closeConPtyEnd();
    }

    /// Release the pseudoconsole's end once `CreatePseudoConsole` has duplicated it.
    fn closeConPtyEnd(self: *WindowsPipe) void {
        win.closeHandle(self.conpty);
        self.conpty = invalid_handle;
    }
};

/// A child's process object, and nothing else.
const WindowsChild = struct {
    handle: win.HANDLE = invalid_handle,
    pid: win.DWORD = 0,

    fn close(self: *WindowsChild) void {
        win.closeHandle(self.handle);
        self.handle = invalid_handle;
    }
};

/// The `INVALID_HANDLE_VALUE` a handle is left as once it has been closed, and the value every
/// handle field starts at.
const invalid_handle = win.closed_handle;

// ---------------------------------------------------------------------------
// The Windows calls this backend is written against
// ---------------------------------------------------------------------------

/// One function per Windows call, each declared against the prototype in the Windows SDK header
/// named beside it.
///
/// This is the only part of the file that knows what a `HANDLE` is. `std.os.windows` declares
/// `CreateProcessW` and almost nothing else a terminal needs — the pseudoconsole trio, the process
/// thread attribute list, the overlapped pipe IO and the wait functions are all absent from it —
/// so they are declared here. Every one of them resolves in `kernel32` on the targets Conduit
/// ships, which is why each is declared against that library rather than through a header.
const win = struct {
    const windows = std.os.windows;

    const HANDLE = windows.HANDLE;
    /// `HPCON`, from wincontypes.h: what `CreatePseudoConsole` hands back.
    const HPCON = ?*anyopaque;
    const BOOL = windows.BOOL;
    const DWORD = windows.DWORD;
    const DWORD_PTR = windows.DWORD_PTR;
    const Win32Error = windows.Win32Error;
    /// `HRESULT`, which is what both pseudoconsole calls report success with.
    const HRESULT = i32;

    /// `INVALID_HANDLE_VALUE`, which is what a closed handle is left as by convention and what
    /// every handle field in this backend starts and ends at.
    const closed_handle = windows.INVALID_HANDLE_VALUE;

    /// `S_OK`, the one `HRESULT` value that means the call worked.
    const s_ok: HRESULT = 0;

    /// `STILL_ACTIVE`: the exit code a process object reports while its process is still running.
    const still_active: DWORD = 259;

    /// `WAIT_TIMEOUT`, `WAIT_FAILED` and `INFINITE`, from winbase.h.
    const wait_timeout: DWORD = 258;
    const wait_failed: DWORD = 0xffffffff;
    const infinite: DWORD = 0xffffffff;

    /// `PIPE_ACCESS_INBOUND`, `FILE_FLAG_OVERLAPPED`, `FILE_FLAG_FIRST_PIPE_INSTANCE` and
    /// `HANDLE_FLAG_INHERIT`, from winbase.h; `PIPE_REJECT_REMOTE_CLIENTS` (with the zero-valued
    /// `PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT`) from namedpipeapi.h's companion winbase.h.
    const pipe_access_inbound: DWORD = 0x00000001;
    const file_flag_overlapped: DWORD = 0x40000000;
    const file_flag_first_pipe_instance: DWORD = 0x00080000;
    const pipe_reject_remote_clients: DWORD = 0x00000008;
    const handle_flag_inherit: DWORD = 0x00000001;

    /// `GENERIC_WRITE`, `OPEN_EXISTING` and `FILE_ATTRIBUTE_NORMAL`, for the pseudoconsole's end of
    /// the output pipe.
    const generic_write: DWORD = 0x40000000;
    const open_existing: DWORD = 3;
    const file_attribute_normal: DWORD = 0x00000080;

    /// How many bytes the output pipe buffers. A screenful of rendered VT is a few kilobytes, so
    /// this is room for several frames before the pseudoconsole has to wait for the read thread.
    const output_pipe_buffer: DWORD = 64 * 1024;

    /// `STARTF_USESTDHANDLES`, from processthreadsapi.h.
    const startf_usestdhandles: DWORD = 0x00000100;

    /// `EXTENDED_STARTUPINFO_PRESENT`, which is what tells `CreateProcessW` that the startup
    /// information is a `STARTUPINFOEXW` with an attribute list behind it, and
    /// `CREATE_UNICODE_ENVIRONMENT`, which is what makes the environment block UTF-16.
    const extended_startupinfo_present: DWORD = 0x00080000;
    const create_unicode_environment: DWORD = 0x00000400;

    /// `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`, from winbase.h: the input attribute numbered 22, so
    /// `0x00020000 | 22`. This is the attribute that attaches the child to a pseudoconsole.
    const proc_thread_attribute_pseudoconsole: DWORD_PTR = 0x00020016;

    /// `FILE_ATTRIBUTE_DIRECTORY` and `INVALID_FILE_ATTRIBUTES`, from fileapi.h.
    const file_attribute_directory: DWORD = 0x00000010;
    const invalid_file_attributes: DWORD = 0xffffffff;

    /// How many UTF-16 units a candidate program path may take. A longer path is not the one that
    /// was asked for; it is skipped rather than truncated into a different program.
    const max_path_chars = 4096;

    /// Which kind of event this backend asks for.
    const Reset = enum {
        /// Stays signalled until cleared. A completion needs this: an automatic event can lose the
        /// signal between the wait that should have noticed it and the wait that comes after.
        manual,
        /// One signal is one wakeup, and the next wait starts over. A hint needs this, because a
        /// hint that has not been acted on yet is still true.
        automatic,
    };

    /// The answer to "which handle was it": not a handle at all. A timeout and a failed wait both
    /// answer the same way here, because in both cases whatever the caller was waiting for is
    /// still false and it asks again.
    const no_signal = std.math.maxInt(usize);

    // --- The pseudoconsole: consoleapi.h ------------------------------------

    extern "kernel32" fn CreatePseudoConsole(
        size: Coord,
        input: HANDLE,
        output: HANDLE,
        flags: DWORD,
        console: *HPCON,
    ) callconv(.winapi) HRESULT;

    extern "kernel32" fn ResizePseudoConsole(console: HPCON, size: Coord) callconv(.winapi) HRESULT;

    extern "kernel32" fn ClosePseudoConsole(console: HPCON) callconv(.winapi) void;

    // --- Attaching a child to it: processthreadsapi.h, winbase.h -------------

    extern "kernel32" fn InitializeProcThreadAttributeList(
        list: ?*anyopaque,
        attribute_count: DWORD,
        flags: DWORD,
        size: *windows.SIZE_T,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn DeleteProcThreadAttributeList(list: ?*anyopaque) callconv(.winapi) void;

    extern "kernel32" fn UpdateProcThreadAttribute(
        list: ?*anyopaque,
        flags: DWORD,
        attribute: DWORD_PTR,
        value: ?*const anyopaque,
        size: windows.SIZE_T,
        previous: ?*anyopaque,
        returned_size: ?*windows.SIZE_T,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn CreateProcessW(
        application: ?windows.LPCWSTR,
        command_line: ?[*:0]u16,
        process_attributes: ?*windows.SECURITY_ATTRIBUTES,
        thread_attributes: ?*windows.SECURITY_ATTRIBUTES,
        inherit_handles: BOOL,
        flags: DWORD,
        environment: ?[*:0]const u16,
        directory: ?windows.LPCWSTR,
        startup_info: *windows.STARTUPINFOW,
        process_info: *windows.PROCESS.INFORMATION,
    ) callconv(.winapi) BOOL;

    // --- Pipes, IO and waiting: namedpipeapi.h, fileapi.h, synchapi.h --------

    extern "kernel32" fn CreatePipe(
        read_end: *HANDLE,
        write_end: *HANDLE,
        attributes: ?*windows.SECURITY_ATTRIBUTES,
        size: DWORD,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn SetHandleInformation(handle: HANDLE, mask: DWORD, flags: DWORD) callconv(.winapi) BOOL;

    // Declared exactly as `platform` declares them, because both modules link into one binary.
    extern "kernel32" fn CreateNamedPipeW(
        name: windows.LPCWSTR,
        open_mode: DWORD,
        pipe_mode: DWORD,
        max_instances: DWORD,
        out_buffer_size: DWORD,
        in_buffer_size: DWORD,
        default_timeout_ms: DWORD,
        attributes: *windows.SECURITY_ATTRIBUTES,
    ) callconv(.winapi) HANDLE;

    extern "kernel32" fn CreateFileW(
        name: windows.LPCWSTR,
        desired_access: DWORD,
        share_mode: DWORD,
        attributes: ?*windows.SECURITY_ATTRIBUTES,
        creation_disposition: DWORD,
        flags_and_attributes: DWORD,
        template: ?HANDLE,
    ) callconv(.winapi) HANDLE;

    // --- The lock between resize and close: synchapi.h -----------------------

    /// `SRWLOCK`: one pointer, zero when unlocked, and never allocated.
    const SrwLock = windows.SRWLOCK;

    extern "kernel32" fn AcquireSRWLockExclusive(lock: *SrwLock) callconv(.winapi) void;

    extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SrwLock) callconv(.winapi) void;

    extern "kernel32" fn ReadFile(
        handle: HANDLE,
        buffer: [*]u8,
        count: DWORD,
        transferred: ?*DWORD,
        overlapped: ?*Overlapped,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn WriteFile(
        handle: HANDLE,
        buffer: [*]const u8,
        count: DWORD,
        written: ?*DWORD,
        overlapped: ?*Overlapped,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn GetOverlappedResult(
        handle: HANDLE,
        overlapped: *Overlapped,
        transferred: *DWORD,
        wait: BOOL,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn CancelIoEx(handle: HANDLE, overlapped: ?*Overlapped) callconv(.winapi) BOOL;

    extern "kernel32" fn CreateEventW(
        attributes: ?*windows.SECURITY_ATTRIBUTES,
        manual_reset: BOOL,
        initial_state: BOOL,
        name: ?windows.LPCWSTR,
    ) callconv(.winapi) ?HANDLE;

    extern "kernel32" fn SetEvent(event: HANDLE) callconv(.winapi) BOOL;

    extern "kernel32" fn ResetEvent(event: HANDLE) callconv(.winapi) BOOL;

    extern "kernel32" fn WaitForMultipleObjects(
        count: DWORD,
        handles: [*]const HANDLE,
        wait_all: BOOL,
        timeout_ms: DWORD,
    ) callconv(.winapi) DWORD;

    // --- The child: processthreadsapi.h, sysinfoapi.h, fileapi.h -------------

    extern "kernel32" fn GetExitCodeProcess(process: HANDLE, code: *DWORD) callconv(.winapi) BOOL;

    extern "kernel32" fn TerminateProcess(process: HANDLE, exit_code: windows.UINT) callconv(.winapi) BOOL;

    extern "kernel32" fn GetProcessHandleCount(process: HANDLE, count: *DWORD) callconv(.winapi) BOOL;

    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

    extern "kernel32" fn GetFileAttributesW(path: windows.LPCWSTR) callconv(.winapi) DWORD;

    /// `COORD`, from wincontypes.h. `x` is a column and `y` is a row, which is the opposite order
    /// to `WindowSize`'s own fields: the pseudoconsole is told in cells, and a caller that got
    /// this backwards would transpose every window.
    const Coord = extern struct {
        x: i16,
        y: i16,

        fn fromSize(size: WindowSize) Coord {
            return .{ .x = @intCast(size.cols), .y = @intCast(size.rows) };
        }
    };

    /// `OVERLAPPED`, from minwinbase.h. Zeroed before every read: the I/O manager writes the number
    /// of bytes it moved through it, which is why a completed read reports its size through
    /// `GetOverlappedResult` and never through `ReadFile`.
    const Overlapped = extern struct {
        internal: windows.ULONG_PTR,
        internal_high: windows.ULONG_PTR,
        /// `DUMMYUNIONNAME`: an offset read uses `Offset`, and a zeroed union reads as zero through
        /// either arm, which is the one thing this backend relies on about it.
        offset: extern union {
            named: extern struct { offset: DWORD, offset_high: DWORD },
            pointer: ?*anyopaque,
        },
        event: ?HANDLE,
        /// `Internal`, the field the I/O manager keeps its own status in. Named apart from the one
        /// above because `OVERLAPPED` has two.
        status: windows.ULONG_PTR,
    };

    /// `STARTUPINFOEXW`, from winbase.h: a `STARTUPINFOW` with the attribute list behind it. The
    /// child is attached to the pseudoconsole by what that list carries; the only `STARTUPINFOW`
    /// fields set are the size and the flag that stops redirected handles being inherited.
    const StartupInfoExW = extern struct {
        startup_info: windows.STARTUPINFOW,
        attribute_list: ?*anyopaque,
    };

    fn lastError() Win32Error {
        return windows.GetLastError();
    }

    /// Report a Win32 failure with the error code that caused it.
    fn failure(context: []const u8, call: []const u8) Error {
        log.err("{s} failed: {s} ({s})", .{ context, call, @tagName(lastError()) });
        return error.SystemError;
    }

    /// Report an `HRESULT` failure. The pseudoconsole calls do not set the last error, so the code
    /// they return is the only reason there is.
    fn hresultFailure(context: []const u8, call: []const u8, code: HRESULT) Error {
        log.err("{s} failed: {s} (HRESULT 0x{X:0>8})", .{
            context,
            call,
            @as(u32, @bitCast(code)),
        });
        return error.SystemError;
    }

    /// Close a handle, once. `INVALID_HANDLE_VALUE` is what a released handle is left as, so the
    /// same terminal can be torn down on a failed spawn and by `destroy` without either of them
    /// closing anything the other has already closed.
    fn closeHandle(handle: HANDLE) void {
        if (handle == closed_handle) return;
        _ = windows.CloseHandle(handle);
    }

    /// Close the pseudoconsole, which is what ends the terminal's child side: the pseudoconsole
    /// owns the far ends of both pipes, and dropping them is the hangup.
    fn closePseudoConsole(console: HPCON) void {
        if (console == null) return;
        ClosePseudoConsole(console);
    }

    fn acquireLock(lock: *SrwLock) void {
        AcquireSRWLockExclusive(lock);
    }

    fn releaseLock(lock: *SrwLock) void {
        ReleaseSRWLockExclusive(lock);
    }

    /// The input pipe: the pseudoconsole reads it and Conduit writes it, so the pseudoconsole is
    /// given the read end and Conduit keeps the write end. Neither end is inheritable, so nothing
    /// Conduit starts inherits a terminal handle by accident. It is not overlapped, because a write
    /// to it is bounded by the terminal's own input buffer and needs no completion to wait for.
    fn createInputPipe() Error!WindowsPipe {
        var pipe: WindowsPipe = .{};
        errdefer pipe.close();
        // `CreatePipe` hands back the read end first and the write end second.
        if (CreatePipe(&pipe.conpty, &pipe.conduit, null, 0) == .FALSE) {
            return failure("create the terminal's input pipe", "CreatePipe");
        }
        if (SetHandleInformation(pipe.conduit, handle_flag_inherit, 0) == .FALSE or
            SetHandleInformation(pipe.conpty, handle_flag_inherit, 0) == .FALSE)
        {
            return failure("mark a pipe end non-inheritable", "SetHandleInformation");
        }
        return pipe;
    }

    /// Distinguishes the output pipes of one process's terminals. The name only has to be unique
    /// for the instant between creating the pipe and opening its other end; the process id keeps
    /// two Conduits apart and `FILE_FLAG_FIRST_PIPE_INSTANCE` refuses a name anybody else holds.
    var output_pipe_serial: std.atomic.Value(u32) = .init(0);

    /// The output pipe: the pseudoconsole writes it and Conduit reads it, through an `OVERLAPPED`
    /// so the read thread can be woken out of a read that has not completed.
    ///
    /// `CreatePipe` makes anonymous pipes that cannot be read with overlapped IO (a read through
    /// one blocks no matter what is passed), so this is a one-instance, local-only named pipe
    /// whose server end is Conduit's overlapped, inbound read end and whose client end, opened
    /// write-only without `FILE_FLAG_OVERLAPPED`, is the pseudoconsole's.
    fn createOutputPipe() Error!WindowsPipe {
        var pipe: WindowsPipe = .{};
        errdefer pipe.close();

        var attributes: windows.SECURITY_ATTRIBUTES = .{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = null,
            .bInheritHandle = .FALSE,
        };
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            var text: [96]u8 = undefined;
            const name = std.fmt.bufPrint(&text, "\\\\.\\pipe\\conduit-pty-{d}-{d}-{d}", .{
                windows.GetCurrentProcessId(),
                output_pipe_serial.fetchAdd(1, .monotonic),
                GetTickCount64(),
            }) catch unreachable; // 96 bytes holds the prefix and three decimal integers.
            var wide: [96:0]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(&wide, name) catch unreachable; // ASCII.
            wide[len] = 0;

            pipe.conduit = CreateNamedPipeW(
                &wide,
                pipe_access_inbound | file_flag_overlapped | file_flag_first_pipe_instance,
                pipe_reject_remote_clients,
                1,
                0,
                output_pipe_buffer,
                0,
                &attributes,
            );
            if (pipe.conduit != closed_handle) {
                pipe.conpty = CreateFileW(&wide, generic_write, 0, &attributes, open_existing, file_attribute_normal, null);
                if (pipe.conpty == closed_handle) {
                    return failure("open the terminal's output pipe", "CreateFileW");
                }
                return pipe;
            }
            // Somebody else holds this name. Another name is one serial away; a pipe that cannot be
            // created under any of a handful of names is a real failure.
            const err = lastError();
            if ((err != .ACCESS_DENIED and err != .PIPE_BUSY) or attempt >= 8) {
                return failure("create the terminal's output pipe", "CreateNamedPipeW");
            }
        }
    }

    /// Create a pseudoconsole `size` cells big, reading `input` and writing `output`.
    fn createPseudoConsole(size: WindowSize, input: HANDLE, output: HANDLE) Error!HPCON {
        var console: HPCON = undefined;
        // `PSEUDOCONSOLE_INHERIT_CURSOR` is deliberately not asked for: Conduit draws the cursor
        // itself, and a pseudoconsole that also draws one leaves it doubled on screen.
        const code = CreatePseudoConsole(Coord.fromSize(size), input, output, 0, &console);
        if (code != s_ok) return hresultFailure("create a pseudoconsole", "CreatePseudoConsole", code);
        return console;
    }

    /// Tell the pseudoconsole its new size, which is the resize a program in the terminal sees.
    fn resizePseudoConsole(console: HPCON, size: WindowSize) Error!void {
        const code = ResizePseudoConsole(console, Coord.fromSize(size));
        if (code != s_ok) return hresultFailure("resize the terminal", "ResizePseudoConsole", code);
    }

    /// Start `prepared`'s program attached to `console`.
    ///
    /// The pseudoconsole is attached through `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` on a
    /// `STARTUPINFOEXW`, and no handle is inherited, so the child's standard handles are the
    /// pseudoconsole's and nothing else of Conduit's reaches it. The program is named by
    /// `lpApplicationName` rather than searched for along the command line, so the `PATH` that
    /// decides which program runs is the request's and not Conduit's own (P7).
    fn createProcess(gpa: Allocator, prepared: WindowsRequest, console: HPCON) Error!WindowsChild {
        var child: WindowsChild = .{};
        errdefer child.close();

        // Two calls, as documented: asked with no list, this one reports how much room a list with
        // this many attributes needs, and says so by failing with ERROR_INSUFFICIENT_BUFFER.
        var needed: windows.SIZE_T = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &needed);
        if (lastError() != .INSUFFICIENT_BUFFER) {
            return failure("size a startup attribute list", "InitializeProcThreadAttributeList");
        }
        const attributes = gpa.alloc(u8, needed) catch |err| return err;
        defer gpa.free(attributes);
        if (InitializeProcThreadAttributeList(attributes.ptr, 1, 0, &needed) == .FALSE) {
            return failure("create a startup attribute list", "InitializeProcThreadAttributeList");
        }
        defer DeleteProcThreadAttributeList(attributes.ptr);
        if (UpdateProcThreadAttribute(
            attributes.ptr,
            0,
            proc_thread_attribute_pseudoconsole,
            console,
            @sizeOf(HPCON),
            null,
            null,
        ) == .FALSE) {
            return failure("attach the child to the pseudoconsole", "UpdateProcThreadAttribute");
        }

        var startup: StartupInfoExW = std.mem.zeroes(StartupInfoExW);
        // `cb` is the size of the whole extended structure, not of the `STARTUPINFOW` in front of
        // it: this is how `CreateProcessW` knows an attribute list follows.
        startup.startup_info.cb = @sizeOf(StartupInfoExW);
        startup.attribute_list = attributes.ptr;
        // Without this a console child of a Conduit whose own standard handles are redirected (a
        // pipe, a file, a CI log) is handed those handles instead of the pseudoconsole's and
        // writes past the terminal entirely. Null handles with the flag set make the child take
        // its standard handles from the console it is attached to, which is the pseudoconsole.
        startup.startup_info.dwFlags = if (diag_use_std_handles) startf_usestdhandles else 0;
        startup.startup_info.hStdInput = null;
        startup.startup_info.hStdOutput = null;
        startup.startup_info.hStdError = null;

        var info: windows.PROCESS.INFORMATION = undefined;
        const started = CreateProcessW(
            prepared.program.ptr,
            prepared.command_line.ptr,
            null,
            null,
            .FALSE,
            extended_startupinfo_present | create_unicode_environment,
            prepared.environment.ptr,
            if (prepared.cwd) |directory| directory.ptr else null,
            &startup.startup_info,
            &info,
        );
        if (started == .FALSE) {
            log.err("cannot start {s}: CreateProcessW", .{prepared.name});
            const err = lastError();
            log.err("CreateProcessW failed: {s}", .{@tagName(err)});
            return error.SpawnFailed;
        }
        // The thread handle is not Conduit's to keep: the child is observed through its process
        // object, and an unclosed thread handle is one this process would hold for ever.
        _ = windows.CloseHandle(info.hThread);
        child.handle = info.hProcess;
        child.pid = info.dwProcessId;
        return child;
    }

    /// An event this backend can wait on.
    fn createEvent(reset: Reset) Error!HANDLE {
        const event = CreateEventW(null, .fromBool(reset == .manual), .FALSE, null) orelse
            return failure("create an event", "CreateEventW");
        return event;
    }

    /// Wait for any of `handles` to be signalled, and report which one. `null` waits as long as it
    /// takes; a timeout and a failed wait both answer `no_signal`.
    fn waitOn(handles: []const HANDLE, timeout_ms: ?u32) usize {
        const status = WaitForMultipleObjects(
            @intCast(handles.len),
            handles.ptr,
            .FALSE,
            timeout_ms orelse infinite,
        );
        if (status == wait_failed) {
            log.err("cannot wait on the terminal: {s}", .{@tagName(lastError())});
            return no_signal;
        }
        if (status == wait_timeout) return no_signal;
        return status; // WAIT_OBJECT_0 + the index of the handle that signalled
    }

    /// Start a read that finishes when `overlapped`'s event is signalled.
    ///
    /// `false` with `ERROR_IO_PENDING` is the ordinary answer for a read that has not completed
    /// yet; every other failure means this read produced nothing and will produce nothing.
    fn readFile(handle: HANDLE, buffer: []u8, overlapped: *Overlapped) bool {
        return ReadFile(handle, buffer.ptr, @intCast(buffer.len), null, overlapped) != .FALSE;
    }

    /// Write to a pipe opened without `FILE_FLAG_OVERLAPPED`, which is the input side of a
    /// pseudoconsole. It blocks until the terminal's input buffer takes the bytes, exactly as a
    /// write to a POSIX pty master does.
    fn writeFile(handle: HANDLE, bytes: []const u8) Error!usize {
        var written: DWORD = 0;
        if (WriteFile(handle, bytes.ptr, @intCast(bytes.len), &written, null) != .FALSE) {
            return written;
        }
        return switch (lastError()) {
            .BROKEN_PIPE, .HANDLE_EOF => error.Closed,
            else => |err| blk: {
                log.err("cannot write to the terminal: {s}", .{@tagName(err)});
                break :blk error.SystemError;
            },
        };
    }

    /// Collect a finished read, waiting for it if it has not finished. Every read this backend
    /// issues is waited on to completion before its `OVERLAPPED` goes out of scope.
    fn getOverlappedResult(handle: HANDLE, overlapped: *Overlapped, transferred: *DWORD) bool {
        return GetOverlappedResult(handle, overlapped, transferred, .TRUE) != .FALSE;
    }

    /// Cancel one in-flight read, which is what makes leaving a wait early safe: the operation ends
    /// with `ERROR_OPERATION_ABORTED` instead of the I/O manager still holding a pointer to an
    /// `OVERLAPPED` this thread owns.
    fn cancelIoEx(handle: HANDLE, overlapped: *Overlapped) bool {
        return CancelIoEx(handle, overlapped) != .FALSE;
    }

    fn setEvent(event: HANDLE) bool {
        return SetEvent(event) != .FALSE;
    }

    fn resetEvent(event: HANDLE) bool {
        return ResetEvent(event) != .FALSE;
    }

    /// The child's exit code. Meaningful only once the process object has been signalled, which is
    /// the read thread's own wait.
    fn getExitCodeProcess(process: HANDLE, code: *DWORD) bool {
        return GetExitCodeProcess(process, code) != .FALSE;
    }

    /// End a process. Windows has no way to ask a process to end politely, so every signal that
    /// means "stop" but for `.interrupt` arrives here.
    fn terminateProcess(process: HANDLE, exit_code: windows.UINT) bool {
        return TerminateProcess(process, exit_code) != .FALSE;
    }

    /// How many handles this process holds, asked of the OS rather than counted in Conduit. This
    /// is how the Windows handle-leak test measures instead of assuming.
    fn processHandleCount() Error!DWORD {
        var count: DWORD = 0;
        if (GetProcessHandleCount(windows.GetCurrentProcess(), &count) == .FALSE) {
            return failure("count this process's handles", "GetProcessHandleCount");
        }
        return count;
    }

    /// Milliseconds since boot. Monotonic, so a wait ends no later than it was asked to.
    fn monotonicMillis() u64 {
        return GetTickCount64();
    }

    /// Whether a path names something this process may start, rather than a directory.
    fn fileExists(path: [:0]const u16) bool {
        const attributes = GetFileAttributesW(path.ptr);
        if (attributes == invalid_file_attributes) return false;
        return attributes & file_attribute_directory == 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a terminal resized to nothing keeps one row and one column" {
    // A user dragging a pane divider past the edge must not lose the shell behind it.
    const collapsed = WindowSize.init(0, 0);
    try testing.expectEqual(WindowSize.min_dimension, collapsed.rows);
    try testing.expectEqual(WindowSize.min_dimension, collapsed.cols);

    const half = WindowSize.init(0, 120);
    try testing.expectEqual(WindowSize.min_dimension, half.rows);
    try testing.expectEqual(@as(u16, 120), half.cols);
}

test "a resize request round-trips through its byte encoding" {
    const size = WindowSize.init(24, 80);
    const bytes = size.encode();

    // The pixel fields are zero, not garbage: a backend that forwards them verbatim must not tell
    // the shell a cell is a pixel.
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, bytes[4..8]);

    const decoded = WindowSize.decode(bytes);
    try testing.expectEqual(size.rows, decoded.rows);
    try testing.expectEqual(size.cols, decoded.cols);
    try testing.expectEqual(size, decoded);
}

test "the encoded size is little-endian in the order the OS reads it" {
    // 24 rows = 0x0018, 80 cols = 0x0050.
    const bytes = WindowSize.init(24, 80).encode();

    try testing.expectEqualSlices(u8, &[_]u8{ 0x18, 0x00, 0x50, 0x00 }, bytes[0..4]);
    try testing.expectEqual(@as(usize, 8), bytes.len);
}

test "cell count matches the grid the renderer will lay out" {
    try testing.expectEqual(@as(u32, 1920), WindowSize.init(24, 80).cells());

    // A clamped size counts the clamped grid, not the size that was asked for.
    try testing.expectEqual(@as(u32, 1), WindowSize.init(0, 0).cells());
}

test "a dimension larger than the wire type saturates instead of wrapping" {
    // A window wider than 65535 cells is not a window. Wrapping it to a small number would resize
    // the shell to something the user never asked for.
    const huge = WindowSize.init(std.math.maxInt(u32), 300);
    try testing.expectEqual(std.math.maxInt(u16), huge.rows);
    try testing.expectEqual(@as(u16, 300), huge.cols);
}

test "a PTY child restores every terminal signal, including interrupt" {
    const expected = [_]ChildSignal{
        .hangup,
        .interrupt,
        .quit,
        .terminate,
        .terminal_stop,
        .background_read,
        .background_write,
        .window_change,
    };

    try testing.expectEqualSlices(ChildSignal, &expected, &child_signals);
    try testing.expectEqualStrings(
        "the child's terminal signal state could not be restored",
        ChildFailure.signal_state.describe(),
    );
    if (comptime builtin.os.tag == .linux) {
        try testing.expectEqual(@as(u32, 2), @intFromEnum(sys.linuxChildSignal(.interrupt)));
    } else if (comptime builtin.os.tag == .macos) {
        try testing.expectEqual(@as(u32, 2), @intFromEnum(sys.darwinChildSignal(.interrupt)));
    }
}

/// Every type the interface is allowed to name. A backend on any platform, POSIX or not, answers
/// with these and nothing else.
const interface_types = [_]type{
    void,
    bool,
    usize,
    u32,
    *anyopaque,
    []const u8,
    []u8,
    WindowSize,
    Signal,
    ChildState,
};

fn isInterfaceType(comptime candidate: type) bool {
    inline for (interface_types) |allowed| {
        if (allowed == candidate) return true;
    }
    return false;
}

/// Whether a function pointer in the vtable speaks only interface types.
///
/// Every leaf it names has to be one of `interface_types`, and every error it can return has to be
/// exactly `Error`. A `pid_t`, a descriptor, a `struct winsize` or a `std.posix` error union would
/// fail here — which is what makes a ConPTY backend possible rather than merely intended.
fn signatureIsClean(comptime Function: type) bool {
    comptime {
        const info = @typeInfo(Function).@"fn";
        if (info.return_type) |returned| {
            switch (@typeInfo(returned)) {
                .error_union => if (@typeInfo(returned).error_union.error_set != Error) return false,
                else => if (!isInterfaceType(returned)) return false,
            }
        }
        for (info.params) |param| {
            if (!isInterfaceType(param.type.?)) return false;
        }
        return true;
    }
}

test "the interface surface names no POSIX-only type" {
    // The handle is opaque and its vtable is a pointer: nothing else may be reachable from a Pty.
    inline for (@typeInfo(Pty).@"struct".fields) |field| {
        try testing.expect(field.type == *const Pty.VTable or isInterfaceType(field.type));
    }

    // Every method, checked leaf by leaf rather than by reading the file and hoping.
    var methods: usize = 0;
    inline for (@typeInfo(Pty.VTable).@"struct".fields) |field| {
        try testing.expect(comptime signatureIsClean(@typeInfo(field.type).pointer.child));
        methods += 1;
    }
    try testing.expectEqual(@typeInfo(Pty.VTable).@"struct".fields.len, methods);

    // The named types are Conduit's own, not aliases of OS ones.
    try testing.expect(@typeInfo(WindowSize) == .@"struct");
    try testing.expect(@typeInfo(Signal) == .@"enum");
    try testing.expect(@typeInfo(ChildState) == .@"union");
    try testing.expect(@typeInfo(ExitStatus) == .@"union");
}

/// A terminal backend that is not POSIX at all: it records what the interface was asked to do and
/// answers from memory. If `Pty` needed a descriptor, a pid or an OS error to work, this would not
/// compile — which is the point of it standing in for the ConPTY backend before that backend exists.
const FakeTerminal = struct {
    const vtable: Pty.VTable = .{
        .write = fakeWrite,
        .resize = fakeResize,
        .kill = fakeKill,
        .takeBytes = fakeTakeBytes,
        .state = fakeState,
        .waitReadable = fakeWaitReadable,
        .destroy = fakeDestroy,
    };

    gpa: Allocator,
    written: std.ArrayList([]const u8) = .empty,
    resized: ?WindowSize = null,
    signalled: ?Signal = null,
    pending: []const u8 = "",
    end: ChildState = .running,
    destroyed: bool = false,

    fn asPty(self: *FakeTerminal) Pty {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn fakeWrite(ptr: *anyopaque, bytes: []const u8) Error!usize {
        const self: *FakeTerminal = @ptrCast(@alignCast(ptr));
        try self.written.append(self.gpa, bytes);
        return bytes.len;
    }

    fn fakeResize(ptr: *anyopaque, size: WindowSize) Error!void {
        const self: *FakeTerminal = @ptrCast(@alignCast(ptr));
        self.resized = size;
    }

    fn fakeKill(ptr: *anyopaque, signal: Signal) Error!void {
        const self: *FakeTerminal = @ptrCast(@alignCast(ptr));
        self.signalled = signal;
    }

    fn fakeTakeBytes(ptr: *anyopaque, dest: []u8) usize {
        const self: *FakeTerminal = @ptrCast(@alignCast(ptr));
        const count = @min(dest.len, self.pending.len);
        @memcpy(dest[0..count], self.pending[0..count]);
        self.pending = self.pending[count..];
        return count;
    }

    fn fakeState(ptr: *anyopaque) ChildState {
        const self: *FakeTerminal = @ptrCast(@alignCast(ptr));
        return self.end;
    }

    fn fakeWaitReadable(_: *anyopaque, _: u32) bool {
        return false;
    }

    fn fakeDestroy(ptr: *anyopaque) void {
        const self: *FakeTerminal = @ptrCast(@alignCast(ptr));
        self.destroyed = true;
        self.written.deinit(self.gpa);
    }
};

test "a backend that is not POSIX implements the whole interface" {
    const gpa = testing.allocator;
    var backend = FakeTerminal{ .gpa = gpa, .pending = "hello", .end = .{ .exited = .{ .code = 7 } } };
    const pty = backend.asPty();

    // Each call lands in the backend, in the order the interface documents.
    try testing.expectEqual(@as(usize, 3), try pty.write("abc"));
    try pty.resize(WindowSize.init(30, 100));
    try pty.kill(.interrupt);

    var buffer: [8]u8 = undefined;
    const handed_over = pty.takeBytes(&buffer);
    try testing.expectEqual(@as(usize, 5), handed_over);
    try testing.expectEqualStrings("hello", buffer[0..handed_over]);
    // Bytes are handed over exactly once.
    try testing.expectEqual(@as(usize, 0), pty.takeBytes(&buffer));

    try testing.expectEqual(ChildState{ .exited = .{ .code = 7 } }, pty.state());
    try testing.expect(!pty.waitReadable(0));

    // What the interface asked for, read back out of the backend before it is torn down.
    try testing.expectEqual(@as(usize, 1), backend.written.items.len);
    try testing.expectEqualStrings("abc", backend.written.items[0]);
    try testing.expectEqual(@as(?WindowSize, WindowSize.init(30, 100)), backend.resized);
    try testing.expectEqual(@as(?Signal, .interrupt), backend.signalled);

    pty.destroy();
    try testing.expect(backend.destroyed);
}

test "a request the OS would only fail on later is refused before anything is created" {
    // The POSIX backend's checks; the ConPTY backend's are the "Windows backend" test below.
    if (!has_posix_backend) return error.SkipZigTest;
    const gpa = testing.allocator;

    try testing.expectError(
        error.EmptyArgv,
        spawnPosix(gpa, .{ .argv = &.{}, .env = &test_env, .cwd = test_cwd, .size = WindowSize.init(24, 80) }),
    );
    try testing.expectError(
        error.EmptyArgv,
        spawnPosix(gpa, .{ .argv = &.{""}, .env = &test_env, .cwd = test_cwd, .size = WindowSize.init(24, 80) }),
    );

    // execve would truncate at the NUL and run a different program than the one named.
    var argument = [_][]const u8{"sh"};
    argument[0] = "sh\x00-c";
    try testing.expectError(error.EmbeddedNul, spawnPosix(gpa, .{
        .argv = &argument,
        .env = &test_env,
        .cwd = test_cwd,
        .size = WindowSize.init(24, 80),
    }));

    // An environment entry without `=` is not an environment entry.
    try testing.expectError(error.InvalidEnvironmentEntry, spawnPosix(gpa, .{
        .argv = &.{"sh"},
        .env = &.{"NOT_AN_ENTRY"},
        .cwd = test_cwd,
        .size = WindowSize.init(24, 80),
    }));

    // A request that is well formed but names nothing: it fails at the PATH search, after the
    // checks above have already passed.
    try testing.expectError(
        error.ProgramNotFound,
        spawnPosix(gpa, shellRequest(&.{"conduit-no-such-program"})),
    );
}

test "a program named by a path is used exactly as it stands" {
    if (!has_posix_backend) return error.SkipZigTest;
    const gpa = testing.allocator;

    // The whole allocation comes back, NUL byte included, because the caller frees the whole slice.
    const resolved = try resolveProgram(gpa, "/bin/sh", "/nowhere");
    defer gpa.free(resolved);
    try testing.expectEqualStrings("/bin/sh\x00", resolved);
}

test "a program named without a path is looked up on the PATH the child was given" {
    if (!has_posix_backend) return error.SkipZigTest;
    const gpa = testing.allocator;

    // A directory that does not exist is skipped, and the child's PATH is the only one consulted:
    // Conduit's own environment must not leak into a spawn (P7).
    const resolved = try resolveProgram(gpa, "sh", "/nowhere:/bin:/usr/bin");
    defer gpa.free(resolved);
    try testing.expectEqualStrings("/bin/sh\x00", resolved);
}

test "a program on no PATH is reported instead of becoming a child that dies at 127" {
    if (!has_posix_backend) return error.SkipZigTest;
    const gpa = testing.allocator;

    try testing.expectError(
        error.ProgramNotFound,
        resolveProgram(gpa, "conduit-no-such-program", "/bin:/usr/bin"),
    );
    // An absent PATH is a request with no answer, not an implicit "search my own PATH".
    try testing.expectError(error.ProgramNotFound, resolveProgram(gpa, "sh", ""));
    try testing.expectError(error.ProgramNotFound, resolveProgram(gpa, "sh", null));
}

test "the environment value the PATH search reads is the child's, not Conduit's" {
    try testing.expectEqualStrings("/usr/bin", envValue(&.{ "TERM=x", "PATH=/usr/bin" }, "PATH").?);
    try testing.expectEqualStrings("", envValue(&.{"PATH="}, "PATH").?);
    try testing.expectEqual(@as(?[]const u8, null), envValue(&.{"TERM=x"}, "PATH"));
    // A key that is only a prefix of the name is not a match.
    try testing.expectEqual(@as(?[]const u8, null), envValue(&.{"PAT=/bin"}, "PATH"));
}

test "a wait status decodes into an end Conduit can name" {
    try testing.expectEqual(ExitStatus{ .code = 0 }, decodeExitStatus(0));
    try testing.expectEqual(ExitStatus{ .code = 42 }, decodeExitStatus(42 << 8));
    try testing.expectEqual(ExitStatus{ .code = 255 }, decodeExitStatus(0xff << 8));

    try testing.expectEqual(ExitStatus{ .signal = .hangup }, decodeExitStatus(1));
    try testing.expectEqual(ExitStatus{ .signal = .interrupt }, decodeExitStatus(2));
    try testing.expectEqual(ExitStatus{ .signal = .kill }, decodeExitStatus(9));
    try testing.expectEqual(ExitStatus{ .signal = .terminate }, decodeExitStatus(15));

    // A signal outside the vocabulary, and a stopped child, are reported as unknown rather than
    // turned into a status nobody observed.
    try testing.expectEqual(ExitStatus.unknown, decodeExitStatus(11));
    try testing.expectEqual(ExitStatus.unknown, decodeExitStatus((3 << 8) | 0x7f));
}

test "the byte ring hands out exactly what went in, in order, across its end" {
    const gpa = testing.allocator;
    var ring = try ByteRing.create(gpa, 8);
    defer ring.destroy(gpa);

    try testing.expectEqual(@as(usize, 0), ring.len());
    try testing.expectEqual(@as(usize, 8), ring.append("abcdefgh"));
    // A full ring takes nothing: the caller waits for room rather than losing bytes.
    try testing.expectEqual(@as(usize, 0), ring.append("i"));
    try testing.expectEqual(@as(usize, 8), ring.len());

    var out: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), ring.take(out[0..4]));
    try testing.expectEqualStrings("abcd", out[0..4]);

    // Four bytes went out and eight came in: the four that fitted went to the end of the buffer,
    // and reading wraps back around to the start.
    try testing.expectEqual(@as(usize, 4), ring.append("ijklmnop"));
    try testing.expectEqual(@as(usize, 8), ring.take(&out));
    try testing.expectEqualStrings("efghijkl", &out);
    try testing.expectEqual(@as(usize, 0), ring.len());
}

/// The environment every integration test hands a child: fixed, minimal, and nothing from the
/// developer's own shell, so what a test reads back cannot vary with the machine.
const test_env = [_][]const u8{
    "PATH=/usr/bin:/bin",
    "HOME=/tmp",
    "TERM=xterm-256color",
    "LANG=C",
};

/// The directory a test's child starts in. Fixed, so no test depends on where it was run from.
const test_cwd = "/";

/// A shell that reads commands from the terminal and nothing else. `-s` reads stdin without making
/// the shell interactive, so no profile, no prompt and no dotfile of the developer's can appear in
/// what a test reads back.
const shell_argv = [_][]const u8{ "/bin/sh", "-s" };

/// How long a test waits for a terminal to say something before calling it a failure. Windows gets
/// longer: a cold Windows PowerShell on a hosted runner takes several seconds to print anything.
const test_timeout_ms = if (builtin.os.tag == .windows) 30_000 else 5_000;

/// How long one wait lasts. Short enough that a failure is reported promptly, long enough that a
/// loaded machine does not lose a race with its own process.
const test_step_ms = 25;

/// When a wait's budget runs out, on the same monotonic clock the terminal itself waits on.
fn testDeadline() u64 {
    return monotonicMillis() + test_timeout_ms;
}

/// How long the next wait may last: `null` once the budget is spent, and otherwise a single step
/// capped by what is left, so a long budget still answers a stop or an exit long before it ends.
fn timeLeft(deadline: u64) ?u32 {
    const now = monotonicMillis();
    if (now >= deadline) return null;
    return @intCast(@min(deadline - now, test_step_ms));
}

fn shellRequest(argv: []const []const u8) SpawnRequest {
    return .{ .argv = argv, .env = &test_env, .cwd = test_cwd, .size = WindowSize.init(24, 80) };
}

/// Collect what a terminal produces until `marker` appears in it, or the budget runs out.
///
/// This is the deterministic shape the testing standards ask for: it waits on a condition with a
/// deadline, and it never sleeps. The budget is that deadline and not a number of waits, because
/// `waitReadable` comes back at once whenever a byte is already pending — a counted budget would be
/// spent in a millisecond and this would report an empty read for a terminal about to speak.
fn readUntil(gpa: Allocator, pty: Pty, marker: []const u8) ![]u8 {
    var collected: std.ArrayList(u8) = .empty;
    errdefer collected.deinit(gpa);

    var buffer: [1024]u8 = undefined;
    const deadline = testDeadline();
    while (true) {
        const count = pty.takeBytes(&buffer);
        if (count != 0) try collected.appendSlice(gpa, buffer[0..count]);
        if (std.mem.indexOf(u8, collected.items, marker) != null) break;
        _ = pty.waitReadable(timeLeft(deadline) orelse break);
    }
    return collected.toOwnedSlice(gpa);
}

/// Wait until a terminal has nothing more to say for one step, and return everything it said.
///
/// A shell that starts reading a terminal greets it first — a prompt, or nothing at all — so a test
/// about an *idle* terminal has to let that greeting arrive before it can mean anything by quiet.
fn quiesce(gpa: Allocator, pty: Pty) ![]u8 {
    var collected: std.ArrayList(u8) = .empty;
    errdefer collected.deinit(gpa);

    var buffer: [256]u8 = undefined;
    const deadline = testDeadline();
    var drained: usize = 0;
    while (true) {
        const count = pty.takeBytes(&buffer);
        if (count != 0) {
            try collected.appendSlice(gpa, buffer[0..count]);
            drained += 1;
            continue;
        }
        // Quiet for a whole step: this terminal has said all it is going to say.
        if (drained != 0) break;
        _ = pty.waitReadable(timeLeft(deadline) orelse break);
    }
    return collected.toOwnedSlice(gpa);
}

/// Wait for a child to end, and report how it ended.
///
/// The budget is a deadline, not a count of waits. `waitReadable` answers the wider question the
/// interface asks — "are bytes or an exit pending" — so a byte the owner has not taken makes it
/// return at once, and a counted budget would be spent in a millisecond while the child was still
/// seconds from being collected.
fn waitForExit(pty: Pty) !ChildState {
    const deadline = testDeadline();
    while (true) {
        switch (pty.state()) {
            .running => {},
            .exited => |status| return .{ .exited = status },
        }
        _ = pty.waitReadable(timeLeft(deadline) orelse return error.TimedOut);
    }
}

/// Write every byte of `bytes`, looping over the short writes the interface allows.
fn writeAll(pty: Pty, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        written += try pty.write(bytes[written..]);
    }
}

fn trimEndOfLine(bytes: []const u8) []const u8 {
    return std.mem.trimEnd(u8, bytes, "\r\n");
}

test "a spawned shell runs what the owner writes, and its output arrives off the read thread" {
    if (!has_posix_backend) return error.SkipZigTest;
    const gpa = testing.allocator;
    const pty = try spawnPosix(gpa, shellRequest(&shell_argv));
    defer pty.destroy();

    // A shell greets its terminal on its own schedule, and whatever it writes goes into the same
    // output stream as the terminal's echo of what the owner typed. Left to race, a two-byte
    // greeting lands in the middle of the echoed line below and splits the text this test reads.
    // Letting the terminal fall quiet first means the greeting is already delivered and nothing else
    // is written until the shell answers, so the echo arrives as one run.
    const greeting = try quiesce(gpa, pty);
    defer gpa.free(greeting);

    // The marker is assembled by the shell rather than typed literally, so the only place it can
    // appear is the shell's own output and not the line the terminal echoes back.
    try writeAll(pty, "printf 'conduit-pty-%s\\n' marker\n");

    const output = try readUntil(gpa, pty, "conduit-pty-marker\r\n");
    defer gpa.free(output);

    // Both halves of the round trip are here: what the terminal's line discipline echoed back, and
    // what the shell printed in answer.
    try testing.expect(std.mem.indexOf(u8, output, "printf 'conduit-pty-%s") != null);
    try testing.expect(std.mem.indexOf(u8, output, "conduit-pty-marker\r\n") != null);
}

test "a resize reaches the child, and the shell reports the size it was given" {
    if (!has_posix_backend) return error.SkipZigTest;
    const gpa = testing.allocator;
    const pty = try spawnPosix(gpa, shellRequest(&shell_argv));
    defer pty.destroy();

    // The size the terminal started at.
    try writeAll(pty, "stty size\n");
    const at_start = try readUntil(gpa, pty, "24 80");
    defer gpa.free(at_start);

    // Then a resize, and the same question asked again of the same terminal.
    try pty.resize(WindowSize.init(40, 100));
    try writeAll(pty, "stty size\n");
    const after_resize = try readUntil(gpa, pty, "40 100");
    defer gpa.free(after_resize);

    // A resize to nothing is still a terminal: it keeps one row and one column.
    try pty.resize(WindowSize.init(0, 0));
    try writeAll(pty, "stty size\n");
    const collapsed = try readUntil(gpa, pty, "1 1");
    defer gpa.free(collapsed);
}

test "a child that exits is reported with the status it exited with" {
    if (!has_posix_backend) return error.SkipZigTest;
    const gpa = testing.allocator;
    const pty = try spawnPosix(gpa, shellRequest(&.{ "/bin/sh", "-c", "exit 42" }));
    defer pty.destroy();

    try testing.expectEqual(ChildState{ .exited = .{ .code = 42 } }, try waitForExit(pty));

    // The terminal is finished. What the OS does with input sent to a terminal whose child has gone
    // is its own business, but Conduit must neither block on it nor crash on it.
    if (pty.write("anything")) |written| {
        try testing.expectEqual(@as(usize, 8), written);
    } else |err| {
        try testing.expectEqual(error.Closed, err);
    }
}

test "killing a child is reported as the signal that ended it" {
    if (!has_posix_backend) return error.SkipZigTest;
    const gpa = testing.allocator;
    const pty = try spawnPosix(gpa, shellRequest(&shell_argv));
    defer pty.destroy();

    // The shell is blocked reading the terminal, so nothing else can end it.
    try pty.kill(.kill);
    try testing.expectEqual(ChildState{ .exited = .{ .signal = .kill } }, try waitForExit(pty));

    // The child is collected now, so its process id is not Conduit's to signal again.
    try testing.expectError(error.Closed, pty.kill(.hangup));
}

test "a reader waiting for room is woken even when the owner empties the ring and waits first" {
    if (!has_posix_backend) return error.SkipZigTest;
    const gpa = testing.allocator;
    // Far more than the ring holds, so the reader keeps finding it full.
    const total = 1024 * 1024;
    const pty = try spawnPosix(gpa, shellRequest(&.{ "/bin/sh", "-c", "head -c 1048576 /dev/zero" }));
    defer pty.destroy();
    const posix: *PosixPty = @ptrCast(@alignCast(pty.ptr));

    var buffer: [16 * 1024]u8 = undefined;
    var consumed: usize = 0;
    // Each round is the interleaving that once froze a session: the reader has found the ring
    // full and is about to wait for room; the owner takes every byte, then waits for more output
    // the way an idle event loop does — draining its wakeups — before the reader waits.
    for (0..4) |_| {
        posix.park.word.store(ReaderPark.armed, .release);
        const park_deadline = sys.monotonicMillis() + 5000;
        while (posix.park.word.load(.acquire) != ReaderPark.parked) {
            if (sys.monotonicMillis() > park_deadline) return error.TimedOut;
            // A reader that found the ring full *before* the park was armed is waiting for
            // room, not parked, and nothing else wakes it. A spurious wake makes it try the
            // append again, fail again and, now that the park is armed, park. No byte is
            // taken, so the ring is exactly full when the check below runs.
            if (posix.queue.len() == PosixPty.queue_capacity) PosixPty.notify(posix.reader_wake);
            std.Thread.yield() catch {
                // Yielding only shortens the spin; a failed yield still waits correctly.
            };
        }
        try testing.expectEqual(@as(usize, PosixPty.queue_capacity), posix.queue.len());
        while (true) {
            const count = pty.takeBytes(&buffer);
            if (count == 0) break;
            consumed += count;
        }
        // The owner's own wait: nothing is pending, so it consumes whatever wakeups it sees.
        try testing.expect(!pty.waitReadable(5));
        posix.park.word.store(ReaderPark.released, .release);
        // The reader was told there is room before it waited, so it must refill the ring.
        try testing.expect(pty.waitReadable(2000));
    }

    // And the terminal still runs to completion.
    const deadline = testDeadline();
    while (pty.state() == .running or posix.queue.len() != 0) {
        const count = pty.takeBytes(&buffer);
        consumed += count;
        if (count == 0) _ = pty.waitReadable(timeLeft(deadline) orelse return error.TimedOut);
    }
    try testing.expectEqual(ChildState{ .exited = .{ .code = 0 } }, pty.state());
    try testing.expectEqual(@as(usize, total), consumed);
}

test "starting and destroying a terminal leaks no descriptor and leaves no child" {
    if (!has_posix_backend) return error.SkipZigTest;
    const gpa = testing.allocator;

    const before = try sys.countOpenDescriptors();
    for (0..5) |_| {
        const pty = try spawnPosix(gpa, shellRequest(&.{ "/bin/sh", "-c", "exit 0" }));

        // Measured, not assumed: a live terminal holds exactly the descriptors it says it does.
        try testing.expectEqual(before + PosixPty.descriptor_count, try sys.countOpenDescriptors());

        // The exit status is only ever reported by a wait, so this is also proof the child was
        // collected rather than left behind as a process.
        try testing.expectEqual(ChildState{ .exited = .{ .code = 0 } }, try waitForExit(pty));
        pty.destroy();
    }
    try testing.expectEqual(before, try sys.countOpenDescriptors());
}

test "the child starts in the directory its request asked for" {
    if (!has_posix_backend) return error.SkipZigTest;
    const gpa = testing.allocator;
    const pty = try spawnPosix(gpa, shellRequest(&.{ "/bin/sh", "-c", "pwd" }));
    defer pty.destroy();

    const output = try readUntil(gpa, pty, "\r\n");
    defer gpa.free(output);

    // "/" and not the directory this test happens to be run from.
    try testing.expectEqualStrings("/", trimEndOfLine(output));
}

test "the child gets the environment its request carried, and not Conduit's own" {
    if (!has_posix_backend) return error.SkipZigTest;
    const gpa = testing.allocator;

    var env: [test_env.len + 1][]const u8 = undefined;
    @memcpy(env[0..test_env.len], &test_env);
    env[test_env.len] = "CONDUIT_TEST_MARKER=from-the-request";

    const pty = try spawnPosix(gpa, .{
        .argv = &.{ "/bin/sh", "-c", "echo \"$CONDUIT_TEST_MARKER\"" },
        .env = &env,
        .cwd = test_cwd,
        .size = WindowSize.init(24, 80),
    });
    defer pty.destroy();

    const output = try readUntil(gpa, pty, "\r\n");
    defer gpa.free(output);
    try testing.expectEqualStrings("from-the-request", trimEndOfLine(output));
}

test "waiting on an idle terminal gives up when its deadline passes" {
    if (!has_posix_backend) return error.SkipZigTest;
    const gpa = testing.allocator;
    const pty = try spawnPosix(gpa, shellRequest(&shell_argv));
    defer pty.destroy();

    // Nothing has been written and the shell has nothing to say, so this is the whole contract of
    // `waitReadable`: it comes back, it does not wait for something that may never arrive.
    const greeting = try quiesce(gpa, pty);
    defer gpa.free(greeting);

    // With the greeting taken, nothing arrives while the owner waits.
    try testing.expect(!pty.waitReadable(test_step_ms));
    try testing.expect(pty.state() == .running);
}

test "spawn refuses a nameless request whichever backend this build has" {
    // Backend selection, proved rather than read off the source: both backends check the request
    // before they touch the OS, so the error `spawn` reports for a request with no program is the
    // chosen backend's own. Naming `spawn` here is also what makes this file check that it, and
    // whichever backend it selects for this target, compiles.
    const gpa = testing.allocator;
    try testing.expectError(error.EmptyArgv, spawn(gpa, .{
        .argv = &.{},
        .env = &test_env,
        .cwd = test_cwd,
        .size = WindowSize.init(24, 80),
    }));
}

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

// Every test in this section needs a real Windows runtime, and none of them can pass anywhere
// else: a pseudoconsole is an object Windows creates, so there is nothing on Linux for a child to
// be attached to, and nothing here that could stand in for it without inventing the evidence. They
// skip off Windows rather than passing without it; on a `windows-latest` runner `zig build test`
// runs them for real. No test in this section has ever been executed by the machine that wrote it,
// which is what the report on this task says out loud.

/// The environment every Windows integration test hands a child: fixed, minimal, and nothing from
/// the runner's own configuration, so what a test reads back cannot vary with the machine.
const windows_test_env = [_][]const u8{
    "PATH=C:\\Windows\\System32;C:\\Windows;C:\\Windows\\System32\\WindowsPowerShell\\v1.0",
    "PATHEXT=.COM;.EXE;.BAT;.CMD",
    "SYSTEMROOT=C:\\Windows",
    "TEMP=C:\\Windows\\Temp",
    "ComSpec=C:\\Windows\\System32\\cmd.exe",
    "PROMPT=$G",
};

/// The directory a Windows test's child starts in. A directory every Windows install has, so no
/// test depends on where the runner checked the tree out.
const windows_test_cwd = "C:\\Windows";

/// A shell that reads commands from the terminal and nothing else. `/Q` keeps the startup banner
/// out of the output stream, so what a test reads back is only what it asked the shell to do.
const windows_shell_argv = [_][]const u8{ "cmd.exe", "/Q" };

fn windowsRequest(argv: []const []const u8) SpawnRequest {
    return .{
        .argv = argv,
        .env = &windows_test_env,
        .cwd = windows_test_cwd,
        .size = WindowSize.init(24, 80),
    };
}

var diag_use_std_handles = true;

fn diagReader(handle: win.HANDLE, out: *std.ArrayList(u8)) void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        var got: win.DWORD = 0;
        if (win.ReadFile(handle, &buffer, buffer.len, &got, null) == .FALSE) {
            log.warn("DIAG sync read ended: {s}", .{@tagName(win.lastError())});
            return;
        }
        if (got == 0) {
            log.warn("DIAG sync read: zero bytes", .{});
            return;
        }
        out.appendSlice(std.heap.page_allocator, buffer[0..got]) catch return;
    }
}

fn diagRun(gpa: Allocator, use_std_handles: bool, named_output: bool) !void {
    diag_use_std_handles = use_std_handles;
    defer diag_use_std_handles = true;
    var prepared = try WindowsRequest.init(gpa, windowsRequest(&.{ "cmd.exe", "/Q", "/C", "echo diag-hello& exit 42" }));
    defer prepared.deinit(gpa);
    var input = try win.createInputPipe();
    defer input.close();
    var output: WindowsPipe = .{};
    if (named_output) {
        output = try win.createOutputPipe();
    } else if (win.CreatePipe(&output.conduit, &output.conpty, null, 0) == .FALSE) return error.SystemError;
    defer output.close();
    const console = try win.createPseudoConsole(WindowSize.init(24, 80), input.conpty, output.conpty);
    input.closeConPtyEnd();
    output.closeConPtyEnd();
    var child = try win.createProcess(gpa, prepared, console);
    defer child.close();
    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(std.heap.page_allocator);
    var thread: ?std.Thread = null;
    if (!named_output) thread = try std.Thread.spawn(.{}, diagReader, .{ output.conduit, &collected });
    var handles = [1]win.HANDLE{child.handle};
    const waited = win.waitOn(&handles, 5000);
    var code: u32 = 0;
    _ = win.getExitCodeProcess(child.handle, &code);
    log.warn("DIAG std_handles={} named={} wait={d} exit=0x{X}", .{ use_std_handles, named_output, waited, code });
    win.closePseudoConsole(console);
    if (thread) |t| t.join();
    log.warn("DIAG output: {f}", .{std.zig.fmtString(collected.items[0..@min(collected.items.len, 600)])});
}

test "DIAG conpty variations" {
    if (!has_conpty_backend) return error.SkipZigTest;
    const gpa = testing.allocator;
    diagRun(gpa, true, false) catch |err| log.warn("DIAG run failed: {s}", .{@errorName(err)});
    diagRun(gpa, false, false) catch |err| log.warn("DIAG run failed: {s}", .{@errorName(err)});
}

test "a request the Windows backend could not run is refused before anything is created" {
    if (!has_conpty_backend) return error.SkipZigTest;
    const gpa = testing.allocator;

    try testing.expectError(
        error.EmptyArgv,
        spawnConPty(gpa, .{
            .argv = &.{},
            .env = &windows_test_env,
            .cwd = windows_test_cwd,
            .size = WindowSize.init(24, 80),
        }),
    );
    // A program that is on no PATH the request carries is an error the caller sees, rather than a
    // child that dies at once with nothing to explain it.
    try testing.expectError(
        error.ProgramNotFound,
        spawnConPty(gpa, windowsRequest(&.{"conduit-no-such-program"})),
    );
    // Every string reaches `CreateProcessW` as UTF-16, so bytes that are not text cannot be passed
    // on: a program started with a mangled argument is worse than a spawn that did not happen.
    try testing.expectError(error.InvalidUtf8, spawnConPty(gpa, .{
        .argv = &.{"\xff\xfe"},
        .env = &windows_test_env,
        .cwd = windows_test_cwd,
        .size = WindowSize.init(24, 80),
    }));
}

test "a Windows program is looked up on the request's own PATH, through PATHEXT" {
    if (!has_conpty_backend) return error.SkipZigTest;
    const gpa = testing.allocator;

    // `cmd` is not a file on disk and `cmd.exe` is: Windows resolves a bare name through PATHEXT,
    // so the PATH search Conduit does before Windows ever sees the request has to as well.
    const resolved = try resolveWindowsProgram(gpa, "cmd", "C:\\nowhere;C:\\Windows\\System32", ".EXE");
    defer gpa.free(resolved);
    const as_utf8 = try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.sliceTo(resolved, 0));
    defer gpa.free(as_utf8);
    // The extension is spelled the way PATHEXT spells it (`.EXE`); Windows paths ignore case.
    if (!std.ascii.eqlIgnoreCase("C:\\Windows\\System32\\cmd.exe", as_utf8)) {
        try testing.expectEqualStrings("C:\\Windows\\System32\\cmd.exe", as_utf8);
    }

    // A program on no PATH the request carries is not found, and Conduit's own PATH is never
    // consulted: a spawn belongs to an ExecutionContext (P7).
    try testing.expectError(
        error.ProgramNotFound,
        resolveWindowsProgram(gpa, "cmd", "C:\\nowhere", null),
    );
    try testing.expectError(
        error.ProgramNotFound,
        resolveWindowsProgram(gpa, "conduit-no-such-program", "C:\\Windows\\System32", ".EXE"),
    );
}

test "a Windows terminal runs what the owner writes, through the pseudoconsole" {
    // TASK-16's first acceptance criterion. It needs a Windows runtime: there is no pseudoconsole
    // on this machine for a child to be attached to, so the test says so rather than passing
    // without proof.
    if (!has_conpty_backend) return error.SkipZigTest;
    const gpa = testing.allocator;
    const pty = try spawnConPty(gpa, windowsRequest(&windows_shell_argv));
    defer pty.destroy();

    // The marker is assembled by the shell rather than typed literally, so the only place it can
    // appear is the shell's own output and not the line the terminal echoes back. Enter is a
    // carriage return, which is what a terminal sends for it; a line feed is a different key.
    try writeAll(pty, "set conduit=marker\recho conduit-pty-%conduit%\r");
    const output = try readUntil(gpa, pty, "conduit-pty-marker");
    defer gpa.free(output);
    log.warn("DIAG round trip: {f}", .{std.zig.fmtString(output[0..@min(output.len, 1500)])});

    // Both halves of the round trip: the terminal's echo of what the owner wrote, which still
    // carries the unexpanded variable, and the line the shell printed in answer.
    try testing.expect(std.mem.indexOf(u8, output, "echo conduit-pty-%conduit%") != null);
    try testing.expect(std.mem.indexOf(u8, output, "conduit-pty-marker") != null);
    // A pseudoconsole ends its lines with CRLF. A byte stream without them is not a terminal.
    try testing.expect(std.mem.indexOf(u8, output, "\r\n") != null);
}

test "a resize reaches the Windows pseudoconsole and the child is told the new size" {
    // TASK-16's second acceptance criterion, and it needs a Windows runtime for the same reason.
    if (!has_conpty_backend) return error.SkipZigTest;
    const gpa = testing.allocator;

    // A program in the terminal asks the console how large it is, once for every line it is
    // given, which is the only way to see the pseudoconsole's own size rather than Conduit's
    // belief about it. Enter alone types nothing, so the size can only appear as the program's
    // own output.
    const ask = [_][]const u8{
        "powershell.exe",
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        "while ($null -ne [Console]::In.ReadLine()) { 'size=' + [Console]::WindowWidth + 'x' + [Console]::WindowHeight }",
    };
    const pty = try spawnConPty(gpa, windowsRequest(&ask));
    defer pty.destroy();

    // The size the terminal started at: 24 rows by 80 columns.
    try writeAll(pty, "\r");
    const at_start = try readUntil(gpa, pty, "size=80x24");
    defer gpa.free(at_start);

    try pty.resize(WindowSize.init(40, 100));

    // The resize and the next line reach the pseudoconsole through different pipes, so a line
    // typed at once may be answered before the new size is in place: ask again, at a bounded
    // pace, until the answer is the new size or the deadline passes.
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(gpa);
    var buffer: [1024]u8 = undefined;
    const deadline = testDeadline();
    var next_ask: u64 = 0;
    while (std.mem.indexOf(u8, seen.items, "size=100x40") == null) {
        const now = monotonicMillis();
        if (now >= deadline) return error.TimedOut;
        if (now >= next_ask) {
            try writeAll(pty, "\r");
            next_ask = now + 500;
        }
        const count = pty.takeBytes(&buffer);
        if (count != 0) {
            try seen.appendSlice(gpa, buffer[0..count]);
            continue;
        }
        _ = pty.waitReadable(timeLeft(deadline) orelse return error.TimedOut);
    }
}

test "a Windows child that exits is reported with the code it exited with" {
    // TASK-16's third acceptance criterion: the exit is detected and the terminal released, which
    // needs a Windows runtime.
    if (!has_conpty_backend) return error.SkipZigTest;
    const gpa = testing.allocator;
    const pty = try spawnConPty(gpa, windowsRequest(&.{ "cmd.exe", "/Q", "/C", "exit 42" }));
    defer pty.destroy();

    try testing.expectEqual(ChildState{ .exited = .{ .code = 42 } }, try waitForExit(pty));
}

test "a Windows child's last output arrives before its end is reported" {
    // The end is published only after the pseudoconsole has been closed and its output drained,
    // so a program's final line is never lost to the race between its exit and its last frame.
    if (!has_conpty_backend) return error.SkipZigTest;
    const gpa = testing.allocator;
    const pty = try spawnConPty(gpa, windowsRequest(&.{ "cmd.exe", "/Q", "/C", "echo conduit-last-words& exit 7" }));
    defer pty.destroy();

    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(gpa);
    var buffer: [1024]u8 = undefined;
    const deadline = testDeadline();
    const end = while (true) {
        // The end is read before the ring, so bytes published ahead of it are always collected.
        const state = pty.state();
        const count = pty.takeBytes(&buffer);
        if (count != 0) {
            try collected.appendSlice(gpa, buffer[0..count]);
            continue;
        }
        switch (state) {
            .running => {},
            .exited => break state,
        }
        _ = pty.waitReadable(timeLeft(deadline) orelse return error.TimedOut);
    };
    try testing.expectEqual(ChildState{ .exited = .{ .code = 7 } }, end);
    try testing.expect(std.mem.indexOf(u8, collected.items, "conduit-last-words") != null);
}

test "ending a Windows child is reported, and a collected child is not ended again" {
    if (!has_conpty_backend) return error.SkipZigTest;
    const gpa = testing.allocator;
    const pty = try spawnConPty(gpa, windowsRequest(&windows_shell_argv));
    defer pty.destroy();

    // Windows reports a child's end as a number and never as a signal, so this asserts the number
    // Conduit ended the child with.
    try pty.kill(.kill);
    try testing.expectEqual(
        ChildState{ .exited = .{ .code = terminationCode(.kill) } },
        try waitForExit(pty),
    );
    // The child is collected now, so its process object is not Conduit's to end again.
    try testing.expectError(error.Closed, pty.kill(.hangup));
}

test "starting and destroying a Windows terminal releases every handle it took" {
    if (!has_conpty_backend) return error.SkipZigTest;
    const gpa = testing.allocator;

    // Measured, not assumed: `GetProcessHandleCount` counts what this process actually holds,
    // including the handles a pseudoconsole keeps inside itself, which no Conduit field names.
    // The first terminal is a warm-up, because the first use of these APIs loads modules and
    // starts system threads that keep handles for the life of the process; every terminal after
    // it must give back exactly what it took.
    const warm_up = try spawnConPty(gpa, windowsRequest(&.{ "cmd.exe", "/Q", "/C", "exit 0" }));
    _ = try waitForExit(warm_up);
    warm_up.destroy();

    const before = try win.processHandleCount();
    for (0..5) |_| {
        const pty = try spawnConPty(gpa, windowsRequest(&.{ "cmd.exe", "/Q", "/C", "exit 0" }));
        // A live terminal holds its child, both pipe ends, four events and two threads at least.
        try testing.expect(try win.processHandleCount() >= before + 9);
        // The exit code is only ever reported by a wait, so this is also proof the child was
        // collected rather than left behind as a process.
        try testing.expectEqual(ChildState{ .exited = .{ .code = 0 } }, try waitForExit(pty));
        pty.destroy();
    }
    try testing.expectEqual(before, try win.processHandleCount());
}
