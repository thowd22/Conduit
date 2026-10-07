//! The harness-neutral PTY baseline (decision-7): what an agent is doing,
//! guessed only from what any terminal program shows Conduit.
//!
//! Every agent session gets this for free, whatever its harness, and keeps it
//! as a fallback when the structured channel is missing or silent. It reads
//! no terminal text: only the escape-sequence facts the terminal already
//! surfaces (OSC 0/2 title changes, BEL, OSC 9/777 notifications, OSC 133
//! prompt marks), output activity versus quiet, the human typing, and child
//! exit. Its claims are labelled `Source.heuristic`, and the registry ignores
//! them once a structured source has spoken.
//!
//! The mapping:
//!   output, title change, OSC 133 command start  → working
//!   no output for `quiet_after_ns` while working → idle
//!   BEL or OSC 9/777 notification                → waiting_input (attention)
//!   the human types into the agent's terminal    → working, attention cleared
//!   OSC 133 prompt while a turn was running      → done (back at the shell)
//!   child exit                                   → done or errored, then exited
//! While attention is raised, output does not count as work: a TUI that
//! redraws a cursor or a spinner while it waits must not hide the wait.
//!
//! Threads: owner thread only. Memory: values only; event text borrows the
//! observation passed in and is valid only for the call.

const std = @import("std");
const state_model = @import("state.zig");
const event = @import("event.zig");

const State = state_model.State;
const Event = event.Event;

/// One terminal fact about an agent's session. `now_ns` is a monotonic
/// timestamp from the caller, so this module reads no clock.
pub const Observation = union(enum) {
    output: struct { now_ns: u64 },
    /// A periodic check while the session is otherwise silent.
    tick: struct { now_ns: u64 },
    title: struct { now_ns: u64 },
    bell,
    notification: event.Notification,
    command_started: struct { now_ns: u64 },
    shell_prompt,
    user_input,
    child_exited: event.ExitStatus,
};

/// At most two events come from one observation.
pub const Batch = struct {
    items: [2]Event = undefined,
    len: usize = 0,

    pub fn events(self: *const Batch) []const Event {
        return self.items[0..self.len];
    }

    fn add(self: *Batch, ev: Event) void {
        self.items[self.len] = ev;
        self.len += 1;
    }
};

pub const Heuristics = struct {
    /// How long a working session must be silent to be called idle.
    pub const default_quiet_after_ns: u64 = 3 * std.time.ns_per_s;

    state: State = .idle,
    quiet_after_ns: u64 = default_quiet_after_ns,
    last_activity_ns: ?u64 = null,
    attention: bool = false,
    exited: bool = false,

    /// Fold one observation and return the events it implies.
    pub fn observe(self: *Heuristics, observation: Observation) Batch {
        var batch: Batch = .{};
        if (self.exited) return batch;
        switch (observation) {
            .output => |o| self.activity(&batch, o.now_ns),
            .title => |o| self.activity(&batch, o.now_ns),
            .command_started => |o| {
                self.attention = false;
                self.activity(&batch, o.now_ns);
            },
            .tick => |o| {
                const last = self.last_activity_ns orelse return batch;
                if (self.state == .working and o.now_ns -| last >= self.quiet_after_ns)
                    self.move(&batch, .idle);
            },
            .bell => self.raiseAttention(&batch),
            .notification => |n| {
                self.raiseAttention(&batch);
                batch.add(.{ .notification = n });
            },
            .user_input => {
                if (self.attention) {
                    self.attention = false;
                    self.move(&batch, .working);
                }
            },
            .shell_prompt => {
                self.attention = false;
                switch (self.state) {
                    .working, .waiting_input, .waiting_permission => self.move(&batch, .done),
                    .idle, .done, .errored => {},
                }
            },
            .child_exited => |status| {
                self.exited = true;
                self.move(&batch, if (status.succeeded()) .done else .errored);
                batch.add(.{ .exited = status });
            },
        }
        return batch;
    }

    fn activity(self: *Heuristics, batch: *Batch, now_ns: u64) void {
        self.last_activity_ns = now_ns;
        if (!self.attention) self.move(batch, .working);
    }

    /// A bell after a finished turn is the harness announcing the outcome,
    /// not a wait, so attention latches only where a wait can begin.
    fn raiseAttention(self: *Heuristics, batch: *Batch) void {
        if (self.state != .waiting_input and !state_model.canTransition(self.state, .waiting_input)) return;
        self.attention = true;
        self.move(batch, .waiting_input);
    }

    /// Emit a status change only when the table allows it; a heuristic never
    /// asks the registry for a refused transition.
    fn move(self: *Heuristics, batch: *Batch, to: State) void {
        if (!state_model.canTransition(self.state, to)) return;
        self.state = to;
        batch.add(.{ .status_change = .{ .state = to, .source = .heuristic } });
    }
};

const testing = std.testing;

fn expectStatus(batch: Batch, expected: ?State) !void {
    if (expected) |state| {
        try testing.expect(batch.len >= 1);
        const change = batch.events()[0].status_change;
        try testing.expectEqual(state, change.state);
        try testing.expectEqual(state_model.Source.heuristic, change.source);
    } else {
        for (batch.events()) |ev| try testing.expect(ev != .status_change);
    }
}

test "activity is work and quiet is idle" {
    var h: Heuristics = .{ .quiet_after_ns = 100 };
    try expectStatus(h.observe(.{ .tick = .{ .now_ns = 0 } }), null);
    try expectStatus(h.observe(.{ .output = .{ .now_ns = 10 } }), .working);
    try expectStatus(h.observe(.{ .output = .{ .now_ns = 20 } }), null);
    try expectStatus(h.observe(.{ .tick = .{ .now_ns = 119 } }), null);
    try expectStatus(h.observe(.{ .tick = .{ .now_ns = 120 } }), .idle);
    try expectStatus(h.observe(.{ .title = .{ .now_ns = 130 } }), .working);
    try expectStatus(h.observe(.{ .tick = .{ .now_ns = 230 } }), .idle);
    try expectStatus(h.observe(.{ .command_started = .{ .now_ns = 240 } }), .working);
}

test "a bell or notification needs attention until the human answers" {
    var h: Heuristics = .{};
    _ = h.observe(.{ .output = .{ .now_ns = 1 } });
    try expectStatus(h.observe(.bell), .waiting_input);
    // A redraw while waiting is not work.
    try expectStatus(h.observe(.{ .output = .{ .now_ns = 2 } }), null);
    try testing.expectEqual(State.waiting_input, h.state);
    try expectStatus(h.observe(.user_input), .working);
    try expectStatus(h.observe(.user_input), null);

    const batch = h.observe(.{ .notification = .{ .title = "Codex", .body = "turn complete" } });
    try expectStatus(batch, .waiting_input);
    try testing.expectEqual(@as(usize, 2), batch.len);
    try testing.expectEqualStrings("turn complete", batch.events()[1].notification.body);
    // A second notification while already waiting carries only the text.
    const repeat = h.observe(.{ .notification = .{ .title = "", .body = "again" } });
    try expectStatus(repeat, null);
    try testing.expectEqual(@as(usize, 1), repeat.len);
}

test "the shell prompt ends a turn and child exit ends everything" {
    var h: Heuristics = .{};
    // Back at a prompt with nothing running finishes nothing.
    try expectStatus(h.observe(.shell_prompt), null);
    _ = h.observe(.{ .command_started = .{ .now_ns = 1 } });
    try expectStatus(h.observe(.shell_prompt), .done);
    // A bell after a finished turn cannot claim a wait the table refuses.
    try expectStatus(h.observe(.bell), null);
    try testing.expectEqual(State.done, h.state);

    _ = h.observe(.{ .output = .{ .now_ns = 5 } });
    var batch = h.observe(.{ .child_exited = .{ .code = 2 } });
    try expectStatus(batch, .errored);
    try testing.expectEqual(event.ExitStatus{ .code = 2 }, batch.events()[1].exited);
    batch = h.observe(.{ .output = .{ .now_ns = 6 } });
    try testing.expectEqual(@as(usize, 0), batch.len);

    var clean: Heuristics = .{};
    batch = clean.observe(.{ .child_exited = .{ .code = 0 } });
    // idle → done is refused, so only the exit is reported; the registry
    // turns a clean exit into `done` itself.
    try testing.expectEqual(@as(usize, 1), batch.len);
    try testing.expect(batch.events()[0].exited.succeeded());
}
