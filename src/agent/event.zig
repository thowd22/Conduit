//! The typed agent event stream (TASK-52, decision-7).
//!
//! Every adapter, structured or heuristic, reports what its harness did as
//! `Event` values. Payload text — messages, tool summaries, paths, permission
//! titles, decision labels — is untrusted data from the harness: nothing in
//! `agent` executes, opens or answers anything because of it (CONDUIT.md
//! §11). A file reference becomes an action only through a later explicit user
//! gesture in a view, and a permission is answered only by
//! `Adapter.respondPermission` from a user gesture.
//!
//! Threads: adapter IO runs off the owner thread and hands events over through
//! `EventQueue`, a bounded, mutex-guarded ring of deep copies. `push` may be
//! called from any thread; `drain` and everything that reads a drained
//! `StoredEvent` belong to the owner (UI) thread.
//!
//! Memory: an `Event` borrows every slice it carries. `StoredEvent` owns fixed
//! inline storage for one event's text and decisions, so a stored event never
//! allocates; `EventQueue` allocates its slot array once in `init` and frees
//! it in `deinit`.

const std = @import("std");
const state = @import("state.zig");

const Allocator = std.mem.Allocator;

/// The most choices one permission request may offer. Claude Code offers
/// three or four; anything beyond this is a malformed request.
pub const max_decisions = 8;
/// The longest identifier (request, decision or subagent id) Conduit keeps.
/// Identifiers are never truncated, because a truncated id names nothing.
pub const max_identifier_bytes = 256;
/// The longest file path a file reference may carry, matching the terminal's
/// OSC 7 limit. Paths are identifiers too and are never truncated.
pub const max_path_bytes = 4096;
/// Inline text storage per stored event. Free text beyond this is truncated
/// at a UTF-8 boundary and flagged; the full transcript stays with the
/// harness's own files (decision-7).
pub const stored_text_capacity = 8 * 1024;

/// Who wrote a transcript message.
pub const Role = enum { user, assistant, system };

/// A transcript message.
pub const Message = struct {
    role: Role,
    text: []const u8,
    /// Set when storage cut `text` short.
    truncated: bool = false,
};

/// A tool the agent used, by the harness's own name, with a one-line summary
/// (a command, a file, a query).
pub const ToolUse = struct {
    name: []const u8,
    summary: []const u8,
    truncated: bool = false,
};

/// A file the agent read, wrote or mentioned. `path` is the harness's claim,
/// relative to the agent's cwd or absolute, in the workspace's
/// ExecutionContext; it is never resolved or opened here.
pub const FileReference = struct {
    path: []const u8,
    line: ?u32 = null,
    column: ?u32 = null,
};

/// What a permission choice means, so views can lay out the usual Allow once /
/// Always allow / Reject row without parsing labels. `other` keeps a harness
/// choice Conduit has no name for.
pub const DecisionKind = enum { allow_once, allow_always, reject, other };

/// One of the harness's own answers to a permission request.
pub const Decision = struct {
    /// What `Adapter.respondPermission` sends back for this choice.
    id: []const u8,
    label: []const u8,
    kind: DecisionKind,
};

/// The harness is blocked on a permission. `decisions` is the harness's own
/// list, in its order; Conduit never invents a choice.
pub const PermissionRequest = struct {
    id: []const u8,
    title: []const u8,
    decisions: []const Decision,
};

/// How a permission request ended. `resolved_elsewhere` is the human
/// answering in the harness's own TUI first, which adapters must accept
/// (decision-7, rule 2).
pub const PermissionOutcome = enum { allowed, rejected, resolved_elsewhere, cancelled };

/// A permission request is no longer pending.
pub const PermissionResolved = struct {
    id: []const u8,
    outcome: PermissionOutcome,
};

/// The agent's state changed, by the harness's side channel or by heuristics.
pub const StatusChange = struct {
    state: state.State,
    source: state.Source,
};

/// A subagent started or stopped inside this agent.
pub const Subagent = struct {
    pub const Phase = enum { start, stop };
    id: []const u8,
    name: []const u8,
    phase: Phase,
};

/// A notification the harness raised: OSC 9/777 text or a hook's
/// notification. Display text only.
pub const Notification = struct {
    title: []const u8,
    body: []const u8,
    truncated: bool = false,
};

/// How the agent's process ended.
pub const ExitStatus = union(enum) {
    code: u8,
    signal: u8,

    /// Whether the process ended normally with status zero.
    pub fn succeeded(self: ExitStatus) bool {
        return switch (self) {
            .code => |code| code == 0,
            .signal => false,
        };
    }
};

/// One thing a harness did.
pub const Event = union(enum) {
    message: Message,
    tool_use: ToolUse,
    file_reference: FileReference,
    permission_request: PermissionRequest,
    permission_resolved: PermissionResolved,
    status_change: StatusChange,
    subagent: Subagent,
    notification: Notification,
    /// The agent's process ended. Nothing follows it.
    exited: ExitStatus,

    pub const Kind = std.meta.Tag(Event);
};

/// Why an event could not be stored.
pub const StoreError = error{
    /// An identifier or path exceeded its limit, a request offered more than
    /// `max_decisions` choices, or identifiers alone filled the storage.
    EventTooLarge,
};

/// One event deep-copied into inline storage.
///
/// After `store`, `event`'s slices point into this value: do not copy a
/// `StoredEvent` by value and keep using the copy's `event`; use `store`
/// again into the destination instead.
pub const StoredEvent = struct {
    event: Event,
    decisions: [max_decisions]Decision,
    text: [stored_text_capacity]u8,

    /// Deep-copy `source` into this slot. Identifiers and paths are copied
    /// whole or the event is refused; free text then takes what space
    /// remains and is truncated at a UTF-8 boundary, flagged on the event.
    /// On error the slot's previous contents are unspecified.
    pub fn store(self: *StoredEvent, source: Event) StoreError!void {
        var copier: Copier = .{ .buffer = &self.text };
        self.event = switch (source) {
            .message => |m| blk: {
                const text = copier.freeText(m.text);
                break :blk .{ .message = .{ .role = m.role, .text = text, .truncated = m.truncated or copier.truncated } };
            },
            .tool_use => |t| blk: {
                const name = try copier.identifier(t.name, max_identifier_bytes);
                const summary = copier.freeText(t.summary);
                break :blk .{ .tool_use = .{ .name = name, .summary = summary, .truncated = t.truncated or copier.truncated } };
            },
            .file_reference => |f| .{ .file_reference = .{
                .path = try copier.identifier(f.path, max_path_bytes),
                .line = f.line,
                .column = f.column,
            } },
            .permission_request => |p| blk: {
                if (p.decisions.len > max_decisions) return error.EventTooLarge;
                const id = try copier.identifier(p.id, max_identifier_bytes);
                for (p.decisions, 0..) |decision, i| {
                    self.decisions[i] = .{
                        .id = try copier.identifier(decision.id, max_identifier_bytes),
                        .label = "",
                        .kind = decision.kind,
                    };
                }
                // Labels are display text, but a cut label could misdescribe
                // a choice, so they share the identifier rule.
                for (p.decisions, 0..) |decision, i| {
                    self.decisions[i].label = try copier.identifier(decision.label, max_identifier_bytes);
                }
                const title = copier.freeText(p.title);
                break :blk .{ .permission_request = .{
                    .id = id,
                    .title = title,
                    .decisions = self.decisions[0..p.decisions.len],
                } };
            },
            .permission_resolved => |r| .{ .permission_resolved = .{
                .id = try copier.identifier(r.id, max_identifier_bytes),
                .outcome = r.outcome,
            } },
            .status_change => |s| .{ .status_change = s },
            .subagent => |s| blk: {
                const id = try copier.identifier(s.id, max_identifier_bytes);
                const name = copier.freeText(s.name);
                break :blk .{ .subagent = .{ .id = id, .name = name, .phase = s.phase } };
            },
            .notification => |n| blk: {
                const title = copier.freeText(n.title);
                const body = copier.freeText(n.body);
                break :blk .{ .notification = .{ .title = title, .body = body, .truncated = n.truncated or copier.truncated } };
            },
            .exited => |e| .{ .exited = e },
        };
    }
};

/// Appends slices into one fixed buffer.
const Copier = struct {
    buffer: []u8,
    used: usize = 0,
    truncated: bool = false,

    fn identifier(self: *Copier, bytes: []const u8, limit: usize) StoreError![]const u8 {
        if (bytes.len > limit or bytes.len > self.buffer.len - self.used) return error.EventTooLarge;
        return self.append(bytes);
    }

    fn freeText(self: *Copier, bytes: []const u8) []const u8 {
        const kept = truncateUtf8(bytes, self.buffer.len - self.used);
        if (kept.len != bytes.len) self.truncated = true;
        return self.append(kept);
    }

    fn append(self: *Copier, bytes: []const u8) []const u8 {
        const destination = self.buffer[self.used..][0..bytes.len];
        @memcpy(destination, bytes);
        self.used += bytes.len;
        return destination;
    }
};

/// The longest prefix of `bytes` no longer than `limit` that does not end
/// inside a UTF-8 sequence. Malformed input is cut at a byte boundary at
/// worst; it is display text and is never interpreted.
pub fn truncateUtf8(bytes: []const u8, limit: usize) []const u8 {
    if (bytes.len <= limit) return bytes;
    var end = limit;
    // Back off at most three continuation bytes to the start of a sequence,
    // and drop that partial sequence.
    var steps: usize = 0;
    while (end > 0 and steps < 4) : (steps += 1) {
        const byte = bytes[end];
        if (byte & 0xC0 != 0x80) break;
        end -= 1;
    }
    return bytes[0..end];
}

/// A bounded hand-over of events from adapter IO threads to the owner thread.
///
/// Ownership: `init` allocates the slot array with the given allocator, which
/// `deinit` must receive again. `io` is borrowed for the mutex and must
/// outlive the queue. The queue never grows: a full queue refuses the push
/// and the adapter keeps the event in its own transport until a later poll,
/// so a permission request is delayed rather than lost.
pub const EventQueue = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    slots: []StoredEvent,
    head: usize = 0,
    len: usize = 0,
    /// Pushes refused because the queue was full.
    full_refusals: u64 = 0,

    pub const PushError = StoreError || error{QueueFull};

    pub fn init(allocator: Allocator, io: std.Io, capacity: usize) Allocator.Error!EventQueue {
        std.debug.assert(capacity != 0);
        return .{ .io = io, .slots = try allocator.alloc(StoredEvent, capacity) };
    }

    pub fn deinit(self: *EventQueue, allocator: Allocator) void {
        allocator.free(self.slots);
        self.* = undefined;
    }

    /// Deep-copy `source` into the queue. Callable from any thread. The
    /// source's slices need only live for the call.
    pub fn push(self: *EventQueue, source: Event) PushError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.len == self.slots.len) {
            self.full_refusals += 1;
            return error.QueueFull;
        }
        const index = (self.head + self.len) % self.slots.len;
        try self.slots[index].store(source);
        self.len += 1;
    }

    /// Move up to `out.len` queued events, oldest first, into `out` and
    /// return how many. Owner thread only; `out`'s events borrow `out`.
    pub fn drain(self: *EventQueue, out: []StoredEvent) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        while (count < out.len and self.len != 0) : (count += 1) {
            // A queued event already fit one slot, so it fits another.
            out[count].store(self.slots[self.head].event) catch unreachable;
            self.head = (self.head + 1) % self.slots.len;
            self.len -= 1;
        }
        return count;
    }

    /// How many events wait to be drained.
    pub fn pending(self: *EventQueue) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.len;
    }
};

test "every event kind survives a deep copy and stops borrowing its source" {
    const testing = std.testing;
    var source_text = "Bash: ls -la".*;
    const decisions = [_]Decision{
        .{ .id = "allow", .label = "Allow once", .kind = .allow_once },
        .{ .id = "always", .label = "Always allow", .kind = .allow_always },
        .{ .id = "deny", .label = "Reject", .kind = .reject },
    };
    const events = [_]Event{
        .{ .message = .{ .role = .assistant, .text = &source_text } },
        .{ .tool_use = .{ .name = "Bash", .summary = &source_text } },
        .{ .file_reference = .{ .path = "src/main.zig", .line = 12, .column = 4 } },
        .{ .permission_request = .{ .id = "req-1", .title = &source_text, .decisions = &decisions } },
        .{ .permission_resolved = .{ .id = "req-1", .outcome = .resolved_elsewhere } },
        .{ .status_change = .{ .state = .working, .source = .structured } },
        .{ .subagent = .{ .id = "sub-1", .name = "explore", .phase = .start } },
        .{ .notification = .{ .title = "Claude", .body = &source_text } },
        .{ .exited = .{ .code = 0 } },
    };
    // Every kind is covered by this list.
    try testing.expectEqual(@typeInfo(Event).@"union".fields.len, events.len);

    const slot = try testing.allocator.create(StoredEvent);
    defer testing.allocator.destroy(slot);
    for (events) |event| {
        try slot.store(event);
        try testing.expectEqual(std.meta.activeTag(event), std.meta.activeTag(slot.event));
    }

    try slot.store(events[3]);
    const request = slot.event.permission_request;
    @memset(&source_text, 'x');
    try testing.expectEqualStrings("Bash: ls -la", request.title);
    try testing.expectEqual(@as(usize, 3), request.decisions.len);
    try testing.expectEqualStrings("always", request.decisions[1].id);
    try testing.expectEqualStrings("Reject", request.decisions[2].label);
    try testing.expectEqual(DecisionKind.reject, request.decisions[2].kind);
}

test "free text truncates at a UTF-8 boundary, identifiers are refused instead" {
    const testing = std.testing;
    const slot = try testing.allocator.create(StoredEvent);
    defer testing.allocator.destroy(slot);

    // "é" is two bytes; a cut through it must drop the whole sequence.
    const long = "é" ** (stored_text_capacity / 2) ++ "é";
    try slot.store(.{ .message = .{ .role = .assistant, .text = long } });
    const message = slot.event.message;
    try testing.expect(message.truncated);
    try testing.expect(message.text.len <= stored_text_capacity);
    try testing.expect(std.unicode.utf8ValidateSlice(message.text));

    try slot.store(.{ .message = .{ .role = .user, .text = "short" } });
    try testing.expect(!slot.event.message.truncated);

    const long_id = "a" ** (max_identifier_bytes + 1);
    try testing.expectError(error.EventTooLarge, slot.store(.{ .permission_resolved = .{ .id = long_id, .outcome = .allowed } }));
    const long_path = "p" ** (max_path_bytes + 1);
    try testing.expectError(error.EventTooLarge, slot.store(.{ .file_reference = .{ .path = long_path } }));

    const too_many = [_]Decision{.{ .id = "a", .label = "A", .kind = .other }} ** (max_decisions + 1);
    try testing.expectError(error.EventTooLarge, slot.store(.{ .permission_request = .{
        .id = "r",
        .title = "t",
        .decisions = &too_many,
    } }));

    try testing.expectEqualStrings("ab", truncateUtf8("abc", 2));
    try testing.expectEqualStrings("a", truncateUtf8("a\xc3\xa9", 2));
    try testing.expectEqualStrings("", truncateUtf8("\xe2\x82\xac", 2));
}

test "the queue is bounded, ordered and refuses rather than grows" {
    const testing = std.testing;
    var queue = try EventQueue.init(testing.allocator, testing.io, 2);
    defer queue.deinit(testing.allocator);

    try queue.push(.{ .status_change = .{ .state = .working, .source = .structured } });
    try queue.push(.{ .tool_use = .{ .name = "Read", .summary = "a.zig" } });
    try testing.expectError(error.QueueFull, queue.push(.{ .exited = .{ .code = 0 } }));
    try testing.expectEqual(@as(u64, 1), queue.full_refusals);
    try testing.expectEqual(@as(usize, 2), queue.pending());

    const out = try testing.allocator.alloc(StoredEvent, 1);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 1), queue.drain(out));
    try testing.expectEqual(Event.Kind.status_change, std.meta.activeTag(out[0].event));
    try queue.push(.{ .exited = .{ .signal = 9 } });
    try testing.expectEqual(@as(usize, 1), queue.drain(out));
    try testing.expectEqualStrings("a.zig", out[0].event.tool_use.summary);
    try testing.expectEqual(@as(usize, 1), queue.drain(out));
    try testing.expect(!out[0].event.exited.succeeded());
    try testing.expectEqual(@as(usize, 0), queue.drain(out));

    // An event too large for a slot is refused and takes no slot.
    try testing.expectError(error.EventTooLarge, queue.push(.{ .file_reference = .{ .path = "p" ** (max_path_bytes + 1) } }));
    try testing.expectEqual(@as(usize, 0), queue.pending());
}
