//! The backlog.md data layer.
//!
//! `backlog` owns the data behind the board and the task-detail views:
//! projects, tasks, milestones, statuses and dependencies, and the linking of a
//! backlog task to an agent (TASK-64). It owns *data*; the views are `ui`
//! compositions of that data. Backlog file content is untrusted text — it is
//! read through the ExecutionContext it is given as a parameter (P7) and can
//! never trigger an action (§11) — and it is never kept in a second copy that
//! could disagree with the file.
//!
//! This file is deliberately smaller than that job: TASK-62 – TASK-64 own
//! projects, milestones, dependencies and persistence. What is here is the
//! vocabulary that has to be right before any of that is read or written: the
//! id a task is known by and the status it is in, in the spellings the
//! `backlog/` files themselves use.
//!
//! It may depend on `config`, `input`, `theme`, `ui` and `workspace`
//! (`build.zig`). None of them is imported yet: reads arrive through the
//! ExecutionContext at TASK-62 and the views are composed at TASK-63, and this
//! file declares no import it does not use today.
//!
//! Memory: this module allocates nothing. Ids and statuses are values, and
//! `TaskId.format` writes into a buffer the caller owns.

const std = @import("std");

/// The id of one backlog task, as written in the file's front matter: `TASK-27`.
///
/// The canonical spelling is `TASK-` followed by the decimal number, no
/// leading zeros and no padding. That is what makes the id, the
/// `backlog/tasks/task-27 - ….md` file name and the `task-27` the CLI prints
/// the same task, and it is why a non-canonical spelling is an error rather
/// than something to normalise into a second representation of the same task.
///
/// Invariant: a `TaskId` is never zero, and `parse` accepts exactly the
/// canonical spellings.
pub const TaskId = struct {
    /// The task's number. Task 1 is the first task; there is no task 0.
    number: u32,

    /// The prefix every id is written with.
    pub const prefix = "TASK-";

    /// The error any non-canonical spelling produces. Backlog files are
    /// untrusted input (§11), so a malformed id is reported, never asserted on
    /// (`AGENTS.md`, coding standards).
    pub const Error = error{MalformedTaskId};

    /// Parse the id out of its canonical spelling.
    pub fn parse(text: []const u8) Error!TaskId {
        if (!std.mem.startsWith(u8, text, prefix)) return error.MalformedTaskId;

        const digits = text[prefix.len..];
        if (digits.len == 0) return error.MalformedTaskId;
        // A leading zero would let one task be written two ways.
        if (digits.len > 1 and digits[0] == '0') return error.MalformedTaskId;
        for (digits) |c| {
            if (!std.ascii.isDigit(c)) return error.MalformedTaskId;
        }

        // Out of range is malformed too, not a wrap or a crash.
        const number = std.fmt.parseInt(u32, digits, 10) catch
            return error.MalformedTaskId;
        if (number == 0) return error.MalformedTaskId;
        return .{ .number = number };
    }

    /// Write the canonical spelling into `buf` and return the written slice.
    /// `buf` stays owned by the caller.
    pub fn format(self: TaskId, buf: []u8) std.fmt.BufPrintError![]const u8 {
        return std.fmt.bufPrint(buf, prefix ++ "{d}", .{self.number});
    }
};

/// Where a task sits: to do, in progress, or done. These are the three
/// statuses the `backlog/` files carry, spelled the way the backlog tool writes
/// them; the board view reads them and renders its columns above that.
///
/// The set is closed, so a file that names a fourth status is malformed rather
/// than a status this module silently drops.
pub const Status = enum {
    to_do,
    in_progress,
    done,

    /// Every status, in board order.
    pub const all = [_]Status{ .to_do, .in_progress, .done };

    /// The error a spelling that is not one of the three produces.
    pub const Error = error{MalformedStatus};

    /// Parse the status as it is stored in a task's front matter.
    pub fn parse(text: []const u8) Error!Status {
        inline for (@typeInfo(Status).@"enum".fields) |field| {
            const status: Status = @enumFromInt(field.value);
            if (std.mem.eql(u8, text, status.display())) return status;
        }
        return error.MalformedStatus;
    }

    /// The spelling this status is stored and shown with.
    pub fn display(self: Status) []const u8 {
        return switch (self) {
            .to_do => "To Do",
            .in_progress => "In Progress",
            .done => "Done",
        };
    }

    /// Whether the task is finished, so the board stops asking an agent about
    /// it.
    pub fn isComplete(self: Status) bool {
        return self == .done;
    }
};

test "a task id round-trips through its canonical spelling" {
    const testing = std.testing;

    try testing.expectEqual(@as(u32, 1), (try TaskId.parse("TASK-1")).number);
    try testing.expectEqual(@as(u32, 70), (try TaskId.parse("TASK-70")).number);

    for ([_]u32{ 1, 9, 10, 27, 70, 1000 }) |number| {
        var buf: [16]u8 = undefined;
        const written = try (TaskId{ .number = number }).format(&buf);
        try testing.expectEqualStrings("TASK-", TaskId.prefix);
        try testing.expectEqual(number, (try TaskId.parse(written)).number);
        // Nothing is written past what is returned.
        try testing.expect(written.len <= buf.len);
    }
}

test "a task id that is not canonical is not an id" {
    const testing = std.testing;

    for ([_][]const u8{
        "", // nothing at all
        "task-27", // lower case: the file name, not the id
        "TASK-", // prefix with no number
        "TASK-0", // no task zero
        "TASK-027", // one task, two spellings
        "TASK-4a", // trailing junk
        "TASK--1", // sign where a digit belongs
        " TASK-27", // padded
        "TASK-27 ", // padded
        "TASK-4294967296", // past the largest id
    }) |malformed| {
        try testing.expectError(error.MalformedTaskId, TaskId.parse(malformed));
    }
}

test "a task is To Do, In Progress or Done" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 3), Status.all.len);

    for (Status.all) |status| {
        try testing.expectEqual(status, try Status.parse(status.display()));
        // Only "Done" is finished; the other two still want work.
        try testing.expect(status.isComplete() == (status == .done));
    }

    for ([_][]const u8{
        "", // nothing at all
        "todo", // a spelling the files do not use
        "In progress", // right words, wrong case
        "IN PROGRESS",
        "done ",
        "Done!", // punctuation is not part of the status
        "Closed", // backlog.md has no fourth status
    }) |malformed| {
        try testing.expectError(error.MalformedStatus, Status.parse(malformed));
    }
}
