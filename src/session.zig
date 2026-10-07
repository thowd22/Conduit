//! One live terminal, and nothing above it.
//!
//! `session` owns the identity and the lifecycle of a single live terminal: the
//! PTY and the terminal state behind it (CONDUIT.md §13, `docs/architecture.md`
//! §2). Hiding a tab, a pane or the scratchpad never stops it — hiding is never
//! termination (P8, invariant 6), so a session leaves `running` only when
//! something explicitly closes it. A session never spawns: `workspace` uses
//! its ExecutionContext and transfers the resulting PTY through `attachChild`
//! (P7). A session never owns layout or knows about workspaces, agents or UI.
//!
//! It may depend on `config`, `pty`, `term` and `theme` (`build.zig`). The live
//! ownership edge to `pty` and `term` lands here: callers may borrow those
//! values, but only the session attaches or destroys them.
//!
//! Memory: `Session` owns one stable heap allocation for `term.Terminal`, made
//! with the allocator borrowed for its whole lifetime, plus fixed inline
//! storage for PTY response bytes a short write has not accepted yet. `std.Io`
//! is borrowed by the terminal for the same lifetime. An attached `pty.Pty`
//! transfers its backend ownership to the session until `deinit` destroys it.

const std = @import("std");
const pty = @import("pty");
const term = @import("term");

const Allocator = std.mem.Allocator;

/// Identity of one session, stable for the lifetime of the workspace that owns
/// it. Tabs, panes and the scratchpad hold sessions by this id.
///
/// Ids are one-based, so zero cannot name a session: the id type has no
/// "absent" value, and a caller that has no session yet has `null`, not a
/// `SessionId`.
///
/// Invariant: `ordinal` and `fromOrdinal` are inverses, and no id ever equals
/// zero.
pub const SessionId = enum(u32) {
    first = 1,
    _,

    /// The id for the `ordinal`-th session, counting from zero. Ordinals come
    /// from the owner's counter, never from a wire format.
    pub fn fromOrdinal(ordinal_: u32) SessionId {
        return @enumFromInt(ordinal_ + 1);
    }

    /// This session's zero-based ordinal.
    pub fn ordinal(self: SessionId) u32 {
        return @intFromEnum(self) - 1;
    }
};

/// One live terminal and, once attached, the one PTY behind it.
///
/// Ownership: `allocator` and `io` are borrowed and must outlive the session.
/// The terminal is allocated at a stable address because Ghostty's callbacks
/// retain the address passed to `term.Terminal.init`. `attachChild` transfers
/// ownership of a PTY on success. `deinit` releases the PTY before the terminal
/// and reports any failure to signal a still-running child after everything
/// has nevertheless been destroyed.
pub const Session = struct {
    /// Which owner this terminal belongs to.
    ///
    /// Scratchpads are separate from other human terminals because every
    /// workspace owns exactly one and agents may never target it. Agent
    /// terminals are separate from both human-owned kinds so later adapter
    /// code cannot accidentally treat one as an ordinary tab or pane.
    pub const Kind = enum {
        human_terminal,
        scratchpad,
        agent_terminal,
    };

    /// Failures from resizing terminal state or the attached PTY. Ghostty may
    /// reject dimensions it cannot represent with `error.InvalidValue`.
    pub const ResizeError = term.Terminal.Error || error{InvalidValue};

    /// What one nonblocking response flush accomplished.
    pub const FlushResult = struct {
        /// Bytes accepted by the child during this call.
        written: usize = 0,
        /// Bytes still retained either by this session or by the terminal.
        pending: usize = 0,

        /// Whether another flush is needed.
        pub fn hasPending(self: FlushResult) bool {
            return self.pending != 0;
        }
    };

    allocator: Allocator,
    kind_value: Kind,
    terminal_ptr: *term.Terminal,
    child_handle: ?pty.Pty,
    child_output_quiescent: bool,
    response_storage: [term.response_capacity]u8,
    response_offset: usize,
    response_len: usize,

    /// Allocate a terminal that will not move for the session's lifetime.
    pub fn init(
        io: std.Io,
        allocator: Allocator,
        kind_value: Kind,
        size: term.GridSize,
    ) term.Terminal.Error!Session {
        const terminal_ptr = try allocator.create(term.Terminal);
        errdefer allocator.destroy(terminal_ptr);
        try terminal_ptr.init(io, allocator, size);
        return .{
            .allocator = allocator,
            .kind_value = kind_value,
            .terminal_ptr = terminal_ptr,
            .child_handle = null,
            .child_output_quiescent = false,
            .response_storage = undefined,
            .response_offset = 0,
            .response_len = 0,
        };
    }

    /// Destroy the child and terminal in ownership order.
    ///
    /// A child is asked to hang up before its backend is destroyed. A failure
    /// to signal it is returned only after both the child handle and terminal
    /// storage have been released, so callers can report the error without
    /// having to choose between cleanup and observability. `error.Closed` is
    /// success: a normally exited child has already been collected.
    pub fn deinit(self: *Session) pty.Error!void {
        var signal_failure: ?pty.Error = null;
        if (self.child_handle) |child_pty| {
            child_pty.kill(.hangup) catch |err| switch (err) {
                error.Closed => {},
                else => signal_failure = err,
            };
            child_pty.destroy();
        }
        self.terminal_ptr.deinit(self.allocator);
        self.allocator.destroy(self.terminal_ptr);
        self.* = undefined;
        if (signal_failure) |err| return err;
    }

    /// Transfer one PTY into this session.
    ///
    /// On `error.ChildAlreadyAttached`, ownership remains with the caller.
    pub fn attachChild(self: *Session, child_pty: pty.Pty) error{ChildAlreadyAttached}!void {
        if (self.child_handle != null) return error.ChildAlreadyAttached;
        self.child_handle = child_pty;
        self.child_output_quiescent = false;
    }

    /// Tell an attached child the grid it is actually drawn in when that differs
    /// from `spawned`, the size its PTY was created with.
    ///
    /// A spawn is asynchronous, so the grid may change while the worker is still
    /// starting the child (a font reload, a window or divider resize). Without
    /// this the child keeps drawing for the old size until the next resize. When
    /// the sizes agree nothing is sent, so callers that pin exact resize counts
    /// see no extra traffic.
    pub fn syncChildSize(self: *Session, spawned: pty.WindowSize) pty.Error!void {
        const child_pty = self.child_handle orelse return;
        const current = pty.WindowSize.init(self.terminal_ptr.gridSize().rows, self.terminal_ptr.gridSize().cols);
        if (current.rows == spawned.rows and current.cols == spawned.cols) return;
        try child_pty.resize(current);
    }

    /// Which owner this terminal was created for.
    pub fn kind(self: *const Session) Kind {
        return self.kind_value;
    }

    /// Borrow the terminal on its owner thread.
    pub fn terminal(self: *const Session) *term.Terminal {
        return self.terminal_ptr;
    }

    /// Borrow the terminal without granting mutation through this accessor.
    pub fn terminalConst(self: *const Session) *const term.Terminal {
        return self.terminal_ptr;
    }

    /// Borrow the PTY handle, or return null before one has been attached.
    /// The backend allocation remains owned by this session.
    pub fn child(self: *const Session) ?pty.Pty {
        return self.child_handle;
    }

    /// Feed one bounded pass of currently queued child output into the terminal.
    ///
    /// At most `buffer.len` bytes are copied in a call. The operation neither
    /// blocks nor allocates; callers may repeat it to empty a queue larger than
    /// their buffer. This belongs to the session rather than a view so a
    /// workspace can keep hidden sessions current. With no attached child or
    /// an empty buffer it returns zero and changes nothing. A zero read records
    /// that an exited child's final queue has been observed empty, so
    /// `needsPump` can stop waking for that child — but only when the child
    /// was already seen exited before the take. The backend publishes the end
    /// after the reader's final enqueue, so an end observed first proves the
    /// empty queue is final; an end observed after an empty take may have
    /// arrived together with bytes queued in between, which must not be
    /// stranded.
    pub fn drainChildOutput(self: *Session, buffer: []u8) usize {
        const child_pty = self.child_handle orelse return 0;
        if (buffer.len == 0) return 0;
        const exited_before_take = child_pty.state() == .exited;
        const count = child_pty.takeBytes(buffer);
        if (count != 0) {
            self.child_output_quiescent = false;
            self.terminal_ptr.feed(buffer[0..count]);
        } else {
            self.child_output_quiescent = exited_before_take;
        }
        return count;
    }

    /// Whether this session needs another owner-thread service pass.
    ///
    /// A running child follows its nonblocking readiness signal. An exited
    /// child stays ready until a non-empty drain attempt observes that its
    /// final byte queue is empty; this prevents the last output from being
    /// stranded while also letting an idle event loop become quiescent after
    /// the child is gone. Replies owed to an attached child always request a
    /// pass. A childless session never does, even if its terminal was fed a
    /// query before attachment.
    pub fn needsPump(self: *Session) bool {
        const child_pty = self.child_handle orelse return false;
        if (self.pendingResponseBytes() != 0) return true;
        if (self.child_output_quiescent) return false;
        return child_pty.waitReadable(0);
    }

    /// Flush terminal-generated replies to the child without blocking or allocating.
    ///
    /// Bytes retained after an earlier short or zero write always go first.
    /// Only after that storage is empty are new replies copied from the
    /// terminal into `scratch`. Any new remainder is copied into the session's
    /// fixed response storage before this call returns, including when the
    /// backend reports an error. With no child, replies remain queued on the
    /// terminal; an empty scratch slice can still retry an older remainder.
    pub fn flushChildResponses(self: *Session, scratch: []u8) pty.Error!FlushResult {
        const child_pty = self.child_handle orelse return .{
            .pending = self.pendingResponseBytes(),
        };
        var result: FlushResult = .{};

        if (self.response_len != 0) {
            const retained = self.response_storage[self.response_offset..][0..self.response_len];
            const written = try child_pty.write(retained);
            if (written > retained.len) return error.SystemError;
            result.written += written;
            self.response_offset += written;
            self.response_len -= written;
            if (self.response_len != 0) {
                result.pending = self.pendingResponseBytes();
                return result;
            }
            self.response_offset = 0;
        }

        if (scratch.len != 0) {
            const count = self.terminal_ptr.takeResponses(scratch);
            if (count != 0) {
                const written = child_pty.write(scratch[0..count]) catch |err| {
                    @memcpy(self.response_storage[0..count], scratch[0..count]);
                    self.response_offset = 0;
                    self.response_len = count;
                    return err;
                };
                if (written > count) {
                    @memcpy(self.response_storage[0..count], scratch[0..count]);
                    self.response_offset = 0;
                    self.response_len = count;
                    return error.SystemError;
                }
                result.written += written;
                if (written != count) {
                    const remainder = scratch[written..count];
                    @memcpy(self.response_storage[0..remainder.len], remainder);
                    self.response_offset = 0;
                    self.response_len = remainder.len;
                }
            }
        }

        result.pending = self.pendingResponseBytes();
        return result;
    }

    /// Number of terminal-generated reply bytes still owed to the child.
    ///
    /// This includes both a remainder retained after a short write and bytes
    /// still queued by the terminal. Workspace polling uses the count only to
    /// decide whether another nonblocking pump is needed.
    pub fn pendingResponseBytes(self: *const Session) usize {
        return self.response_len + self.terminal_ptr.pendingResponses();
    }

    /// Resize the terminal and its child, when present, in the required order.
    pub fn resize(self: *Session, size: term.GridSize) ResizeError!void {
        if (self.child_handle) |child_pty| {
            try self.terminal_ptr.resizeChild(self.allocator, child_pty, size);
        } else {
            try self.terminal_ptr.resize(self.allocator, size);
        }
    }

    /// The validated working directory most recently reported with OSC 7.
    /// The returned slice borrows the terminal until its next feed.
    pub fn workingDirectory(self: *const Session) ?[]const u8 {
        return self.terminal_ptr.workingDirectory();
    }

    /// Whether OSC 133 says the cursor is currently at a shell prompt.
    pub fn cursorIsAtPrompt(self: *const Session) bool {
        return self.terminal_ptr.cursorIsAtPrompt();
    }

    /// Whether any prompt mark has been observed since init or reset.
    pub fn hasSeenPromptMarks(self: *const Session) bool {
        return self.terminal_ptr.hasSeenPromptMarks();
    }

    /// Copy retained prompt-start rows, oldest first, into caller storage.
    pub fn promptRows(self: *const Session, rows: []u32) usize {
        return self.terminal_ptr.promptRows(rows);
    }
};

/// Where a session is in its life: the PTY starts, runs, is asked to close,
/// and is gone. A session that has not been closed yet is always in `running`,
/// whatever view is showing it — visibility is `ui`'s state, not this module's
/// (P8, invariant 6).
///
/// Invariant: the only legal steps are `starting → running`, `running →
/// closing` and `closing → exited`. `exited` is terminal and `running` is not
/// reachable from anything but `starting`, so a closed session can never be
/// revived.
pub const Lifecycle = enum {
    starting,
    running,
    closing,
    exited,

    /// Whether this state admits no further transition.
    pub fn isTerminal(self: Lifecycle) bool {
        return self == .exited;
    }
};

/// Whether `from → to` is a legal lifecycle step.
///
/// Every pair not listed here is illegal, which is what keeps "hiding is never
/// termination" true by construction: nothing in the vocabulary of this enum
/// expresses hiding.
pub fn canTransition(from: Lifecycle, to: Lifecycle) bool {
    return switch (from) {
        .starting => to == .running,
        .running => to == .closing,
        .closing => to == .exited,
        .exited => false,
    };
}

/// Move a session from `from` to `to`, or fail. Returning the error rather
/// than forcing an `assert` keeps a bad call from crashing the app: lifecycle
/// is driven by PTY and input events, not only by programmer invariants
/// (`AGENTS.md`, coding standards).
pub fn transition(from: Lifecycle, to: Lifecycle) error{IllegalTransition}!Lifecycle {
    if (!canTransition(from, to)) return error.IllegalTransition;
    return to;
}

const ResponsePty = struct {
    write_limits: []const usize = &.{},
    error_call: ?usize = null,
    write_calls: usize = 0,
    received: [128]u8 = undefined,
    received_len: usize = 0,
    output: []const u8 = "",
    child_state: pty.ChildState = .running,
    readable_override: ?bool = null,
    /// When set, the first take that finds nothing queued publishes these final bytes and then
    /// this end before returning zero: the read thread finishing between the owner's two looks.
    late_end: ?pty.ChildState = null,
    late_output: []const u8 = "",
    /// The most recent window size the session told this child about.
    resized: ?pty.WindowSize = null,

    const vtable: pty.Pty.VTable = .{
        .write = write,
        .resize = resize,
        .kill = kill,
        .takeBytes = takeBytes,
        .state = state,
        .waitReadable = waitReadable,
        .destroy = destroy,
    };

    fn asPty(self: *ResponsePty) pty.Pty {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn written(self: *const ResponsePty) []const u8 {
        return self.received[0..self.received_len];
    }

    fn write(ptr: *anyopaque, bytes: []const u8) pty.Error!usize {
        const self: *ResponsePty = @ptrCast(@alignCast(ptr));
        const call = self.write_calls;
        self.write_calls += 1;
        if (self.error_call) |error_call| {
            if (error_call == call) return error.SystemError;
        }
        const limit = if (call < self.write_limits.len) self.write_limits[call] else bytes.len;
        const count = @min(limit, bytes.len);
        if (count > self.received.len - self.received_len) return error.SystemError;
        @memcpy(self.received[self.received_len..][0..count], bytes[0..count]);
        self.received_len += count;
        return count;
    }

    fn resize(ptr: *anyopaque, size: pty.WindowSize) pty.Error!void {
        const self: *ResponsePty = @ptrCast(@alignCast(ptr));
        self.resized = size;
    }

    fn kill(_: *anyopaque, _: pty.Signal) pty.Error!void {}

    fn takeBytes(ptr: *anyopaque, dest: []u8) usize {
        const self: *ResponsePty = @ptrCast(@alignCast(ptr));
        const count = @min(dest.len, self.output.len);
        @memcpy(dest[0..count], self.output[0..count]);
        self.output = self.output[count..];
        if (count == 0) {
            if (self.late_end) |end| {
                self.output = self.late_output;
                self.child_state = end;
                self.late_end = null;
            }
        }
        return count;
    }

    fn state(ptr: *anyopaque) pty.ChildState {
        const self: *ResponsePty = @ptrCast(@alignCast(ptr));
        return self.child_state;
    }

    fn waitReadable(ptr: *anyopaque, _: u32) bool {
        const self: *ResponsePty = @ptrCast(@alignCast(ptr));
        if (self.readable_override) |readable| return readable;
        if (self.output.len != 0) return true;
        return self.child_state == .exited;
    }

    fn destroy(_: *anyopaque) void {}
};

const primary_device_attributes = "\x1b[?62;22c";
const secondary_device_attributes = "\x1b[>1;0;0c";
const primary_and_secondary = "\x1b[?62;22c\x1b[>1;0;0c";

test "session flushes a complete terminal response to its child" {
    const testing = std.testing;
    var fake: ResponsePty = .{};
    var live = try Session.init(testing.io, testing.allocator, .human_terminal, .{ .cols = 20, .rows = 3 });
    defer live.deinit() catch |err| std.debug.panic("session cleanup failed: {s}", .{@errorName(err)});
    try live.attachChild(fake.asPty());
    live.terminal().feed("\x1b[c");
    var scratch: [32]u8 = undefined;

    try testing.expect(live.needsPump());
    const result = try live.flushChildResponses(&scratch);
    try testing.expectEqual(primary_device_attributes.len, result.written);
    try testing.expectEqual(@as(usize, 0), result.pending);
    try testing.expect(!result.hasPending());
    try testing.expectEqualStrings(primary_device_attributes, fake.written());
    try testing.expect(!live.needsPump());
}

test "session retries a short response write before newer terminal bytes" {
    const testing = std.testing;
    const limits = [_]usize{ 3, primary_device_attributes.len, secondary_device_attributes.len };
    var fake: ResponsePty = .{ .write_limits = &limits };
    var live = try Session.init(testing.io, testing.allocator, .human_terminal, .{ .cols = 20, .rows = 3 });
    defer live.deinit() catch |err| std.debug.panic("session cleanup failed: {s}", .{@errorName(err)});
    try live.attachChild(fake.asPty());
    var scratch: [32]u8 = undefined;

    live.terminal().feed("\x1b[c");
    const first = try live.flushChildResponses(&scratch);
    try testing.expectEqual(@as(usize, 3), first.written);
    try testing.expectEqual(primary_device_attributes.len - 3, first.pending);

    live.terminal().feed("\x1b[>c");
    const second = try live.flushChildResponses(&scratch);
    try testing.expectEqual(primary_device_attributes.len - 3 + secondary_device_attributes.len, second.written);
    try testing.expectEqual(@as(usize, 0), second.pending);
    try testing.expectEqualStrings(primary_and_secondary, fake.written());
    try testing.expectEqual(@as(usize, 3), fake.write_calls);
}

test "session preserves a zero-write response and retries it with empty scratch" {
    const testing = std.testing;
    const limits = [_]usize{ 0, primary_device_attributes.len };
    var fake: ResponsePty = .{ .write_limits = &limits };
    var live = try Session.init(testing.io, testing.allocator, .human_terminal, .{ .cols = 20, .rows = 3 });
    defer live.deinit() catch |err| std.debug.panic("session cleanup failed: {s}", .{@errorName(err)});
    try live.attachChild(fake.asPty());
    live.terminal().feed("\x1b[c");
    var scratch: [32]u8 = undefined;

    const blocked = try live.flushChildResponses(&scratch);
    try testing.expectEqual(@as(usize, 0), blocked.written);
    try testing.expectEqual(primary_device_attributes.len, blocked.pending);
    try testing.expectEqualStrings("", fake.written());

    const retried = try live.flushChildResponses(scratch[0..0]);
    try testing.expectEqual(primary_device_attributes.len, retried.written);
    try testing.expectEqual(@as(usize, 0), retried.pending);
    try testing.expectEqualStrings(primary_device_attributes, fake.written());
}

test "session preserves a response when the child write fails" {
    const testing = std.testing;
    var fake: ResponsePty = .{ .error_call = 0 };
    var live = try Session.init(testing.io, testing.allocator, .agent_terminal, .{ .cols = 20, .rows = 3 });
    defer live.deinit() catch |err| std.debug.panic("session cleanup failed: {s}", .{@errorName(err)});
    try live.attachChild(fake.asPty());
    live.terminal().feed("\x1b[c");
    var scratch: [32]u8 = undefined;

    try testing.expectError(error.SystemError, live.flushChildResponses(&scratch));
    fake.error_call = null;
    const retried = try live.flushChildResponses(scratch[0..0]);
    try testing.expectEqual(primary_device_attributes.len, retried.written);
    try testing.expectEqual(@as(usize, 0), retried.pending);
    try testing.expectEqualStrings(primary_device_attributes, fake.written());
}

test "a childless session leaves terminal responses queued" {
    const testing = std.testing;
    var live = try Session.init(testing.io, testing.allocator, .scratchpad, .{ .cols = 20, .rows = 3 });
    defer live.deinit() catch |err| std.debug.panic("childless session cleanup failed: {s}", .{@errorName(err)});
    live.terminal().feed("\x1b[c");
    var scratch: [32]u8 = undefined;

    const result = try live.flushChildResponses(&scratch);
    try testing.expectEqual(@as(usize, 0), result.written);
    try testing.expectEqual(primary_device_attributes.len, result.pending);
    try testing.expect(result.hasPending());
    try testing.expectEqual(primary_device_attributes.len, live.terminal().pendingResponses());
    try testing.expect(!live.needsPump());
}

test "an exited child stays pumpable through final output and then quiesces" {
    const testing = std.testing;
    var fake: ResponsePty = .{
        .output = "final",
        .child_state = .{ .exited = .{ .code = 0 } },
    };
    var live = try Session.init(testing.io, testing.allocator, .agent_terminal, .{ .cols = 20, .rows = 3 });
    defer live.deinit() catch |err| std.debug.panic("session cleanup failed: {s}", .{@errorName(err)});
    try live.attachChild(fake.asPty());
    var buffer: [2]u8 = undefined;

    try testing.expect(live.needsPump());
    try testing.expectEqual(@as(usize, 0), live.drainChildOutput(buffer[0..0]));
    try testing.expect(live.needsPump());

    try testing.expectEqual(@as(usize, 2), live.drainChildOutput(&buffer));
    try testing.expectEqualStrings("fi", &buffer);
    try testing.expect(live.needsPump());
    try testing.expectEqual(@as(usize, 2), live.drainChildOutput(&buffer));
    try testing.expectEqualStrings("na", &buffer);
    try testing.expect(live.needsPump());
    try testing.expectEqual(@as(usize, 1), live.drainChildOutput(&buffer));
    try testing.expectEqualStrings("l", buffer[0..1]);

    // Even the final positive read needs one more pass: only a zero read can
    // prove that the exited child's queue is empty.
    try testing.expect(live.needsPump());
    try testing.expectEqual(@as(usize, 0), live.drainChildOutput(&buffer));
    try testing.expect(!live.needsPump());
}

test "final output and the end published after an empty take are not stranded" {
    const testing = std.testing;
    var fake: ResponsePty = .{
        .late_output = "tail",
        .late_end = .{ .exited = .{ .code = 0 } },
    };
    var live = try Session.init(testing.io, testing.allocator, .human_terminal, .{ .cols = 20, .rows = 3 });
    defer live.deinit() catch |err| std.debug.panic("session cleanup failed: {s}", .{@errorName(err)});
    try live.attachChild(fake.asPty());
    var buffer: [8]u8 = undefined;

    // The take finds the ring empty, and only then does the reader queue its last bytes and
    // publish the end. That end was not seen before the empty take, so it proves nothing about
    // the queue and the session must keep asking.
    try testing.expectEqual(@as(usize, 0), live.drainChildOutput(&buffer));
    try testing.expect(live.needsPump());
    try testing.expectEqual(@as(usize, 4), live.drainChildOutput(&buffer));
    try testing.expectEqualStrings("tail", buffer[0..4]);
    try testing.expect(live.needsPump());
    try testing.expectEqual(@as(usize, 0), live.drainChildOutput(&buffer));
    try testing.expect(!live.needsPump());
}

test "a running zero read does not make the child permanently quiescent" {
    const testing = std.testing;
    var fake: ResponsePty = .{ .readable_override = true };
    var live = try Session.init(testing.io, testing.allocator, .human_terminal, .{ .cols = 20, .rows = 3 });
    defer live.deinit() catch |err| std.debug.panic("session cleanup failed: {s}", .{@errorName(err)});
    try live.attachChild(fake.asPty());
    var buffer: [8]u8 = undefined;

    try testing.expect(live.needsPump());
    try testing.expectEqual(@as(usize, 0), live.drainChildOutput(&buffer));

    fake.readable_override = null;
    fake.output = "later";
    try testing.expect(live.needsPump());
    try testing.expectEqual(@as(usize, 5), live.drainChildOutput(&buffer));
    try testing.expectEqualStrings("later", buffer[0..5]);
    try testing.expect(!live.needsPump());

    fake.output = "again";
    try testing.expect(live.needsPump());
}

test "a session exposes OSC 7 cwd and forgets it on reset" {
    const testing = std.testing;
    var live = try Session.init(testing.io, testing.allocator, .human_terminal, .{ .cols = 40, .rows = 4 });
    // There is no child, so deinit has no fallible operation in this test.
    defer live.deinit() catch |err| std.debug.panic("childless session cleanup failed: {s}", .{@errorName(err)});

    try testing.expectEqual(@as(?[]const u8, null), live.workingDirectory());
    live.terminal().feed("\x1b]7;file://localhost/tmp/conduit%20cwd\x07");
    _ = live.terminal().takeEvents();
    try testing.expectEqualStrings("/tmp/conduit cwd", live.workingDirectory().?);

    live.terminal().feed("\x1bc");
    _ = live.terminal().takeEvents();
    try testing.expectEqual(@as(?[]const u8, null), live.workingDirectory());
    try testing.expect(!live.hasSeenPromptMarks());
    try testing.expect(!live.cursorIsAtPrompt());
}

test "a session exposes OSC 133 prompt state and retained rows" {
    const testing = std.testing;
    var live = try Session.init(testing.io, testing.allocator, .human_terminal, .{ .cols = 20, .rows = 4 });
    // There is no child, so deinit has no fallible operation in this test.
    defer live.deinit() catch |err| std.debug.panic("childless session cleanup failed: {s}", .{@errorName(err)});
    var rows: [8]u32 = undefined;

    try testing.expect(!live.hasSeenPromptMarks());
    try testing.expect(!live.cursorIsAtPrompt());
    try testing.expectEqual(@as(usize, 0), live.promptRows(&rows));

    for (0..3) |_| {
        live.terminal().feed("\x1b]133;A\x07$ \x1b]133;B\x07x\r\n\x1b]133;C\x07out\r\n\x1b]133;D;0\x07");
        _ = live.terminal().takeEvents();
    }
    try testing.expect(live.hasSeenPromptMarks());
    try testing.expect(!live.cursorIsAtPrompt());
    try testing.expectEqual(@as(usize, 3), live.promptRows(&rows));
    try testing.expectEqualSlices(u32, &.{ 0, 2, 4 }, rows[0..3]);

    live.terminal().feed("\x1b]133;A\x07$ \x1b]133;B\x07");
    _ = live.terminal().takeEvents();
    try testing.expect(live.cursorIsAtPrompt());
}

test "a child attached after the terminal was resized is told the current size" {
    const testing = std.testing;
    // The PTY was created with the grid known when the spawn was requested; the
    // grid changed while the worker was still spawning (a font reload, a window
    // or sidebar resize). The child must learn the grid it is actually drawn in,
    // or it draws for a size the terminal no longer has until the next resize.
    var fake: ResponsePty = .{};
    var live = try Session.init(testing.io, testing.allocator, .human_terminal, .{ .cols = 20, .rows = 3 });
    defer live.deinit() catch |err| std.debug.panic("session cleanup failed: {s}", .{@errorName(err)});
    try live.resize(.{ .cols = 56, .rows = 18 });
    try live.attachChild(fake.asPty());
    try testing.expect(fake.resized == null);

    try live.syncChildSize(pty.WindowSize.init(3, 20));

    try testing.expect(fake.resized != null);
    try testing.expectEqual(@as(u16, 18), fake.resized.?.rows);
    try testing.expectEqual(@as(u16, 56), fake.resized.?.cols);
}

test "a child spawned at the current size is not resized again on attach" {
    const testing = std.testing;
    var fake: ResponsePty = .{};
    var live = try Session.init(testing.io, testing.allocator, .human_terminal, .{ .cols = 20, .rows = 3 });
    defer live.deinit() catch |err| std.debug.panic("session cleanup failed: {s}", .{@errorName(err)});
    try live.attachChild(fake.asPty());

    try live.syncChildSize(pty.WindowSize.init(3, 20));

    try testing.expect(fake.resized == null);
}

test "a session retains its explicit owner kind" {
    const testing = std.testing;

    inline for (@typeInfo(Session.Kind).@"enum".fields) |field| {
        const expected: Session.Kind = @enumFromInt(field.value);
        var live = try Session.init(testing.io, testing.allocator, expected, .{ .cols = 2, .rows = 1 });
        defer live.deinit() catch |err| std.debug.panic("childless session cleanup failed: {s}", .{@errorName(err)});

        try testing.expectEqual(expected, live.kind());
    }
}

test "draining a childless session is an allocation-free no-op" {
    const testing = std.testing;
    var live = try Session.init(testing.io, testing.allocator, .scratchpad, .{ .cols = 8, .rows = 2 });
    defer live.deinit() catch |err| std.debug.panic("childless session cleanup failed: {s}", .{@errorName(err)});
    const untouched = [_]u8{0xa5} ** 8;
    var buffer = untouched;

    try testing.expectEqual(@as(usize, 0), live.drainChildOutput(&buffer));
    try testing.expectEqualSlices(u8, &untouched, &buffer);
}

test "session ids are one-based and their ordinals round-trip" {
    const testing = std.testing;

    // Zero is the boundary: the first id is 1, so no id can name "no session".
    try testing.expectEqual(@as(u32, 1), @intFromEnum(SessionId.first));
    try testing.expectEqual(SessionId.fromOrdinal(0), SessionId.first);

    var ordinal: u32 = 0;
    while (ordinal < 8) : (ordinal += 1) {
        const id = SessionId.fromOrdinal(ordinal);
        try testing.expectEqual(ordinal, id.ordinal());
        try testing.expect(@intFromEnum(id) != 0);
        // Distinct ordinals are distinct sessions.
        try testing.expect(id != SessionId.fromOrdinal(ordinal + 1));
    }
}

test "the lifecycle allows only start, run, close and exit" {
    const testing = std.testing;

    // The complete set of legal steps, spelled out independently of the
    // implementation so a new state or a new edge fails here.
    const legal = [_][2]Lifecycle{
        .{ .starting, .running },
        .{ .running, .closing },
        .{ .closing, .exited },
    };

    inline for (@typeInfo(Lifecycle).@"enum".fields) |from_field| {
        const from: Lifecycle = @enumFromInt(from_field.value);
        inline for (@typeInfo(Lifecycle).@"enum".fields) |to_field| {
            const to: Lifecycle = @enumFromInt(to_field.value);

            var expected = false;
            for (legal) |step| {
                if (step[0] == from and step[1] == to) expected = true;
            }
            try testing.expectEqual(expected, canTransition(from, to));
        }
    }
}

test "an exited session is dead and a running one cannot restart" {
    const testing = std.testing;

    try testing.expect(try transition(.starting, .running) == .running);
    try testing.expect(try transition(.running, .closing) == .closing);
    try testing.expect(try transition(.closing, .exited) == .exited);

    // Closing is the only way out of running: a session that is still running
    // is alive no matter which view is showing it.
    for ([_]Lifecycle{ .closing, .exited }) |illegal_from| {
        try testing.expectError(
            error.IllegalTransition,
            transition(illegal_from, .running),
        );
    }

    // An exited session has no further steps, and nothing revives it.
    try testing.expect(Lifecycle.exited.isTerminal());
    for ([_]Lifecycle{ .starting, .running, .closing, .exited }) |to| {
        try testing.expect(!canTransition(.exited, to));
        try testing.expectError(error.IllegalTransition, transition(.exited, to));
    }
}
