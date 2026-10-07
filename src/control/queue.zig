//! The bounded hand-off between control connection threads and the owner
//! (UI) thread.
//!
//! A connection thread `submit`s one validated request, transferring its
//! parse arena to a slot, and then `wait`s on that slot with a deadline. The
//! owner `take`s queued requests in arrival order, borrows each `Request`
//! until it `complete`s the ticket, and never blocks. A wait that times out
//! (or a server that stops) cancels a still-queued request outright; a request
//! the owner already took is marked abandoned and freed by the owner's later
//! `complete`, so the owner's borrow is never invalidated under it.
//!
//! Every field is guarded by `mutex`. Memory: the slot array is allocated once
//! in `init`; each occupied slot owns one `protocol.Parsed` arena until the
//! slot is freed.

const std = @import("std");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;

/// The opaque workspace identity the owner registered a token for.
pub const WorkspaceRef = u64;

/// A request the owner performs. Every slice borrows the slot's parse arena
/// and stays valid until the owner completes its ticket.
pub const Request = struct {
    /// The workspace the caller's token resolved to.
    workspace: WorkspaceRef,
    /// The caller's own session as it named it, already checked not to be the
    /// workspace's scratchpad. The owner must still check that it belongs to
    /// `workspace`, and must never resolve an absent session to the scratchpad.
    session: ?u32,
    params: protocol.Params,
};

/// Names one in-flight request. Stale tickets are ignored.
pub const Ticket = struct {
    slot: u32,
    generation: u32,
};

/// How a wait ended.
pub const WaitResult = union(enum) {
    reply: protocol.Reply,
    timed_out,
    stopped,
};

const State = enum { free, queued, taken, replied };

const Slot = struct {
    state: State = .free,
    /// The waiter gave up while the owner held the request.
    abandoned: bool = false,
    generation: u32 = 0,
    sequence: u64 = 0,
    parsed: ?protocol.Parsed = null,
    token: protocol.Token = undefined,
    request: Request = undefined,
    reply: protocol.Reply = undefined,
    done: std.Io.Event = .unset,
};

pub const Queue = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    slots: []Slot,
    next_sequence: u64 = 0,
    stopping: bool = false,

    pub const SubmitError = error{ Busy, Stopped };

    pub fn init(allocator: Allocator, io: std.Io, capacity: usize) Allocator.Error!Queue {
        std.debug.assert(capacity != 0 and capacity <= std.math.maxInt(u32));
        const slots = try allocator.alloc(Slot, capacity);
        @memset(slots, .{});
        return .{ .io = io, .slots = slots };
    }

    /// Free every arena still held, whatever its state. Call only once no
    /// connection thread can touch the queue.
    pub fn deinit(self: *Queue, allocator: Allocator) void {
        for (self.slots) |*slot| if (slot.parsed) |*parsed| parsed.deinit();
        allocator.free(self.slots);
        self.* = undefined;
    }

    /// Queue `request`, taking ownership of `parsed` on success only. Any
    /// thread.
    pub fn submit(self: *Queue, parsed: protocol.Parsed, token: protocol.Token, request: Request) SubmitError!Ticket {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.Stopped;
        for (self.slots, 0..) |*slot, index| {
            if (slot.state != .free) continue;
            slot.state = .queued;
            slot.abandoned = false;
            slot.sequence = self.next_sequence;
            self.next_sequence += 1;
            slot.parsed = parsed;
            slot.token = token;
            slot.request = request;
            slot.done.reset();
            return .{ .slot = @intCast(index), .generation = slot.generation };
        }
        return error.Busy;
    }

    /// Block until the owner replies, `timeout` passes or the queue stops.
    /// Only the submitting thread waits on its ticket. The slot is released
    /// (or left for the owner to release) before this returns.
    pub fn wait(self: *Queue, ticket: Ticket, timeout: std.Io.Duration) WaitResult {
        const deadline: std.Io.Clock.Timestamp = .fromNow(self.io, .{ .raw = timeout, .clock = .awake });
        const slot = &self.slots[ticket.slot];
        while (true) {
            const timed_out = if (slot.done.waitTimeout(self.io, .{ .deadline = deadline })) |_|
                false
            else |_|
                // A timeout may be spurious; only the deadline decides.
                deadline.durationFromNow(self.io).raw.nanoseconds <= 0;

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            std.debug.assert(slot.generation == ticket.generation);
            switch (slot.state) {
                .replied => {
                    const reply = slot.reply;
                    self.release(slot);
                    return .{ .reply = reply };
                },
                .queued, .taken => if (timed_out or self.stopping) {
                    if (slot.state == .queued) self.release(slot) else slot.abandoned = true;
                    return if (self.stopping) .stopped else .timed_out;
                },
                .free => unreachable, // only this waiter or an abandoned owner frees it
            }
        }
    }

    /// Take the oldest queued request without blocking. Owner thread only.
    /// The returned request borrows the slot until `complete`.
    pub fn take(self: *Queue) ?struct { ticket: Ticket, token: protocol.Token, request: *const Request } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var oldest: ?*Slot = null;
        for (self.slots) |*slot| {
            if (slot.state != .queued) continue;
            if (oldest == null or slot.sequence < oldest.?.sequence) oldest = slot;
        }
        const slot = oldest orelse return null;
        slot.state = .taken;
        const index: u32 = @intCast(slot - self.slots.ptr);
        return .{
            .ticket = .{ .slot = index, .generation = slot.generation },
            .token = slot.token,
            .request = &slot.request,
        };
    }

    /// Answer a taken request. Returns false for a stale or untaken ticket.
    /// Owner thread only.
    pub fn complete(self: *Queue, ticket: Ticket, reply: protocol.Reply) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (ticket.slot >= self.slots.len) return false;
        const slot = &self.slots[ticket.slot];
        if (slot.generation != ticket.generation or slot.state != .taken) return false;
        if (slot.abandoned) {
            self.release(slot);
            return true;
        }
        slot.reply = reply;
        slot.state = .replied;
        slot.done.set(self.io);
        return true;
    }

    /// Wake every waiter with `.stopped` and refuse new submissions.
    pub fn stop(self: *Queue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stopping = true;
        for (self.slots) |*slot| if (slot.state == .queued or slot.state == .taken) slot.done.set(self.io);
    }

    /// Requests waiting for the owner.
    pub fn pending(self: *Queue) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.slots) |slot| count += @intFromBool(slot.state == .queued);
        return count;
    }

    fn release(self: *Queue, slot: *Slot) void {
        _ = self;
        if (slot.parsed) |*parsed| parsed.deinit();
        slot.parsed = null;
        slot.state = .free;
        slot.abandoned = false;
        slot.generation +%= 1;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const token_text = "0123456789abcdef0123456789abcdef";

fn parsedPing() !protocol.Parsed {
    return protocol.parseFrame(testing.allocator, "{\"id\":1,\"method\":\"ping\",\"token\":\"" ++ token_text ++ "\"}");
}

fn submitPing(queue: *Queue, workspace: WorkspaceRef) !Ticket {
    var parsed = try parsedPing();
    errdefer parsed.deinit();
    return queue.submit(parsed, try protocol.Token.parse(token_text), .{
        .workspace = workspace,
        .session = null,
        .params = .ping,
    });
}

test "the queue is bounded and refuses submissions once full or stopped" {
    var queue = try Queue.init(testing.allocator, testing.io, 2);
    defer queue.deinit(testing.allocator);
    _ = try submitPing(&queue, 1);
    _ = try submitPing(&queue, 2);
    try testing.expectError(error.Busy, submitPing(&queue, 3));
    try testing.expectEqual(@as(usize, 2), queue.pending());
    queue.stop();
    try testing.expectError(error.Stopped, submitPing(&queue, 4));
}

test "the owner takes requests in arrival order and its reply reaches the waiter" {
    var queue = try Queue.init(testing.allocator, testing.io, 4);
    defer queue.deinit(testing.allocator);
    const first = try submitPing(&queue, 10);
    const second = try submitPing(&queue, 20);

    const taken_first = queue.take().?;
    try testing.expectEqual(@as(WorkspaceRef, 10), taken_first.request.workspace);
    try testing.expect(queue.complete(taken_first.ticket, .{ .result = .pong }));
    try testing.expect(!queue.complete(taken_first.ticket, .{ .result = .pong }));
    const reply = queue.wait(first, .fromSeconds(5));
    try testing.expectEqual(protocol.Reply{ .result = .pong }, reply.reply);
    // The released slot's old ticket is now stale.
    try testing.expect(!queue.complete(first, .{ .result = .ok }));

    const taken_second = queue.take().?;
    try testing.expectEqual(@as(WorkspaceRef, 20), taken_second.request.workspace);
    try testing.expect(queue.complete(taken_second.ticket, .{ .fault = .not_found }));
    try testing.expectEqual(protocol.Reply{ .fault = .not_found }, queue.wait(second, .fromSeconds(5)).reply);
    try testing.expectEqual(@as(?@TypeOf(queue.take().?), null), queue.take());
}

test "a reply deadline cancels a queued request and abandons a taken one" {
    var queue = try Queue.init(testing.allocator, testing.io, 1);
    defer queue.deinit(testing.allocator);

    const queued = try submitPing(&queue, 1);
    try testing.expectEqual(WaitResult.timed_out, queue.wait(queued, .fromMilliseconds(20)));
    try testing.expectEqual(@as(usize, 0), queue.pending());

    const held = try submitPing(&queue, 2);
    const taken = queue.take().?;
    try testing.expectEqual(WaitResult.timed_out, queue.wait(held, .fromMilliseconds(20)));
    // The owner still holds the request: its slot is not reusable yet.
    try testing.expectError(error.Busy, submitPing(&queue, 3));
    try testing.expectEqual(@as(WorkspaceRef, 2), taken.request.workspace);
    try testing.expect(queue.complete(taken.ticket, .{ .result = .ok }));
    _ = try submitPing(&queue, 4);
}
