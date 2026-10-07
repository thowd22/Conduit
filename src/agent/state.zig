//! The agent state model: what an agent is doing, where that claim came
//! from, and which changes of state are meaningful (TASK-52).
//!
//! The six states are the ones CONDUIT.md §7 and TASK-56 notify on. `done`
//! and `errored` are the outcome of a turn, not of the process: an agent that
//! finished a turn can start another, so they are not terminal here. Process
//! exit is a separate fact the registry records (`Event.exited`), after which
//! no state changes at all.
//!
//! Memory: values only; nothing here allocates.

const std = @import("std");

/// What an agent is doing, harness-neutrally.
pub const State = enum {
    /// Started, or settled, with no turn in progress.
    idle,
    /// A turn is in progress.
    working,
    /// The harness needs the human: a question, an attention bell or a
    /// notification. Heuristics cannot tell this from a permission prompt.
    waiting_input,
    /// The harness asked for permission to use a tool and is blocked on it.
    waiting_permission,
    /// The last turn completed.
    done,
    /// The last turn, or the agent's start, failed.
    errored,

    /// Whether the agent is blocked on the human (TASK-56 raises
    /// notifications on these). `done` and `errored` are announced too, but
    /// nothing is blocked on them.
    pub fn needsAttention(self: State) bool {
        return self == .waiting_input or self == .waiting_permission;
    }

    /// Terse label for the agent manager and status lines.
    pub fn label(self: State) []const u8 {
        return switch (self) {
            .idle => "idle",
            .working => "working",
            .waiting_input => "waiting for input",
            .waiting_permission => "waiting for permission",
            .done => "done",
            .errored => "errored",
        };
    }
};

/// Where a state claim came from (decision-7). A structured source is the
/// harness's own side channel (hooks, app-server, extension); a heuristic one
/// is the harness-neutral PTY baseline. Once an agent has produced any
/// structured event, heuristic claims about it are ignored.
pub const Source = enum {
    structured,
    heuristic,
};

/// Whether `from → to` is a meaningful change of state.
///
/// Staying in the same state is not a transition. `waiting_input` and
/// `waiting_permission` arise only while a turn could be running, so they are
/// unreachable from a turn outcome (`done`, `errored`): a new turn starts with
/// `working`. `idle → done` is refused because nothing was running to finish,
/// and the two outcomes never turn into each other without a new turn.
/// Everything else is allowed, because a structured source may legitimately
/// skip intermediate states (an agent attached mid-turn reports its first
/// permission prompt while Conduit still believes it idle).
pub fn canTransition(from: State, to: State) bool {
    if (from == to) return false;
    return switch (from) {
        .idle => to != .done,
        .working, .waiting_input, .waiting_permission => true,
        .done, .errored => to == .idle or to == .working,
    };
}

/// Move from `from` to `to`, or fail. Returned rather than asserted: state
/// changes are driven by harness and PTY input, which must never crash the app.
pub fn transition(from: State, to: State) error{IllegalTransition}!State {
    if (!canTransition(from, to)) return error.IllegalTransition;
    return to;
}

test "the transition table, every pair" {
    const testing = std.testing;
    // Rows are `from`, columns are `to`, in declaration order:
    // idle, working, waiting_input, waiting_permission, done, errored.
    const allowed = [6][6]bool{
        .{ false, true, true, true, false, true }, // idle
        .{ true, false, true, true, true, true }, // working
        .{ true, true, false, true, true, true }, // waiting_input
        .{ true, true, true, false, true, true }, // waiting_permission
        .{ true, true, false, false, false, false }, // done
        .{ true, true, false, false, false, false }, // errored
    };
    const fields = @typeInfo(State).@"enum".fields;
    try testing.expectEqual(@as(usize, 6), fields.len);
    inline for (fields, 0..) |from_field, i| {
        inline for (fields, 0..) |to_field, j| {
            const from: State = @enumFromInt(from_field.value);
            const to: State = @enumFromInt(to_field.value);
            try testing.expectEqual(allowed[i][j], canTransition(from, to));
            if (allowed[i][j]) {
                try testing.expectEqual(to, try transition(from, to));
            } else {
                try testing.expectError(error.IllegalTransition, transition(from, to));
            }
        }
    }
}

test "only the two waiting states need attention" {
    const testing = std.testing;
    try testing.expect(State.waiting_input.needsAttention());
    try testing.expect(State.waiting_permission.needsAttention());
    for ([_]State{ .idle, .working, .done, .errored }) |state| {
        try testing.expect(!state.needsAttention());
        try testing.expect(state.label().len != 0);
    }
}
