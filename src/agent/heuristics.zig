//! The harness-neutral PTY baseline (decision-7): what an agent is doing,
//! guessed only from what any terminal program shows Conduit.
//!
//! Every agent session gets this for free, whatever its harness, and keeps it
//! as a fallback when the structured channel is missing or silent. It reads
//! the escape-sequence facts the terminal already surfaces (OSC 0/2 title
//! changes, BEL, OSC 9/777 notifications, OSC 133 prompt marks), output
//! activity versus quiet, the human typing and child exit, and (TASK-84) the
//! bottom rows of the terminal's active screen, classified by the harness's
//! own `ScreenManifest`. Its claims are labelled `Source.heuristic`, and the
//! registry ignores them once a structured source has spoken.
//!
//! The mapping:
//!   output, title change, OSC 133 command start  → working
//!   a permission prompt on screen                → waiting_permission, even
//!                                                  while output continues
//!   quiet for `quiet_after_ns`, prompt on screen → waiting_input
//!   quiet for `quiet_after_ns`, error on screen  → errored
//!   quiet, a busy line still on screen           → working, for at most
//!                                                  `working_hold_ns`
//!   quiet, nothing on screen                     → idle, debounced
//!   BEL or OSC 9/777 notification                → waiting_input (attention)
//!   the human types into the agent's terminal    → working, attention cleared
//!   OSC 133 prompt while a turn was running      → done (back at the shell)
//!   child exit                                   → done or errored, then exited
//!
//! Output is the authority for working, as in herdr (whose design this
//! follows; see `screen.zig`): the screen names the quiet states, except that
//! a visible permission prompt outranks activity, because some TUIs keep
//! animating a spinner behind their approval dialog. Once a state came from
//! the screen, output alone does not end it (the human typing at the prompt,
//! or moving the selection in a dialog, redraws); the next look at the
//! screen does. Leaving working for plain idle is debounced as herdr does:
//! the quiet must be confirmed `idle_confirmations` times at least
//! `idle_recheck_ns` apart, or have lasted `idle_cap_ns` since it was first
//! seen, and any output on the way starts over, so a spinner that pauses
//! does not flap the sidebar glyph. While attention is raised, output does
//! not count as work: a TUI that redraws a cursor or a spinner while it
//! waits must not hide the wait.
//!
//! Screen text is untrusted. It is classified and dropped: it can move this
//! state machine, never answer a prompt or trigger an action, and it is
//! never stored or logged.
//!
//! Threads: owner thread only. Memory: values only; event text borrows the
//! observation passed in and is valid only for the call.

const std = @import("std");
const state_model = @import("state.zig");
const event = @import("event.zig");
const screen = @import("screen.zig");

const State = state_model.State;
const Event = event.Event;

/// One terminal fact about an agent's session. `now_ns` is a monotonic
/// timestamp from the caller, so this module reads no clock.
pub const Observation = union(enum) {
    output: struct { now_ns: u64 },
    /// A periodic check. `screen` is the bottom of the session's active
    /// screen when `Heuristics.wantsScreen` asked for it, borrowed for the
    /// call; null when it was not read.
    tick: struct { now_ns: u64, screen: ?[]const u8 = null },
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
    /// How long a working session must be silent before the screen may name
    /// a quiet state, or the idle debounce begins.
    pub const default_quiet_after_ns: u64 = 1 * std.time.ns_per_s;
    /// How long a busy line still on screen keeps a silent session working.
    pub const default_working_hold_ns: u64 = 3 * std.time.ns_per_s;
    /// herdr's idle debounce: three confirmations 100 ms apart, or 700 ms.
    pub const idle_confirmations: u8 = 3;
    pub const default_idle_recheck_ns: u64 = 100 * std.time.ns_per_ms;
    pub const default_idle_cap_ns: u64 = 700 * std.time.ns_per_ms;
    /// The rows of the active screen worth reading: no manifest region is
    /// taller.
    pub const screen_rows: u16 = screen.ScreenManifest.max_rows;
    /// The most screen text a tick carries, in bytes.
    pub const screen_capacity = 8 * 1024;

    state: State = .idle,
    manifest: *const screen.ScreenManifest = &screen.empty,
    quiet_after_ns: u64 = default_quiet_after_ns,
    working_hold_ns: u64 = default_working_hold_ns,
    idle_recheck_ns: u64 = default_idle_recheck_ns,
    idle_cap_ns: u64 = default_idle_cap_ns,
    last_activity_ns: ?u64 = null,
    attention: bool = false,
    exited: bool = false,
    /// The current wait or error was named by the screen, so output alone
    /// does not end it.
    from_screen: bool = false,
    /// The screen may have changed since it was last classified.
    dirty: bool = true,
    /// A working → idle whose quiet is being confirmed.
    pending_idle: ?PendingIdle = null,

    const PendingIdle = struct {
        since_ns: u64,
        last_ns: u64,
        confirmations: u8 = 0,
    };

    /// Whether the next tick should carry the screen: only with a manifest,
    /// and only when the screen can say something new (a turn may be
    /// running, or it was redrawn since it was last read).
    pub fn wantsScreen(self: *const Heuristics) bool {
        if (self.exited or self.manifest.isEmpty()) return false;
        return self.state == .working or self.dirty;
    }

    /// Whether ticks should come every `idle_recheck_ns` rather than at the
    /// caller's usual pace: while working (its quiet may need confirming)
    /// and when a wait the screen named was redrawn (the human may have
    /// started a turn).
    pub fn wantsFastTicks(self: *const Heuristics) bool {
        if (self.exited) return false;
        return self.state == .working or (self.from_screen and self.dirty);
    }

    /// Fold one observation and return the events it implies.
    pub fn observe(self: *Heuristics, observation: Observation) Batch {
        var batch: Batch = .{};
        if (self.exited) return batch;
        switch (observation) {
            .output => |o| self.activity(&batch, o.now_ns),
            .title => |o| self.activity(&batch, o.now_ns),
            .command_started => |o| {
                self.attention = false;
                self.from_screen = false;
                self.activity(&batch, o.now_ns);
            },
            .tick => |o| self.tick(&batch, o.now_ns, o.screen),
            .bell => self.raiseAttention(&batch),
            .notification => |n| {
                self.raiseAttention(&batch);
                batch.add(.{ .notification = n });
            },
            .user_input => {
                if (self.attention) {
                    self.attention = false;
                    self.from_screen = false;
                    self.move(&batch, .working);
                }
            },
            .shell_prompt => {
                self.attention = false;
                self.from_screen = false;
                self.pending_idle = null;
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
        self.dirty = true;
        self.pending_idle = null;
        if (!self.attention and !self.from_screen) self.move(batch, .working);
    }

    fn tick(self: *Heuristics, batch: *Batch, now_ns: u64, text: ?[]const u8) void {
        const class: ?screen.Class = if (text) |t| blk: {
            self.dirty = false;
            break :blk self.manifest.classify(t);
        } else null;
        // Never active since it was seen: as quiet as it gets.
        const quiet_ns: u64 = if (self.last_activity_ns) |last| now_ns -| last else std.math.maxInt(u64);
        const quiet = quiet_ns >= self.quiet_after_ns;

        if (self.attention) {
            // The bell said "look"; the screen may say why.
            if (class == .permission and self.state == .waiting_input) self.fromScreen(batch, .waiting_permission);
            return;
        }
        if (self.from_screen) {
            const c = class orelse return;
            switch (c) {
                .permission => self.fromScreen(batch, .waiting_permission),
                .input, .errored => {
                    const to: State = if (c == .input) .waiting_input else .errored;
                    if (self.state == to) return;
                    if (state_model.canTransition(self.state, to)) {
                        self.fromScreen(batch, to);
                    } else {
                        // An error line gave way to the prompt: settled.
                        self.move(batch, .idle);
                    }
                },
                .working => self.move(batch, .working),
                // The wait is gone from the screen: a new turn's output, or
                // a screen cleared without one.
                .none => self.move(batch, if (quiet) .idle else .working),
            }
            return;
        }
        switch (self.state) {
            .working => {
                if (class == .permission) return self.fromScreen(batch, .waiting_permission);
                if (!quiet) {
                    self.pending_idle = null;
                    return;
                }
                if (class) |c| switch (c) {
                    .input => return self.fromScreen(batch, .waiting_input),
                    .errored => return self.fromScreen(batch, .errored),
                    .working => if (quiet_ns < self.working_hold_ns) {
                        self.pending_idle = null;
                        return;
                    },
                    .permission, .none => {},
                };
                if (self.confirmIdle(now_ns)) self.move(batch, .idle);
            },
            .idle => {
                // An agent first seen already waiting, or settled at its
                // prompt after a turn Conduit did not see run.
                const c = class orelse return;
                if (c == .permission) return self.fromScreen(batch, .waiting_permission);
                if (c == .input and quiet) self.fromScreen(batch, .waiting_input);
            },
            .waiting_input, .waiting_permission, .done, .errored => {},
        }
    }

    /// Count one more quiet confirmation of a pending idle; true once it is
    /// confirmed often enough or has waited out the cap.
    fn confirmIdle(self: *Heuristics, now_ns: u64) bool {
        const pending = if (self.pending_idle) |*p| p else {
            self.pending_idle = .{ .since_ns = now_ns, .last_ns = now_ns };
            return false;
        };
        if (now_ns -| pending.since_ns >= self.idle_cap_ns) {
            self.pending_idle = null;
            return true;
        }
        if (now_ns -| pending.last_ns >= self.idle_recheck_ns) {
            pending.confirmations += 1;
            pending.last_ns = now_ns;
        }
        if (pending.confirmations >= idle_confirmations) {
            self.pending_idle = null;
            return true;
        }
        return false;
    }

    fn fromScreen(self: *Heuristics, batch: *Batch, to: State) void {
        if (self.state != to) {
            if (!state_model.canTransition(self.state, to)) return;
            self.move(batch, to);
        }
        self.pending_idle = null;
        self.from_screen = true;
    }

    /// A bell after a finished turn is the harness announcing the outcome,
    /// not a wait, so attention latches only where a wait can begin. A
    /// permission prompt already on screen stays the more precise claim.
    fn raiseAttention(self: *Heuristics, batch: *Batch) void {
        if (self.state == .waiting_permission) {
            self.attention = true;
            return;
        }
        if (self.state != .waiting_input and !state_model.canTransition(self.state, .waiting_input)) return;
        self.attention = true;
        self.from_screen = false;
        self.pending_idle = null;
        self.move(batch, .waiting_input);
    }

    /// Emit a status change only when the table allows it; a heuristic never
    /// asks the registry for a refused transition. Every move ends a claim
    /// the screen made; `fromScreen` makes a new one.
    fn move(self: *Heuristics, batch: *Batch, to: State) void {
        if (!state_model.canTransition(self.state, to)) return;
        self.state = to;
        self.from_screen = false;
        self.pending_idle = null;
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

fn tickAt(h: *Heuristics, now_ns: u64) Batch {
    return h.observe(.{ .tick = .{ .now_ns = now_ns } });
}

fn screenAt(h: *Heuristics, now_ns: u64, text: []const u8) Batch {
    return h.observe(.{ .tick = .{ .now_ns = now_ns, .screen = text } });
}

test "activity is work and confirmed quiet is idle" {
    var h: Heuristics = .{ .quiet_after_ns = 100, .idle_recheck_ns = 10, .idle_cap_ns = 70 };
    try expectStatus(tickAt(&h, 0), null);
    try expectStatus(h.observe(.{ .output = .{ .now_ns = 10 } }), .working);
    try expectStatus(h.observe(.{ .output = .{ .now_ns = 20 } }), null);
    try expectStatus(tickAt(&h, 119), null);
    // Quiet long enough: held, then confirmed three times 10 apart.
    try expectStatus(tickAt(&h, 120), null);
    try expectStatus(tickAt(&h, 125), null);
    try expectStatus(tickAt(&h, 130), null);
    try expectStatus(tickAt(&h, 140), null);
    try expectStatus(tickAt(&h, 150), .idle);
    try expectStatus(h.observe(.{ .title = .{ .now_ns = 160 } }), .working);
    try expectStatus(h.observe(.{ .command_started = .{ .now_ns = 170 } }), null);
}

test "a spinner frame during the debounce starts it over, and the cap ends it" {
    var h: Heuristics = .{ .quiet_after_ns = 100, .idle_recheck_ns = 10, .idle_cap_ns = 70 };
    _ = h.observe(.{ .output = .{ .now_ns = 0 } });
    try expectStatus(tickAt(&h, 100), null);
    try expectStatus(tickAt(&h, 110), null);
    try expectStatus(tickAt(&h, 120), null);
    // A frame of a paused spinner: still working, nothing pending.
    try expectStatus(h.observe(.{ .output = .{ .now_ns = 125 } }), null);
    try testing.expect(h.pending_idle == null);
    try expectStatus(tickAt(&h, 130), null);
    try expectStatus(tickAt(&h, 224), null);
    try testing.expectEqual(State.working, h.state);
    // Quiet again from 225; ticks too close to confirm, so the cap decides.
    try expectStatus(tickAt(&h, 225), null);
    try expectStatus(tickAt(&h, 229), null);
    try expectStatus(tickAt(&h, 233), null);
    try expectStatus(tickAt(&h, 294), null);
    try expectStatus(tickAt(&h, 295), .idle);
    try testing.expect(!h.wantsFastTicks());
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

const test_manifest: screen.ScreenManifest = blk: {
    const m: screen.ScreenManifest = .{
        .captured_from = "test",
        .permission = &.{.{ .all = &.{"allow? [y/n]"} }},
        .working = &.{.{ .all = &.{"spinning"} }},
        .errored = &.{.{ .row_prefix = "error:" }},
        .input = &.{.{ .row_prefix = "> " }},
    };
    m.validate();
    break :blk m;
};

test "the screen names the quiet states and a visible prompt outranks activity" {
    var h: Heuristics = .{ .manifest = &test_manifest, .quiet_after_ns = 100, .working_hold_ns = 300, .idle_recheck_ns = 10, .idle_cap_ns = 70 };
    try testing.expect(h.wantsScreen());
    // First seen at its prompt.
    try expectStatus(screenAt(&h, 0, "hello\n> "), .waiting_input);
    try testing.expect(!h.wantsScreen());
    // The human types at the prompt: redraws, but still the prompt.
    try expectStatus(h.observe(.{ .output = .{ .now_ns = 10 } }), null);
    try testing.expect(h.wantsScreen());
    try expectStatus(screenAt(&h, 20, "hello\n> fix it"), null);
    try testing.expectEqual(State.waiting_input, h.state);
    // Submitted: a busy line replaces the prompt.
    _ = h.observe(.{ .output = .{ .now_ns = 30 } });
    try expectStatus(screenAt(&h, 40, "> fix it\nspinning"), .working);
    // The approval dialog appears while the spinner still animates.
    _ = h.observe(.{ .output = .{ .now_ns = 50 } });
    try expectStatus(screenAt(&h, 55, "spinning\nallow? [y/n]"), .waiting_permission);
    _ = h.observe(.{ .output = .{ .now_ns = 60 } });
    try expectStatus(screenAt(&h, 65, "spinning\nallow? [y/n]"), null);
    // A bell at the dialog does not downgrade it.
    try expectStatus(h.observe(.bell), null);
    try testing.expectEqual(State.waiting_permission, h.state);
    try expectStatus(h.observe(.user_input), .working);
    // Answered: a quiet busy line holds working until the hold runs out.
    _ = h.observe(.{ .output = .{ .now_ns = 100 } });
    try expectStatus(screenAt(&h, 250, "spinning"), null);
    try expectStatus(screenAt(&h, 399, "spinning"), null);
    try expectStatus(screenAt(&h, 400, "spinning"), null);
    try expectStatus(screenAt(&h, 410, "spinning"), null);
    try expectStatus(screenAt(&h, 420, "spinning"), null);
    try expectStatus(screenAt(&h, 430, "spinning"), .idle);
}

test "a quiet error line errs, and output before quiet is still work" {
    var h: Heuristics = .{ .manifest = &test_manifest, .quiet_after_ns = 100 };
    _ = h.observe(.{ .output = .{ .now_ns = 0 } });
    // Not quiet yet: the prompt may be the one shown while working.
    try expectStatus(screenAt(&h, 50, "Error: boom\n> "), null);
    try testing.expectEqual(State.working, h.state);
    try expectStatus(screenAt(&h, 100, "Error: boom\n> "), .errored);
    // Typing under the error redraws without ending it.
    _ = h.observe(.{ .output = .{ .now_ns = 110 } });
    try expectStatus(screenAt(&h, 120, "Error: boom\n> again"), null);
    // The error scrolled away and only the prompt is left: settled.
    _ = h.observe(.{ .output = .{ .now_ns = 130 } });
    try expectStatus(screenAt(&h, 240, "> again"), .idle);
    // A new turn: a busy line.
    _ = h.observe(.{ .output = .{ .now_ns = 250 } });
    try testing.expectEqual(State.working, h.state);
    // Plain shell text is no claim at all, so quiet is debounced idle.
    try expectStatus(screenAt(&h, 360, "$ ls"), null);
    try testing.expectEqual(State.working, h.state);
}

test "without a manifest the screen is never asked for" {
    var h: Heuristics = .{};
    try testing.expect(!h.wantsScreen());
    _ = h.observe(.{ .output = .{ .now_ns = 0 } });
    try testing.expect(!h.wantsScreen());
    try testing.expect(h.wantsFastTicks());
    // A screen passed anyway is classified by the empty manifest: nothing.
    try expectStatus(screenAt(&h, 5, "allow? [y/n]"), null);
}
