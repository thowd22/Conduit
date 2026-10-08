//! Bounded readiness waits on the descriptors the agent transports use: the
//! pipes to a harness child and the Unix socket to a daemon (TASK-5).
//!
//! `std.posix.poll` does not exist for Windows targets in Zig 0.16 (its
//! `pollfd` names a `ws2_32` type the standard library does not declare), so
//! adapter code that named it did not compile there. This is the one place the
//! agent layer asks the OS whether a descriptor is ready; adapters call `wait`
//! and stay free of OS conditionals.
//!
//! POSIX: `poll(2)` on the one descriptor. Windows: an anonymous or named
//! pipe's readiness to read is `PeekNamedPipe` reporting bytes or a broken
//! pipe, re-checked in one-millisecond slices until the timeout; a pipe has
//! no write readiness to ask about (`WriteFile` simply blocks), so a write
//! wait reports writable at once. Windows sockets are not served here.

const std = @import("std");
const builtin = @import("builtin");

/// A descriptor on POSIX, a `HANDLE` on Windows.
pub const Handle = std.posix.fd_t;

pub const Interest = enum { read, write };

/// What `wait` saw. `hangup` is the peer gone (POLLHUP, a broken pipe) and
/// `failed` an error condition on the descriptor (POLLERR, POLLNVAL); either
/// may come with `readable` while buffered bytes remain.
pub const Ready = struct {
    readable: bool = false,
    writable: bool = false,
    hangup: bool = false,
    failed: bool = false,

    /// Whether the descriptor can no longer carry new data both ways.
    pub fn broken(self: Ready) bool {
        return self.hangup or self.failed;
    }
};

pub const Error = error{Unavailable};

/// Wait at most `timeout_ms` (zero: just look) for `handle` to be ready for
/// `interest`. Null when the timeout passed with nothing to report.
pub fn wait(handle: Handle, interest: Interest, timeout_ms: u32) Error!?Ready {
    if (comptime builtin.os.tag == .windows) return windowsWait(handle, interest, timeout_ms);
    return posixWait(handle, interest, timeout_ms);
}

fn posixWait(handle: Handle, interest: Interest, timeout_ms: u32) Error!?Ready {
    const posix = std.posix;
    const events: i16 = switch (interest) {
        .read => posix.POLL.IN,
        .write => posix.POLL.OUT,
    };
    var fds = [_]posix.pollfd{.{ .fd = handle, .events = events, .revents = 0 }};
    const timeout: i32 = @intCast(@min(timeout_ms, std.math.maxInt(i32)));
    const count = posix.poll(&fds, timeout) catch return error.Unavailable;
    if (count == 0) return null;
    const revents = fds[0].revents;
    return .{
        .readable = revents & posix.POLL.IN != 0,
        .writable = revents & posix.POLL.OUT != 0,
        .hangup = revents & posix.POLL.HUP != 0,
        .failed = revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0,
    };
}

const win = struct {
    const windows = std.os.windows;
    extern "kernel32" fn PeekNamedPipe(
        pipe: windows.HANDLE,
        buffer: ?*anyopaque,
        buffer_size: windows.DWORD,
        bytes_read: ?*windows.DWORD,
        total_available: ?*windows.DWORD,
        bytes_left_this_message: ?*windows.DWORD,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn Sleep(milliseconds: windows.DWORD) callconv(.winapi) void;
    // Declared exactly as `pty` declares it, because both link into one binary.
    extern "kernel32" fn CreatePipe(
        read_end: *windows.HANDLE,
        write_end: *windows.HANDLE,
        attributes: ?*windows.SECURITY_ATTRIBUTES,
        size: windows.DWORD,
    ) callconv(.winapi) windows.BOOL;
};

fn windowsWait(handle: Handle, interest: Interest, timeout_ms: u32) Error!?Ready {
    if (interest == .write) return .{ .writable = true };
    var waited: u32 = 0;
    while (true) {
        var available: win.windows.DWORD = 0;
        if (win.PeekNamedPipe(handle, null, 0, null, &available, null) == .FALSE) {
            return switch (win.windows.GetLastError()) {
                // The writer closed: what a POSIX reader sees as POLLHUP, with
                // the end of the stream left for the read to report.
                .BROKEN_PIPE, .PIPE_NOT_CONNECTED => .{ .readable = true, .hangup = true },
                else => error.Unavailable,
            };
        }
        if (available != 0) return .{ .readable = true };
        if (waited >= timeout_ms) return null;
        // A pipe has no waitable readiness, so the bounded wait is slices.
        win.Sleep(1);
        waited += 1;
    }
}

/// Both ends of a fresh anonymous pipe, for the test.
fn testPipe() ![2]Handle {
    if (comptime builtin.os.tag == .windows) {
        var ends: [2]Handle = undefined;
        if (win.CreatePipe(&ends[0], &ends[1], null, 0) == .FALSE) return error.Unexpected;
        return ends;
    }
    return std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
}

fn testFile(handle: Handle) std.Io.File {
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

test "a pipe is writable at once, readable once written, and hung up once its writer closes" {
    const testing = std.testing;
    const io = testing.io;
    const ends = try testPipe();
    var write_open = true;
    defer testFile(ends[0]).close(io);
    defer if (write_open) testFile(ends[1]).close(io);

    try testing.expect((try wait(ends[0], .read, 0)) == null);
    try testing.expect((try wait(ends[1], .write, 0)).?.writable);
    try testFile(ends[1]).writeStreamingAll(io, "x");
    const ready = (try wait(ends[0], .read, 1000)).?;
    try testing.expect(ready.readable and !ready.broken());
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try testFile(ends[0]).readStreaming(io, &.{&byte}));

    testFile(ends[1]).close(io);
    write_open = false;
    // POSIX lets a reader see a gone writer as POLLHUP, as POLLIN with the
    // end of the stream behind it, or as both (Linux and macOS differ).
    const gone = (try wait(ends[0], .read, 1000)).?;
    try testing.expect(gone.hangup or gone.readable);
}
